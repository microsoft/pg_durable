//! UpdateInstanceStatus activity - updates df.instances status

use duroxide::ActivityContext;
use sqlx::PgPool;
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::update-instance-status";

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

    let query = if status == "completed" {
        sqlx::query(
            "UPDATE df.instances
             SET status = $1, completed_at = now(), updated_at = now()
             WHERE id = $2",
        )
        .bind(status)
        .bind(instance_id)
    } else {
        sqlx::query(
            "UPDATE df.instances
             SET status = $1, updated_at = now()
             WHERE id = $2",
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
