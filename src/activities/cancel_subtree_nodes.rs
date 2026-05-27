//! CancelSubtreeNodes activity - marks all non-terminal nodes in a list as 'cancelled'
//!
//! Used after a RACE winner is determined to clean up the losing branch's node records.

use duroxide::ActivityContext;
use sqlx::PgPool;
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::cancel-subtree-nodes";

/// Mark all non-terminal nodes in `node_ids` as 'cancelled'.
///
/// Nodes that are already in a terminal state (`completed`, `failed`, `cancelled`)
/// are left untouched; only `pending` and `running` nodes are updated.
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    input_json: String,
) -> Result<String, String> {
    let input: serde_json::Value = serde_json::from_str(&input_json)
        .map_err(|e| format!("Failed to parse cancel-subtree-nodes input: {e}"))?;

    let node_ids: Vec<String> = input["node_ids"]
        .as_array()
        .ok_or("Missing node_ids array")?
        .iter()
        .filter_map(|v| v.as_str().map(|s| s.to_string()))
        .collect();

    if node_ids.is_empty() {
        return Ok("No nodes to cancel".to_string());
    }

    ctx.trace_info(format!("Cancelling {} losing-branch nodes", node_ids.len()));

    // Bulk-update only nodes that are still in a non-terminal state so we never
    // overwrite a 'completed', 'failed', or already-'cancelled' node — any of these
    // are terminal and must not be disturbed.
    let result = sqlx::query(
        "UPDATE df.nodes
         SET status = 'cancelled', updated_at = now()
         WHERE id = ANY($1) AND status NOT IN ('completed', 'failed', 'cancelled')",
    )
    .bind(&node_ids[..])
    .execute(pool.as_ref())
    .await;

    match result {
        Ok(r) => {
            ctx.trace_info(format!("Cancelled {} node(s)", r.rows_affected()));
            Ok(format!("Cancelled {} node(s)", r.rows_affected()))
        }
        Err(e) => {
            let err_msg = format!("Failed to cancel subtree nodes: {e}");
            ctx.trace_info(&err_msg);
            Err(err_msg)
        }
    }
}
