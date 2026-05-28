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

    let query = if let Some(res) = result {
        // The result column is JSONB, so normalize invalid JSON payloads into
        // a JSON string before binding.
        let json_result = serde_json::from_str::<serde_json::Value>(res)
            .unwrap_or_else(|_| serde_json::Value::String(res.to_string()));

        sqlx::query(
            "UPDATE df.nodes
             SET status = $1, result = $2::jsonb, updated_at = now()
             WHERE id = $3",
        )
        .bind(status)
        .bind(json_result)
        .bind(node_id)
    } else if status == "running" {
        // When marking as running, clear any stale result from a previous
        // loop iteration to satisfy the constraint:
        // (result IS NULL OR status IN ('completed', 'failed'))
        sqlx::query(
            "UPDATE df.nodes
             SET status = $1, result = NULL, updated_at = now()
             WHERE id = $2",
        )
        .bind(status)
        .bind(node_id)
    } else {
        sqlx::query(
            "UPDATE df.nodes
             SET status = $1, updated_at = now()
             WHERE id = $2",
        )
        .bind(status)
        .bind(node_id)
    };

    match query.execute(pool.as_ref()).await {
        Ok(_) => Ok("Node status updated".to_string()),
        Err(e) => {
            let err_msg = format!("Failed to update node status: {e}");
            ctx.trace_info(&err_msg);
            Err(err_msg)
        }
    }
}
