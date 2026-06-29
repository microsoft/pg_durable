// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! UpdateNodeStatus activity - updates df.nodes status, result, and status_details

use duroxide::ActivityContext;
use sqlx::{PgPool, Postgres, QueryBuilder};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::update-node-status";

/// Process-global cache for whether df.nodes.status_details exists.
///
/// 0 = unknown, 1 = present, 2 = absent. The column is added by the
/// 0.2.3 → 0.2.4 upgrade; a binary newer than the schema (Scenario B1) must run
/// against an older schema that lacks it. We cache "present" permanently once
/// seen, but re-probe on "unknown"/"absent" so an in-place ALTER EXTENSION
/// UPDATE that adds the column is picked up without a worker restart.
static STATUS_DETAILS_COL: AtomicU8 = AtomicU8::new(0);

async fn status_details_present(pool: &PgPool) -> bool {
    if STATUS_DETAILS_COL.load(Ordering::Relaxed) == 1 {
        return true;
    }
    let present = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM information_schema.columns \
         WHERE table_schema = 'df' AND table_name = 'nodes' \
         AND column_name = 'status_details')",
    )
    .fetch_one(pool)
    .await
    .unwrap_or(false);
    STATUS_DETAILS_COL.store(if present { 1 } else { 2 }, Ordering::Relaxed);
    present
}

/// Update the status and optionally the result of a node in df.nodes.
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    input_json: String,
) -> Result<String, String> {
    let input: serde_json::Value = serde_json::from_str(&input_json)
        .map_err(|e| format!("Failed to parse node status input: {e}"))?;

    let node_id = input["node_id"].as_str().ok_or("Missing node_id")?;
    let status = input["status"].as_str().ok_or("Missing status")?;
    let result = input.get("result").and_then(|r| r.as_str());
    // instance_id scopes the UPDATE to the owning instance and is REQUIRED.
    // Node IDs are only unique per instance (issue #129 / composite PK
    // (instance_id, id) on df.nodes), so updating by node_id alone could touch a
    // different instance's node -- a fail-open cross-instance corruption path.
    // The scope must travel through the activity input: duroxide's
    // ctx.instance_id() returns the *orchestration* id (an auto-generated token
    // for parallel/loop subtrees), not the df instance id, so it cannot be used
    // here. The serialized graph carried in the input preserves the df id.
    //
    // Upgrade note: duroxide compares activity inputs by exact equality during
    // replay, so adding fields changes the recorded input shape. Instances in
    // flight across the binary upgrade recorded the old shape and cannot be
    // replayed -- they must be drained/recreated before upgrading (see
    // docs/upgrade-testing.md, issue #129 section).
    let instance_id = input["instance_id"].as_str().ok_or("Missing instance_id")?;

    // execution_id is the "{orchestration_instance_id}::{execution_id}" stamp
    // identifying which orchestration generation last transitioned this node. It
    // is optional: a pre-execution-id binary recorded inputs without it, so when
    // absent we fall back to the unfenced write. df.instance_nodes() parses the
    // stamp's second token (the root loop generation) to derive pending/skipped.
    let execution_id = input.get("execution_id").and_then(|v| v.as_str());

    // Only write status_details when the binary supplies a stamp AND the running
    // schema actually has the column (Scenario B1: a newer .so may run against a
    // pre-0.2.4 schema lacking it -- degrade to the plain status/result write).
    let write_details = execution_id.is_some() && status_details_present(pool.as_ref()).await;

    // Fence value: the incoming root generation (second "::"-token of the stamp).
    // When the stamp can't be parsed we pass i64::MAX so the fence always
    // accepts (i.e. behaves as no fence) rather than silently dropping writes.
    let incoming_gen: i64 = execution_id
        .and_then(|s| s.split("::").nth(1))
        .and_then(|tok| tok.parse::<i64>().ok())
        .unwrap_or(i64::MAX);

    let mut update = QueryBuilder::<Postgres>::new("UPDATE df.nodes SET status = ");
    update.push_bind(status);

    if let Some(res) = result {
        let json_result = serde_json::from_str::<serde_json::Value>(res)
            .unwrap_or_else(|_| serde_json::Value::String(res.to_string()));
        update
            .push(", result = ")
            .push_bind(json_result)
            .push("::jsonb");
    } else if status == "running" {
        // When marking as running, clear any stale result from a previous loop
        // iteration to satisfy nodes_result_status_chk
        // (result IS NULL OR status IN ('completed', 'failed')).
        update.push(", result = NULL");
    }

    if write_details {
        let details = serde_json::json!({ "execution_id": execution_id });
        update
            .push(", status_details = ")
            .push_bind(details)
            .push("::jsonb");
    }

    // Monotonic write fence: reject a write carrying an OLDER root generation than
    // the one already stamped on the row, so a stale loser/iteration drain can't
    // clobber a newer generation's status. Equal-or-newer generations (including
    // running -> terminal within the same generation) are accepted.
    update
        .push(", updated_at = now() WHERE id = ")
        .push_bind(node_id)
        .push(" AND instance_id = ")
        .push_bind(instance_id);
    if write_details {
        update
            .push(
                " AND (status_details IS NULL OR \
                 COALESCE(NULLIF(split_part(status_details->>'execution_id', '::', 2), '')::bigint, 0) <= ",
            )
            .push_bind(incoming_gen)
            .push(")");
    }

    match update.build().execute(pool.as_ref()).await {
        Ok(done) => {
            let rows = done.rows_affected();
            if rows == 1 {
                Ok("Node status updated".to_string())
            } else if write_details {
                // Zero rows under an active fence is ambiguous: the row may exist
                // but carry a NEWER generation (a legitimate fenced-out stale
                // write), or the node may genuinely be missing. Distinguish the
                // two so a fence rejection is not surfaced as a correctness error.
                let exists = sqlx::query_scalar::<_, bool>(
                    "SELECT EXISTS (SELECT 1 FROM df.nodes WHERE id = $1 AND instance_id = $2)",
                )
                .bind(node_id)
                .bind(instance_id)
                .fetch_one(pool.as_ref())
                .await
                .unwrap_or(false);
                if exists {
                    Ok("Node status write fenced (superseded by newer generation)".to_string())
                } else {
                    let err_msg = format!(
                        "update_node_status affected 0 rows: node {node_id} \
                         not found in instance {instance_id}"
                    );
                    ctx.trace_info(&err_msg);
                    Err(err_msg)
                }
            } else {
                // No fence in play: exactly one row must match (instance_id, id).
                // Anything else (typically zero rows: a missing node or a
                // mismatched instance_id) is a correctness violation.
                let err_msg = format!(
                    "update_node_status affected {rows} row(s) for node {node_id} \
                     in instance {instance_id} (expected exactly 1)"
                );
                ctx.trace_info(&err_msg);
                Err(err_msg)
            }
        }
        Err(e) => {
            let err_msg = format!("Failed to update node status: {e}");
            ctx.trace_info(&err_msg);
            Err(err_msg)
        }
    }
}
