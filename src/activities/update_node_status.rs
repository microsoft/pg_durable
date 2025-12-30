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

    let update_query = if let Some(res) = result {
        // The result column is JSONB, so we need valid JSON.
        // If the result is already valid JSON, use it directly.
        // If not (e.g., error strings), wrap it as a JSON string.
        let json_result = if serde_json::from_str::<serde_json::Value>(res).is_ok() {
            res.to_string()
        } else {
            // Wrap as JSON string - serde_json::to_string handles escaping
            serde_json::to_string(res).unwrap_or_else(|_| "null".to_string())
        };
        // Use dollar-quoting to avoid SQL escaping issues with JSON
        format!(
            "UPDATE df.nodes SET status = '{status}', result = $json${json_result}$json$::jsonb, updated_at = now() WHERE id = '{node_id}'"
        )
    } else {
        format!(
            "UPDATE df.nodes SET status = '{status}', updated_at = now() WHERE id = '{node_id}'"
        )
    };

    match sqlx::query(&update_query).execute(pool.as_ref()).await {
        Ok(_) => Ok("Node status updated".to_string()),
        Err(e) => {
            let err_msg = format!("Failed to update node status: {e}");
            ctx.trace_info(&err_msg);
            Err(err_msg)
        }
    }
}
