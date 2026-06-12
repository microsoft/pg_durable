//! GetInstanceState activity - reads status/result for a durable instance

use duroxide::ActivityContext;
use sqlx::{PgPool, Row};
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::get-instance-state";

/// Read the current state of an instance from df.instances/df.nodes.
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    instance_id: String,
) -> Result<String, String> {
    ctx.trace_info(format!("Reading state for instance {instance_id}"));

    let row = sqlx::query(
        r#"SELECT i.status, n.result::text AS result
           FROM df.instances i
           LEFT JOIN df.nodes n ON n.id = i.root_node
           WHERE i.id = $1"#,
    )
    .bind(&instance_id)
    .fetch_optional(pool.as_ref())
    .await
    .map_err(|e| format!("Failed to read instance state for {instance_id}: {e}"))?;

    let Some(row) = row else {
        return Err(format!("Instance not found: {instance_id}"));
    };

    let payload = serde_json::json!({
        "instance_id": instance_id,
        "status": row.get::<String, _>("status"),
        "result": row.get::<Option<String>, _>("result"),
    });

    Ok(payload.to_string())
}
