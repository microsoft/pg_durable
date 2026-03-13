//! LoadFunctionGraph activity - loads graph from df.instances/df.nodes
//!
//! Includes retry logic to handle the race between df.start() enqueuing work
//! and the user's transaction committing.

use duroxide::ActivityContext;
use sqlx::{PgPool, Row};
use std::sync::Arc;

use crate::types::{FunctionGraph, FunctionNode};

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::load-function-graph";

/// Retry configuration for waiting on uncommitted transactions
pub const MAX_WAIT_SECS: u64 = 5;
pub const POLL_INTERVAL_MS: u64 = 100;

/// Load a function graph from the database, with retry logic for transaction visibility
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    instance_id: String,
) -> Result<String, String> {
    ctx.trace_info(format!(
        "Loading function graph for instance: {instance_id}"
    ));

    let instance_query = "SELECT root_node FROM df.instances WHERE id = $1";

    // Retry loop: wait for instance data to appear
    let start_time = std::time::Instant::now();
    let root_node_id: String = loop {
        match sqlx::query_scalar::<_, String>(instance_query)
            .bind(&instance_id)
            .fetch_one(pool.as_ref())
            .await
        {
            Ok(id) => break id,
            Err(e) => {
                let elapsed = start_time.elapsed();
                if elapsed.as_secs() >= MAX_WAIT_SECS {
                    return Err(format!(
                        "Instance {instance_id} not found after {MAX_WAIT_SECS}s (transaction may have been rolled back): {e}"
                    ));
                }
                // Log first retry and then every second
                if elapsed.as_millis() < POLL_INTERVAL_MS as u128 * 2 {
                    ctx.trace_info(format!(
                        "Instance {instance_id} not yet visible, waiting for transaction commit..."
                    ));
                }
                tokio::time::sleep(std::time::Duration::from_millis(POLL_INTERVAL_MS)).await;
            }
        }
    };

    let nodes_query = r#"SELECT id, node_type, query, result_name,
           left_node, right_node,
           submitted_by::text AS submitted_by,
           login_role::text AS login_role,
           database
        FROM df.nodes WHERE instance_id = $1"#;

    let rows = match sqlx::query(nodes_query)
        .bind(&instance_id)
        .fetch_all(pool.as_ref())
        .await
    {
        Ok(rows) => rows,
        Err(e) => return Err(format!("Failed to load function nodes: {e}")),
    };

    let mut nodes = std::collections::BTreeMap::new();
    for row in rows {
        let id: String = row.get("id");
        let node = FunctionNode {
            id: id.clone(),
            node_type: row.get("node_type"),
            query: row.get("query"),
            result_name: row.get("result_name"),
            left_node: row.get("left_node"),
            right_node: row.get("right_node"),
            submitted_by: row.get::<String, _>("submitted_by"),
            login_role: row.get::<String, _>("login_role"),
            database: row.get("database"),
        };
        nodes.insert(id, node);
    }

    let graph = FunctionGraph {
        instance_id,
        root_node_id,
        nodes,
    };

    ctx.trace_info(format!(
        "Loaded function graph with {} nodes",
        graph.nodes.len()
    ));

    serde_json::to_string(&graph).map_err(|e| format!("Failed to serialize graph: {e}"))
}
