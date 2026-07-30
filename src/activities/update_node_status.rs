// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! UpdateNodeStatus activity - updates df.nodes status, result, and status_details

use duroxide::ActivityContext;
use sqlx::{PgPool, Postgres, QueryBuilder, Transaction};
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

fn execution_id_from_details(status_details: Option<&serde_json::Value>) -> Option<&str> {
    status_details?.get("execution_id")?.as_str()
}

/// Decompose a node stamp into its generation lineage and the branch node ids
/// spawned at each level.
///
/// A stamp is `{root_instance}::{g0}::{node1}::{g1}::...::{nodeN}::{gN}`: the
/// root df instance id, then the root orchestration generation `g0`, then for
/// every spawned sub-orchestration the child root node id and that child's own
/// `continue_as_new` generation. `subtree_instance_id` composes exactly this
/// shape, so the returned `gens` reads root→innermost (`g0..gN`) and `nodes`
/// holds the branch node id taken to descend from each level to the next.
///
/// Returns `None` for a malformed stamp (no generation, or an odd trailing
/// token count that is not `gen (node gen)*`), so a legacy/unparseable stamp
/// degrades to an unfenced write rather than silently dropping it.
fn stamp_lineage(execution_id: &str) -> Option<(Vec<i64>, Vec<&str>)> {
    let (lineage, current_generation) = crate::node_status::parse_execution_stamp(execution_id)?;
    let mut generations = lineage.generations().to_vec();
    generations.push(current_generation);
    Some((generations, lineage.node_ids().to_vec()))
}

