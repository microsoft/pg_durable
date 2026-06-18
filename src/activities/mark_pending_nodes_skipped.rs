// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! MarkPendingNodesSkipped activity - marks unexecuted nodes as skipped
//! after a node-level failure.

use duroxide::ActivityContext;
use sqlx::PgPool;
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::mark-pending-nodes-skipped";

/// Mark pending nodes as skipped for a failed instance.
///
/// Behavior:
/// - No-op on schemas that do not support 'skipped' in nodes_status_chk.
/// - No-op unless the instance has at least one failed node.
/// - Updates only nodes still in 'pending'.
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    input_json: String,
) -> Result<String, String> {
    let input: serde_json::Value = serde_json::from_str(&input_json)
        .map_err(|e| format!("Failed to parse skipped-status input: {e}"))?;

    let instance_id = input["instance_id"].as_str().ok_or("Missing instance_id")?;

    let skipped_supported: bool = sqlx::query_scalar(
        "SELECT COALESCE(
            (
                SELECT pg_catalog.pg_get_constraintdef(c.oid)
                FROM pg_catalog.pg_constraint c
                JOIN pg_catalog.pg_class t ON t.oid = c.conrelid
                JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
                WHERE n.nspname = 'df'
                  AND t.relname = 'nodes'
                  AND c.conname = 'nodes_status_chk'
                LIMIT 1
            ) LIKE '%''skipped''%',
            false
        )",
    )
    .fetch_one(pool.as_ref())
    .await
    .map_err(|e| format!("Failed to detect skipped status support: {e}"))?;

    if !skipped_supported {
        ctx.trace_info(format!(
            "Schema does not support node status 'skipped'; leaving pending nodes unchanged for instance {instance_id}"
        ));
        return Ok("Skipped status unsupported on schema; no-op".to_string());
    }

    let rows_affected = sqlx::query(
        "UPDATE df.nodes n
         SET status = 'skipped', updated_at = now()
         WHERE n.instance_id = $1
           AND n.status = 'pending'
           AND EXISTS (
                SELECT 1
                FROM df.nodes f
                WHERE f.instance_id = $1
                  AND f.status = 'failed'
           )",
    )
    .bind(instance_id)
    .execute(pool.as_ref())
    .await
    .map_err(|e| format!("Failed to mark pending nodes as skipped: {e}"))?
    .rows_affected();

    let msg = format!("Marked {rows_affected} pending nodes as skipped for instance {instance_id}");
    ctx.trace_info(&msg);
    Ok(msg)
}
