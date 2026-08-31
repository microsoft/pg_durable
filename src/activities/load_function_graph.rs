// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! LoadFunctionGraph activity - loads graph from df.instances/df.nodes
//!
//! Includes retry logic to handle the race between df.start() enqueuing work
//! and the user's transaction committing.

use duroxide::ActivityContext;
use sqlx::{PgPool, Row};
use std::sync::Arc;
use std::time::Duration;

use crate::types::{
    is_role_superuser_name, superuser_instances_enabled, FunctionGraph, FunctionNode,
};

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::load-function-graph";
/// Transaction-aware graph probe used only by inputs created by the current binary.
pub const TRANSACTION_AWARE_NAME: &str =
    "pg_durable::activity::probe-function-graph-transaction-v1";
const TRANSACTION_PROBE_QUERY_TIMEOUT: Duration = Duration::from_secs(2);

/// Retry configuration for waiting on uncommitted transactions
pub const MAX_WAIT_SECS: u64 = 5;
pub const POLL_INTERVAL_MS: u64 = 100;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TransactionAwareLoadInput {
    pub instance_id: String,
    pub origin_xid: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TransactionGraphProbe {
    Ready { graph: String },
    InProgress,
    Retry,
    Aborted,
    CommittedMissing,
}

#[derive(Debug)]
enum LoadGraphError {
    Retryable(String),
    Permanent(String),
}

impl LoadGraphError {
    fn into_message(self) -> String {
        match self {
            Self::Retryable(message) | Self::Permanent(message) => message,
        }
    }
}

const INSTANCE_QUERY: &str = "SELECT root_node, r.rolname AS submitted_by
    FROM df.instances i
    LEFT JOIN pg_catalog.pg_roles r ON r.oid = i.submitted_by::oid
    WHERE i.id = $1";

async fn find_visible_instance(
    pool: &PgPool,
    instance_id: &str,
) -> Result<Option<sqlx::postgres::PgRow>, sqlx::Error> {
    sqlx::query(INSTANCE_QUERY)
        .bind(instance_id)
        .fetch_optional(pool)
        .await
}

async fn load_visible_graph(
    ctx: &ActivityContext,
    pool: &PgPool,
    instance_id: String,
    instance_row: sqlx::postgres::PgRow,
) -> Result<String, LoadGraphError> {
    let root_node_id: String = instance_row.get("root_node");
    let instance_submitted_by: Option<String> = instance_row.get("submitted_by");
    let instance_submitted_by = instance_submitted_by.ok_or_else(|| {
        LoadGraphError::Permanent(format!(
            "Instance {instance_id}: submitted_by role no longer exists in pg_roles"
        ))
    })?;

    // Worker-side superuser guard: reject before executing any user SQL.
    // This closes the forgery path where a BYPASSRLS role inserts rows with
    // submitted_by = <superuser> directly, bypassing the df.start() check.
    if !superuser_instances_enabled() {
        match is_role_superuser_name(pool, &instance_submitted_by).await {
            Ok(true) => {
                return Err(LoadGraphError::Permanent(format!(
                    "pg_durable blocked instance {instance_id}: submitted_by role \
                     \"{instance_submitted_by}\" is a superuser, but \
                     pg_durable.enable_superuser_instances is off"
                )));
            }
            Ok(false) => {}
            Err(e) => {
                return Err(LoadGraphError::Retryable(format!(
                    "pg_durable: superuser check failed for instance {instance_id}: {e}"
                )));
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

    let rows = sqlx::query(nodes_query)
        .bind(&instance_id)
        .fetch_all(pool)
        .await
        .map_err(|e| LoadGraphError::Retryable(format!("Failed to load function nodes: {e}")))?;

    let mut nodes = std::collections::BTreeMap::new();
    for row in rows {
        let id: String = row.get("id");
        let submitted_by: Option<String> = row.get("submitted_by");
        let submitted_by = submitted_by.ok_or_else(|| {
            LoadGraphError::Permanent(format!(
                "Instance {instance_id}: node {id} submitted_by role no longer exists in pg_roles"
            ))
        })?;

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

    serde_json::to_string(&graph)
        .map_err(|e| LoadGraphError::Permanent(format!("Failed to serialize graph: {e}")))
}

/// Load a function graph from the database, with retry logic for transaction visibility
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    instance_id: String,
) -> Result<String, String> {
    ctx.trace_info(format!(
        "Loading function graph for instance: {instance_id}"
    ));

    // Retry loop: wait for instance data to appear
    let start_time = std::time::Instant::now();
    let instance_row = loop {
        match find_visible_instance(pool.as_ref(), &instance_id).await {
            Ok(Some(row)) => break row,
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

    load_visible_graph(&ctx, pool.as_ref(), instance_id, instance_row)
        .await
        .map_err(LoadGraphError::into_message)
}

fn serialize_probe(probe: &TransactionGraphProbe) -> Result<String, String> {
    serde_json::to_string(probe).map_err(|e| format!("Failed to serialize graph probe result: {e}"))
}

fn retry_probe(
    ctx: &ActivityContext,
    operation: &str,
    instance_id: &str,
    error: impl std::fmt::Display,
) -> Result<String, String> {
    ctx.trace_info(format!(
        "Transient {operation} failure for instance {instance_id}; graph probe will retry: {error}"
    ));
    serialize_probe(&TransactionGraphProbe::Retry)
}

/// Probe graph visibility without pinning an activity task while the caller's
/// transaction remains open. The orchestration schedules a durable timer and
/// invokes this single-shot activity again when the xid is still in progress.
pub async fn probe_transaction(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    input_json: String,
) -> Result<String, String> {
    let input: TransactionAwareLoadInput = serde_json::from_str(&input_json)
        .map_err(|e| format!("Invalid transaction-aware graph probe input: {e}"))?;
    if input.origin_xid.parse::<u64>().is_err() {
        return Err(format!(
            "Invalid origin transaction id \"{}\" for instance {}",
            input.origin_xid, input.instance_id
        ));
    }

    ctx.trace_info(format!(
        "Probing graph visibility for instance {} from origin transaction {}",
        input.instance_id, input.origin_xid
    ));

    let visible = match tokio::time::timeout(
        TRANSACTION_PROBE_QUERY_TIMEOUT,
        find_visible_instance(pool.as_ref(), &input.instance_id),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => {
            return retry_probe(
                &ctx,
                "graph visibility check",
                &input.instance_id,
                "timed out after 2s",
            );
        }
    };

    match visible {
        Ok(Some(row)) => {
            let loaded = match tokio::time::timeout(
                TRANSACTION_PROBE_QUERY_TIMEOUT,
                load_visible_graph(&ctx, pool.as_ref(), input.instance_id.clone(), row),
            )
            .await
            {
                Ok(result) => result,
                Err(_) => {
                    return retry_probe(
                        &ctx,
                        "graph load",
                        &input.instance_id,
                        "timed out after 2s",
                    );
                }
            };
            return match loaded {
                Ok(graph) => serialize_probe(&TransactionGraphProbe::Ready { graph }),
                Err(LoadGraphError::Retryable(error)) => {
                    retry_probe(&ctx, "graph load", &input.instance_id, error)
                }
                Err(LoadGraphError::Permanent(error)) => Err(error),
            };
        }
        Ok(None) => {}
        Err(e) => {
            return retry_probe(&ctx, "graph visibility check", &input.instance_id, e);
        }
    }

    let transaction_status_query = tokio::time::timeout(
        TRANSACTION_PROBE_QUERY_TIMEOUT,
        sqlx::query_scalar("SELECT pg_catalog.pg_xact_status($1::text::xid8)::text")
            .bind(&input.origin_xid)
            .fetch_one(pool.as_ref()),
    )
    .await;
    let transaction_status: Option<String> = match transaction_status_query {
        Ok(Ok(status)) => status,
        Ok(Err(e)) => {
            return retry_probe(&ctx, "origin transaction check", &input.instance_id, e);
        }
        Err(_) => {
            return retry_probe(
                &ctx,
                "origin transaction check",
                &input.instance_id,
                "timed out after 2s",
            );
        }
    };

    let probe = match transaction_status.as_deref() {
        Some("in progress") => TransactionGraphProbe::InProgress,
        Some("aborted") => TransactionGraphProbe::Aborted,
        Some("committed") => {
            // The status and graph reads use separate READ COMMITTED statements.
            // Re-read once after observing commit so a commit between the first
            // graph query and pg_xact_status cannot be misclassified as missing.
            let visible = match tokio::time::timeout(
                TRANSACTION_PROBE_QUERY_TIMEOUT,
                find_visible_instance(pool.as_ref(), &input.instance_id),
            )
            .await
            {
                Ok(result) => result,
                Err(_) => {
                    return retry_probe(
                        &ctx,
                        "post-commit graph visibility check",
                        &input.instance_id,
                        "timed out after 2s",
                    );
                }
            };
            match visible {
                Ok(Some(row)) => {
                    let loaded = match tokio::time::timeout(
                        TRANSACTION_PROBE_QUERY_TIMEOUT,
                        load_visible_graph(&ctx, pool.as_ref(), input.instance_id.clone(), row),
                    )
                    .await
                    {
                        Ok(result) => result,
                        Err(_) => {
                            return retry_probe(
                                &ctx,
                                "post-commit graph load",
                                &input.instance_id,
                                "timed out after 2s",
                            );
                        }
                    };
                    match loaded {
                        Ok(graph) => TransactionGraphProbe::Ready { graph },
                        Err(LoadGraphError::Retryable(error)) => {
                            return retry_probe(
                                &ctx,
                                "post-commit graph load",
                                &input.instance_id,
                                error,
                            );
                        }
                        Err(LoadGraphError::Permanent(error)) => return Err(error),
                    }
                }
                Ok(None) => TransactionGraphProbe::CommittedMissing,
                Err(e) => {
                    return retry_probe(
                        &ctx,
                        "post-commit graph visibility check",
                        &input.instance_id,
                        e,
                    );
                }
            }
        }
        Some(other) => {
            return Err(format!(
                "Origin transaction {} for instance {} has unknown status \"{}\"",
                input.origin_xid, input.instance_id, other
            ))
        }
        None => {
            return Err(format!(
                "Origin transaction {} for instance {} has no available status",
                input.origin_xid, input.instance_id
            ))
        }
    };

    serialize_probe(&probe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transaction_probe_input_round_trips() {
        let input = TransactionAwareLoadInput {
            instance_id: "deadbeef".to_string(),
            origin_xid: "12345".to_string(),
        };
        let json = serde_json::to_string(&input).unwrap();
        assert_eq!(
            serde_json::from_str::<TransactionAwareLoadInput>(&json).unwrap(),
            input
        );
    }

    #[test]
    fn transaction_probe_results_have_stable_tags() {
        assert_eq!(
            serde_json::to_string(&TransactionGraphProbe::InProgress).unwrap(),
            r#"{"state":"in_progress"}"#
        );
        assert_eq!(
            serde_json::to_string(&TransactionGraphProbe::Aborted).unwrap(),
            r#"{"state":"aborted"}"#
        );
        assert_eq!(
            serde_json::to_string(&TransactionGraphProbe::Retry).unwrap(),
            r#"{"state":"retry"}"#
        );
        assert_eq!(
            serde_json::to_string(&TransactionGraphProbe::CommittedMissing).unwrap(),
            r#"{"state":"committed_missing"}"#
        );
    }
}
