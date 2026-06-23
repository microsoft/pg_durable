// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! UpdateNodeStatus activity - updates df.nodes status and result

use duroxide::ActivityContext;
use sqlx::PgPool;
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::update-node-status";

/// Update the status and optionally the result of a node in df.nodes
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
    // replay, so adding instance_id changes the recorded input shape. Instances
    // in flight across the binary upgrade recorded the old shape and cannot be
    // replayed -- they must be drained/recreated before upgrading (see
    // docs/upgrade-testing.md, issue #129 section). Every post-upgrade instance
    // carries instance_id from the start, so requiring it here is safe and there
    // is deliberately no node_id-only fallback (it would be dead code that only
    // re-opened the corruption path above).
    let instance_id = input["instance_id"].as_str().ok_or("Missing instance_id")?;

    // The UPDATE is always scoped by (id, instance_id), which the composite
    // primary key makes unique, so it can affect at most one row. Positional
    // placeholders match the bind order below.
    let sql: &str = if result.is_some() {
        "UPDATE df.nodes
             SET status = $1, result = $2::jsonb, updated_at = now()
             WHERE id = $3 AND instance_id = $4"
    } else if status == "running" {
        // When marking as running, clear any stale result from a previous
        // loop iteration to satisfy the constraint:
        // (result IS NULL OR status IN ('completed', 'failed'))
        "UPDATE df.nodes
             SET status = $1, result = NULL, updated_at = now()
             WHERE id = $2 AND instance_id = $3"
    } else {
        "UPDATE df.nodes
             SET status = $1, updated_at = now()
             WHERE id = $2 AND instance_id = $3"
    };

    let mut query = sqlx::query(sql).bind(status);
    if let Some(res) = result {
        // The result column is JSONB, so normalize invalid JSON payloads into
        // a JSON string before binding.
        let json_result = serde_json::from_str::<serde_json::Value>(res)
            .unwrap_or_else(|_| serde_json::Value::String(res.to_string()));
        query = query.bind(json_result);
    }
    query = query.bind(node_id).bind(instance_id);

    match query.execute(pool.as_ref()).await {
        Ok(done) => {
            let rows = done.rows_affected();
            if rows == 1 {
                Ok("Node status updated".to_string())
            } else {
                // Exactly one row must match (instance_id, id). Anything else
                // (typically zero rows: a missing node or a mismatched
                // instance_id) is a correctness violation we must surface rather
                // than silently swallow.
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