/// Whether the `incoming` write belongs to a superseded generation relative to
/// the `existing` stamp already on the row.
///
/// Both stamps transition the SAME node, so they share a node lineage but may
/// carry different generations at each nesting level. Walk both lineages from
/// the root: the first level whose incoming generation is OLDER means the write
/// comes from a superseded ancestor (or its own older) generation and must be
/// fenced. If the generations tie at a level, the branch node id spawned next
/// decides — a different id is an independent sibling scope (one loop iteration's
/// parallel branch must never fence another's), an equal id descends, and a
/// lineage that ends is the same-or-deeper scope in the same generation and is
/// accepted. A newer incoming generation at any level is accepted. This is the
/// write-side mirror of the read-time inference in `node_status::is_superseded`,
/// but compares two stamps directly because the activity sees only one row.
fn incoming_stamp_is_superseded(incoming: &str, existing: Option<&str>) -> bool {
    let Some(existing) = existing else {
        return false;
    };
    let (Some((inc_gens, inc_nodes)), Some((ex_gens, ex_nodes))) =
        (stamp_lineage(incoming), stamp_lineage(existing))
    else {
        return false;
    };

    let depth = inc_gens.len().min(ex_gens.len());
    for level in 0..depth {
        if inc_gens[level] < ex_gens[level] {
            return true;
        }
        if inc_gens[level] > ex_gens[level] {
            return false;
        }
        // Generations tie at this level: an independent sibling scope (a
        // different branch node id spawned next) is never fenced.
        if let (Some(a), Some(b)) = (inc_nodes.get(level), ex_nodes.get(level)) {
            if a != b {
                return false;
            }
        }
    }
    false
}
fn push_status_update<'a>(
    update: &mut QueryBuilder<'a, Postgres>,
    status: &'a str,
    result: Option<&'a str>,
    execution_id: Option<&'a str>,
    write_details: bool,
) {
    update
        .push("UPDATE df.nodes SET status = ")
        .push_bind(status);

    if let Some(res) = result {
        let json_result = serde_json::from_str::<serde_json::Value>(res)
            .unwrap_or_else(|_| serde_json::Value::String(res.to_string()));
        update
            .push(", result = ")
            .push_bind(json_result)
            .push("::jsonb");
    } else if !matches!(status, "completed" | "failed") {
        // When marking as non-terminal, clear any stale result from a previous
        // transition to satisfy nodes_result_status_chk
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
}

pub(crate) async fn finish_fenced_status_update(
    tx: Transaction<'_, Postgres>,
) -> Result<String, String> {
    tx.rollback()
        .await
        .map_err(|e| format!("Failed to roll back fenced node status update: {e}"))?;
    Ok("Node status write fenced (superseded by newer generation)".to_string())
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

    let mut update = QueryBuilder::<Postgres>::new("");
    push_status_update(&mut update, status, result, execution_id, write_details);

    // Monotonic write fence: when status_details exists, first lock the row and compare the
    // incoming stamp against the existing stamp using the same scope-lineage semantics as
    // read-time status inference. A stale write is one whose own scope generation is older,
    // or whose parent scope was spawned by an older ancestor generation. Equal-or-newer
    // generations (including running -> terminal within the same generation) are accepted.
    if write_details {
        let mut tx = pool
            .begin()
            .await
            .map_err(|e| format!("Failed to begin node status update transaction: {e}"))?;

        let existing_details = sqlx::query_scalar::<_, Option<serde_json::Value>>(
            "SELECT status_details FROM df.nodes WHERE id = $1 AND instance_id = $2 FOR UPDATE",
        )
        .bind(node_id)
        .bind(instance_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| format!("Failed to lock node status row: {e}"))?;

        let Some(existing_details) = existing_details else {
            let err_msg = format!(
                "update_node_status affected 0 rows: node {node_id} \
                 not found in instance {instance_id}"
            );
            ctx.trace_info(&err_msg);
            return Err(err_msg);
        };

        let existing_execution_id = execution_id_from_details(existing_details.as_ref());
        if incoming_stamp_is_superseded(execution_id.unwrap_or_default(), existing_execution_id) {
            return finish_fenced_status_update(tx).await;
        }

        update
            .push(", updated_at = now() WHERE id = ")
            .push_bind(node_id)
            .push(" AND instance_id = ")
            .push_bind(instance_id);

        let done = update
            .build()
            .execute(&mut *tx)
            .await
            .map_err(|e| format!("Failed to update node status: {e}"))?;
        let rows = done.rows_affected();
        if rows != 1 {
            let err_msg = format!(
                "update_node_status affected {rows} row(s) for node {node_id} \
                 in instance {instance_id} (expected exactly 1)"
            );
            ctx.trace_info(&err_msg);
            return Err(err_msg);
        }

        tx.commit()
            .await
            .map_err(|e| format!("Failed to commit node status update transaction: {e}"))?;
        return Ok("Node status updated".to_string());
    }

    update
        .push(", updated_at = now() WHERE id = ")
        .push_bind(node_id)
        .push(" AND instance_id = ")
        .push_bind(instance_id);

    match update.build().execute(pool.as_ref()).await {
        Ok(done) => {
            let rows = done.rows_affected();
            if rows == 1 {
                Ok("Node status updated".to_string())
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

#[cfg(test)]
mod tests {
    use super::*;

    fn status_update_sql(status: &str, result: Option<&str>) -> String {
        let mut update = QueryBuilder::<Postgres>::new("");
        push_status_update(&mut update, status, result, None, false);
        update.sql().to_string()
    }

    #[test]
    fn clears_result_for_every_non_terminal_status() {
        assert!(status_update_sql("pending", None).contains("result = NULL"));
        assert!(status_update_sql("running", None).contains("result = NULL"));
    }

    #[test]
    fn preserves_result_for_terminal_status_without_replacement() {
        assert!(!status_update_sql("completed", None).contains("result = NULL"));
        assert!(!status_update_sql("failed", None).contains("result = NULL"));
    }

    #[test]
    fn accepts_terminal_write_in_same_generation() {
        assert!(!incoming_stamp_is_superseded(
            "root::1::loop::2",
            Some("root::1::loop::2")
        ));
    }

    #[test]
    fn rejects_older_child_loop_generation() {
        assert!(incoming_stamp_is_superseded(
            "root::1::loop::1",
            Some("root::1::loop::2")
        ));
    }

    #[test]
    fn rejects_child_spawned_by_older_root_generation() {
        assert!(incoming_stamp_is_superseded(
            "root::1::loop::5",
            Some("root::2")
        ));
    }

    #[test]
    fn accepts_sibling_scope_in_same_parent_generation() {
        assert!(!incoming_stamp_is_superseded(
            "root::1::left::1",
            Some("root::1::right::2")
        ));
    }

    #[test]
    fn accepts_unparseable_stamp_as_unfenced_for_backward_compatibility() {
        assert!(!incoming_stamp_is_superseded(
            "legacy",
            Some("root::1::loop::2")
        ));
    }

    #[test]
    fn rejects_inner_loop_write_from_older_outer_generation() {
        // Nested loops: an inner (non-root) loop whose outer loop advanced from
        // generation 1 -> 2 is re-spawned under scope root::2::inner. A stale late
        // write from the previous outer generation (root::1::inner::5) must be fenced
        // out even though its own child generation (5) is numerically higher than the
        // current row's child generation (1) -- the deciding factor is that its parent
        // scope was spawned by the older outer generation.
        assert!(incoming_stamp_is_superseded(
            "root::1::inner::5",
            Some("root::2::inner::1")
        ));
    }

    #[test]
    fn accepts_newer_inner_loop_write_from_same_outer_generation() {
        // Same nested shape, but the outer generation matches and the inner
        // generation advanced: this is the current in-flight write and must be
        // accepted, not fenced.
        assert!(!incoming_stamp_is_superseded(
            "root::2::inner::5",
            Some("root::2::inner::1")
        ));
    }

    #[test]
    fn accepts_sibling_branch_nested_under_same_generations() {
        // Two parallel branches (left/right) spawned inside the same inner-loop
        // iteration are independent scopes: neither may fence the other even
        // though their trailing generations differ.
        assert!(!incoming_stamp_is_superseded(
            "root::1::inner::2::left::1",
            Some("root::1::inner::2::right::9")
        ));
    }

    #[test]
    fn sibling_scopes_never_fence_each_other_in_either_direction() {
        assert!(!incoming_stamp_is_superseded(
            "root::0::left::9",
            Some("root::0::right::0")
        ));
        assert!(!incoming_stamp_is_superseded(
            "root::0::right::0",
            Some("root::0::left::9")
        ));
    }

    #[test]
    fn unequal_depth_scopes_have_no_ordering_in_either_direction() {
        assert!(!incoming_stamp_is_superseded(
            "root::0",
            Some("root::0::loop::7")
        ));
        assert!(!incoming_stamp_is_superseded(
            "root::0::loop::7",
            Some("root::0")
        ));
    }

    #[test]
    fn compares_generations_within_same_loop_child() {
        assert!(incoming_stamp_is_superseded(
            "root::0::loop::7",
            Some("root::0::loop::8")
        ));
        assert!(!incoming_stamp_is_superseded(
            "root::0::loop::8",
            Some("root::0::loop::7")
        ));
    }

    #[test]
    fn rejects_join_branch_spawned_by_older_loop_generation() {
        assert!(incoming_stamp_is_superseded(
            "root::0::loop::3::branch::0",
            Some("root::0::loop::4")
        ));
    }

    #[test]
    fn odd_token_count_disables_fence() {
        assert!(stamp_lineage("root::0::loop").is_none());
        assert!(!incoming_stamp_is_superseded(
            "root::0::loop",
            Some("root::0::loop::8")
        ));
    }

    #[test]
    fn nonnumeric_generation_disables_fence() {
        assert!(stamp_lineage("root::generation").is_none());
        assert!(!incoming_stamp_is_superseded(
            "root::generation",
            Some("root::8")
        ));
    }

    #[test]
    fn unparseable_existing_stamp_does_not_fence_valid_incoming_write() {
        assert!(!incoming_stamp_is_superseded(
            "root::8",
            Some("root::generation")
        ));
    }

    #[test]
    fn numeric_node_id_remains_in_node_slot() {
        let (generations, nodes) = stamp_lineage("root::1::12345678::2").unwrap();
        assert_eq!(generations, vec![1, 2]);
        assert_eq!(nodes, vec!["12345678"]);
    }
}
