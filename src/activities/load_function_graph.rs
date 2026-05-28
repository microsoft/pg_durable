// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! LoadFunctionGraph activity - loads graph from df.instances/df.nodes
//!
//! Includes retry logic to handle the race between df.start() enqueuing work
//! and the user's transaction committing.

use duroxide::ActivityContext;
use sqlx::{PgPool, Row};
use std::sync::Arc;

use crate::types::{
    is_role_superuser_name, superuser_instances_enabled, FunctionGraph, FunctionNode,
};

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

    let instance_query = "SELECT root_node, r.rolname AS submitted_by
        FROM df.instances i
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = i.submitted_by::oid
        WHERE i.id = $1";

    // Retry loop: wait for instance data to appear
    let start_time = std::time::Instant::now();
    let (root_node_id, instance_submitted_by): (String, String) = loop {
        match sqlx::query(instance_query)
            .bind(&instance_id)
            .fetch_optional(pool.as_ref())
            .await
        {
            Ok(Some(row)) => {
                let submitted_by: Option<String> = row.get("submitted_by");
                match submitted_by {
                    Some(name) => break (row.get("root_node"), name),
                    None => {
                        return Err(format!(
                        "Instance {instance_id}: submitted_by role no longer exists in pg_roles"
                    ))
                    }
                }
            }
            Ok(None) => {
                let elapsed = start_time.elapsed();
                if elapsed.as_secs() >= MAX_WAIT_SECS {
                    return Err(format!(
                        "Instance {instance_id} not found after {MAX_WAIT_SECS}s (transaction may have been rolled back)"
                    ));
                }
                if elapsed.as_millis() < POLL_INTERVAL_MS as u128 * 2 {
                    ctx.trace_info(format!(
                        "Instance {instance_id} not yet visible, waiting for transaction commit..."
                    ));
                }
                tokio::time::sleep(std::time::Duration::from_millis(POLL_INTERVAL_MS)).await;
            }
            Err(e) => {
                let elapsed = start_time.elapsed();
                if elapsed.as_secs() >= MAX_WAIT_SECS {
                    return Err(format!(
                        "Instance {instance_id} not found after {MAX_WAIT_SECS}s: {e}"
                    ));
                }
                tokio::time::sleep(std::time::Duration::from_millis(POLL_INTERVAL_MS)).await;
            }
        }
    };

    // Worker-side superuser guard: reject before executing any user SQL.
    // This closes the forgery path where a BYPASSRLS role inserts rows with
    // submitted_by = <superuser> directly, bypassing the df.start() check.
    if !superuser_instances_enabled() {
        match is_role_superuser_name(pool.as_ref(), &instance_submitted_by).await {
            Ok(true) => {
                return Err(format!(
                    "pg_durable blocked instance {instance_id}: submitted_by role \
                     \"{instance_submitted_by}\" is a superuser, but \
                     pg_durable.enable_superuser_instances is off"
                ));
            }
            Ok(false) => {}
            Err(e) => {
                return Err(format!(
                    "pg_durable: superuser check failed for instance {instance_id}: {e}"
                ));
            }
        }
    }

    let nodes_query = r#"SELECT n.id, n.node_type, n.query, n.result_name,
           n.left_node, n.right_node,
           r.rolname AS submitted_by,
           n.database
        FROM df.nodes n
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = n.submitted_by::oid
        WHERE n.instance_id = $1"#;

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
        let submitted_by: Option<String> = row.get("submitted_by");
        let submitted_by = match submitted_by {
            Some(name) => name,
            None => {
                return Err(format!(
                "Instance {instance_id}: node {id} submitted_by role no longer exists in pg_roles"
            ))
            }
        };

        // No per-node superuser check needed: a composite FK
        //   (instance_id, submitted_by) REFERENCES df.instances (id, submitted_by)
        // guarantees every node shares the instance's submitted_by.
        // The instance-level check above already covers the superuser case.

        let node = FunctionNode {
            id: id.clone(),
            node_type: row.get("node_type"),
            query: row.get("query"),
            result_name: row.get("result_name"),
            left_node: row.get("left_node"),
            right_node: row.get("right_node"),
            submitted_by,
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
