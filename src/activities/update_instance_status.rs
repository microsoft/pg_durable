// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! UpdateInstanceStatus activity - updates df.instances status

use duroxide::ActivityContext;
use sqlx::PgPool;
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::update-instance-status";

/// New binaries can briefly run against an old extension schema before
/// ALTER EXTENSION UPDATE adds this column.
pub async fn instances_have_blocked_on_signal(pool: &PgPool) -> Result<bool, String> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (
             SELECT 1
             FROM pg_catalog.pg_attribute a
             JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
             JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'df'
               AND c.relname = 'instances'
               AND a.attname = 'blocked_on_signal'
               AND NOT a.attisdropped
         )",
    )
    .fetch_one(pool)
    .await
    .map_err(|e| format!("Failed to inspect df.instances columns: {e}"))
}

/// Update the status of an instance in df.instances
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    input_json: String,
) -> Result<String, String> {
    let input: serde_json::Value = serde_json::from_str(&input_json)
        .map_err(|e| format!("Failed to parse status update input: {e}"))?;

    let instance_id = input["instance_id"].as_str().ok_or("Missing instance_id")?;
    let status = input["status"].as_str().ok_or("Missing status")?;

    ctx.trace_info(format!(
        "Updating instance {instance_id} status to {status}"
    ));

    let has_blocked_on_signal = instances_have_blocked_on_signal(pool.as_ref()).await?;

    // Never overwrite a terminal state ('completed', 'failed', 'cancelled') with any status.
    // This prevents a race where an in-flight activity (scheduled just before cancel was
    // processed) tries to flip the status back from 'cancelled' to 'running'/'completed'.
    let clears_blocked_on_signal =
        has_blocked_on_signal && matches!(status, "completed" | "failed" | "cancelled");

    let query = if status == "completed" && clears_blocked_on_signal {
        sqlx::query(
            "UPDATE df.instances
             SET status = $1, completed_at = now(), updated_at = now(), blocked_on_signal = NULL
             WHERE id = $2 AND status NOT IN ('completed', 'failed', 'cancelled')",
        )
        .bind(status)
        .bind(instance_id)
    } else if status == "completed" {
        sqlx::query(
            "UPDATE df.instances
             SET status = $1, completed_at = now(), updated_at = now()
             WHERE id = $2 AND status NOT IN ('completed', 'failed', 'cancelled')",
        )
        .bind(status)
        .bind(instance_id)
    } else if clears_blocked_on_signal {
        sqlx::query(
            "UPDATE df.instances
             SET status = $1, updated_at = now(), blocked_on_signal = NULL
             WHERE id = $2 AND status NOT IN ('completed', 'failed', 'cancelled')",
        )
        .bind(status)
        .bind(instance_id)
    } else {
        sqlx::query(
            "UPDATE df.instances
             SET status = $1, updated_at = now()
             WHERE id = $2 AND status NOT IN ('completed', 'failed', 'cancelled')",
        )
        .bind(status)
        .bind(instance_id)
    };

    match query.execute(pool.as_ref()).await {
        Ok(_) => {
            ctx.trace_info(format!("Instance {instance_id} status updated to {status}"));
            Ok(format!("Status updated to {status}"))
        }
        Err(e) => {
            let err_msg = format!("Failed to update instance status: {e}");
            ctx.trace_info(&err_msg);
            Err(err_msg)
        }
    }
}
