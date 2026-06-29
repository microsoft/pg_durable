// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Monitoring functions for pg_durable - using Duroxide Client Management API

#![allow(clippy::type_complexity)] // Required for pgrx TableIterator return types

use duroxide::Client;
use pgrx::datum::TimestampWithTimeZone;
use pgrx::prelude::*;
use std::collections::HashMap;

use crate::types::{backend_duroxide_schema, new_backend_provider, postgres_connection_string};

// ============================================================================
// Monitoring Functions
// ============================================================================

/// List all durable function instances, optionally filtered by status.
#[pg_extern(schema = "df")]
pub fn list_instances(
    status_filter: default!(Option<&str>, "NULL"),
    limit_count: default!(i32, "100"),
) -> TableIterator<
    'static,
    (
        name!(instance_id, String),
        name!(label, Option<String>),
        name!(function_name, String),
        name!(status, String),
        name!(execution_count, i64),
        name!(output, Option<String>),
    ),
> {
    if limit_count < 1 {
        pgrx::error!("limit_count must be at least 1");
    }
    let limit_count = limit_count.min(10000);

    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();

    // Query df.instances via SPI first — RLS filters to calling user's rows only.
    // We also fetch status here so that all three monitoring APIs (df.status(),
    // df.list_instances(), df.instance_info()) share the same authoritative source
    // for the status column, eliminating the vocabulary mismatch between
    // df.instances.status ('cancelled') and duroxide executions.status ('Failed').
    let user_instances: Vec<(String, Option<String>, String)> = Spi::connect(|client| {
        use pgrx::datum::DatumWithOid;

        let (sql, args): (&str, Vec<DatumWithOid>) = if let Some(status) = status_filter {
            (
                "SELECT id, label, status FROM df.instances WHERE status = $1 ORDER BY created_at DESC LIMIT $2",
                vec![status.into(), (limit_count as i64).into()],
            )
        } else {
            (
                "SELECT id, label, status FROM df.instances ORDER BY created_at DESC LIMIT $1",
                vec![(limit_count as i64).into()],
            )
        };
        let mut instances = Vec::new();
        if let Ok(table) = client.select(sql, None, &args) {
            for row in table {
                if let Ok(Some(id)) = row.get::<String>(1) {
                    let label: Option<String> = row.get(2).ok().flatten();
                    let status: String = row.get(3).ok().flatten().unwrap_or_default();
                    instances.push((id, label, status));
                }
            }
        }
        instances
    });

    if user_instances.is_empty() {
        return TableIterator::new(vec![]);
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return TableIterator::new(vec![]),
    };

    let results = rt.block_on(async {
        let store = match new_backend_provider(&pg_conn_str, provider_schema).await {
            Ok(s) => s,
            Err(_) => return vec![],
        };

        let client = Client::new(store);

        let mut rows = Vec::new();
        // Only query duroxide for function_name, execution_count, and output.
        // Status is read from df.instances (already fetched above) to ensure all
        // monitoring APIs agree on the status value.
        for (id, label, df_status) in &user_instances {
            if let Ok(info) = client.get_instance_info(id).await {
                rows.push((
                    info.instance_id,
                    label.clone(),
                    info.orchestration_name,
                    df_status.clone(),
                    info.current_execution_id as i64,
                    info.output,
                ));
            }
        }
        rows
    });

    TableIterator::new(results)
}

/// Get detailed info about a specific durable function instance.
#[pg_extern(schema = "df")]
pub fn instance_info(
    instance_id: &str,
) -> TableIterator<
    'static,
    (
        name!(instance_id, String),
        name!(label, Option<String>),
        name!(function_name, String),
        name!(function_version, String),
        name!(current_execution_id, i64),
        name!(status, String),
        name!(output, Option<String>),
    ),
> {
    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();
    let instance_id_str = instance_id.to_string();

    // Ownership check: SPI goes through RLS, returning NULL for non-owned instances.
    // Also fetch status here so that df.instance_info() uses df.instances as the
    // authoritative status source, consistent with df.status() and df.list_instances().
    let row: Option<(Option<String>, String)> = Spi::connect(|client| {
        client
            .select(
                "SELECT label, status FROM df.instances WHERE id = $1",
                Some(1),
                &[instance_id.into()],
            )
            .ok()
            .and_then(|table| {
                table.into_iter().next().map(|row| {
                    // SPI row columns are 1-based: col 1 = label, col 2 = status
                    let label: Option<String> = row.get(1).ok().flatten();
                    let status: String = row.get(2).ok().flatten().unwrap_or_default();
                    (label, status)
                })
            })
    });

    let (label, df_status) = match row {
        Some(r) => r,
        None => return TableIterator::new(vec![]),
    };

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return TableIterator::new(vec![]),
    };

    let results = rt.block_on(async {
        let store = match new_backend_provider(&pg_conn_str, provider_schema).await {
            Ok(s) => s,
            Err(_) => return vec![],
        };

        let client = Client::new(store);

        match client.get_instance_info(&instance_id_str).await {
            Ok(info) => vec![(
                info.instance_id,
                label,
                info.orchestration_name,
                info.orchestration_version,
                info.current_execution_id as i64,
                df_status,
                info.output,
            )],
            Err(_) => vec![],
        }
    });

    TableIterator::new(results)
}

/// Get the last N executions for an eternal durable function (loop).
///
/// Distinguishes "this instance genuinely has no execution history yet" (empty
/// rowset) from "the execution-history lookup failed" (explicit error). The
/// latter — failing to build the runtime, connect to the duroxide store, list
/// executions, or fetch a specific execution's info — now raises an error
/// instead of being silently swallowed into an empty rowset. A completed
/// instance always has at least one execution row, so an empty result for one
/// previously masked a real lookup failure. See issue #168.
#[pg_extern(schema = "df")]
pub fn instance_executions(
    instance_id: &str,
    limit_count: default!(i32, "5"),
) -> TableIterator<
    'static,
    (
        name!(execution_id, i64),
        name!(status, String),
        name!(event_count, i64),
        name!(duration_ms, i64),
        name!(output, Option<String>),
    ),
> {
    if limit_count < 1 {
        pgrx::error!("limit_count must be at least 1");
    }
    let limit_count = limit_count.min(10000);

    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();
    let instance_id_owned = instance_id.to_string();

    // Ownership check: SPI goes through RLS, so non-owned instances are invisible.
    // A non-existent or non-owned instance legitimately has no history to show,
    // so an empty rowset (not an error) is the correct response here.
    let exists: bool = Spi::get_one_with_args(
        "SELECT EXISTS(SELECT 1 FROM df.instances WHERE id = $1)",
        &[instance_id.into()],
    )
    .ok()
    .flatten()
    .unwrap_or(false);

    if !exists {
        return TableIterator::new(vec![]);
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => pgrx::error!("failed to create async runtime for instance_executions: {e}"),
    };

    let results: Result<Vec<(i64, String, i64, i64, Option<String>)>, String> =
        rt.block_on(async {
            let store = new_backend_provider(&pg_conn_str, provider_schema).await?;

            let client = Client::new(store);

            let execution_ids = client
                .list_executions(&instance_id_owned)
                .await
                .map_err(|e| format!("failed to list executions: {e:?}"))?;

            let mut sorted_ids: Vec<_> = execution_ids.into_iter().collect();
            sorted_ids.sort_by(|a, b| b.cmp(a));
            let limited: Vec<_> = sorted_ids.into_iter().take(limit_count as usize).collect();

            let mut rows = Vec::new();
            for exec_id in limited {
                let info = client
                    .get_execution_info(&instance_id_owned, exec_id)
                    .await
                    .map_err(|e| format!("failed to fetch info for execution {exec_id}: {e:?}"))?;

                let duration_ms = info
                    .completed_at
                    .map(|end| end.saturating_sub(info.started_at))
                    .unwrap_or(0);

                rows.push((
                    info.execution_id as i64,
                    info.status,
                    info.event_count as i64,
                    duration_ms as i64,
                    info.output,
                ));
            }
            Ok(rows)
        });

    match results {
        Ok(rows) => TableIterator::new(rows),
        Err(e) => pgrx::error!("df.instance_executions: execution history lookup failed: {e}"),
    }
}

/// Get system-wide durable function metrics.
///
/// Access is controlled by PostgreSQL function privileges. Roles with ordinary
/// df usage can call `df.list_instances()` to see counts scoped to their own
/// workflows; `df.metrics()` should be granted only to roles that may see
/// system-wide aggregate counts.
#[pg_extern(schema = "df")]
pub fn metrics() -> TableIterator<
    'static,
    (
        name!(total_instances, i64),
        name!(running_instances, i64),
        name!(completed_instances, i64),
        name!(failed_instances, i64),
        name!(total_executions, i64),
        name!(total_events, i64),
    ),
> {
    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return TableIterator::new(vec![]),
    };

    let results = rt.block_on(async {
        let store = match new_backend_provider(&pg_conn_str, provider_schema).await {
            Ok(s) => s,
            Err(_) => return vec![],
        };

        let client = Client::new(store);

        match client.get_system_metrics().await {
            Ok(m) => vec![(
                m.total_instances as i64,
                m.running_instances as i64,
                m.completed_instances as i64,
                m.failed_instances as i64,
                m.total_executions as i64,
                m.total_events as i64,
            )],
            Err(_) => vec![],
        }
    });

    TableIterator::new(results)
}

struct NodeRow {
    id: String,
    node_type: String,
    query: Option<String>,
    result_name: Option<String>,
    left_node: Option<String>,
    right_node: Option<String>,
    status: Option<String>,
    result: Option<String>,
    status_details: Option<String>,
    updated_at: Option<TimestampWithTimeZone>,
}

impl crate::node_status::NodeFacts for NodeRow {
    fn node_type(&self) -> &str {
        &self.node_type
    }
    fn query(&self) -> Option<&str> {
        self.query.as_deref()
    }
    fn left_node(&self) -> Option<&str> {
        self.left_node.as_deref()
    }
    fn right_node(&self) -> Option<&str> {
        self.right_node.as_deref()
    }
    fn status(&self) -> Option<&str> {
        self.status.as_deref()
    }
    fn status_details(&self) -> Option<&str> {
        self.status_details.as_deref()
    }
}

fn load_instance_nodes(instance_id: &str) -> (Option<String>, Vec<NodeRow>) {
    Spi::connect(|client| {
        let status_details_expr = crate::node_status::status_details_select_expr(client);
        let node_sql = format!(
            "SELECT id, node_type, query, result_name, left_node, right_node,
                    status, result::text, {status_details_expr}, updated_at
             FROM df.nodes WHERE instance_id = $1"
        );
        let mut nodes = Vec::new();
        if let Ok(table) = client.select(&node_sql, None, &[instance_id.into()]) {
            for row in table {
                if let Ok(Some(id)) = row.get::<String>(1) {
                    nodes.push(NodeRow {
                        id,
                        node_type: row.get::<String>(2).ok().flatten().unwrap_or_default(),
                        query: row.get(3).ok().flatten(),
                        result_name: row.get(4).ok().flatten(),
                        left_node: row.get(5).ok().flatten(),
                        right_node: row.get(6).ok().flatten(),
                        status: row.get(7).ok().flatten(),
                        result: row.get(8).ok().flatten(),
                        status_details: row.get(9).ok().flatten(),
                        updated_at: row.get(10).ok().flatten(),
                    });
                }
            }
        }

        let mut root: Option<String> = None;
        if let Ok(table) = client.select(
            "SELECT root_node FROM df.instances WHERE id = $1",
            None,
            &[instance_id.into()],
        ) {
            if let Some(row) = table.into_iter().next() {
                root = row.get::<String>(1).ok().flatten();
            }
        }

        (root, nodes)
    })
}

/// Get one row per node, with stored status plus read-time inferred status.
#[pg_extern(name = "instance_nodes", schema = "df")]
pub fn instance_nodes_v2(
    instance_id_param: &str,
) -> TableIterator<
    'static,
    (
        name!(node_id, String),
        name!(node_type, String),
        name!(query, Option<String>),
        name!(result_name, Option<String>),
        name!(left_node, Option<String>),
        name!(right_node, Option<String>),
        name!(status, Option<String>),
        name!(result, Option<String>),
        name!(status_details, Option<String>),
        name!(inferred_status, String),
        name!(inferred_status_from_ancestor_id, Option<String>),
        name!(updated_at, Option<pgrx::datum::TimestampWithTimeZone>),
    ),
> {
    use crate::node_status::infer_statuses;

    let (root_node, node_rows) = load_instance_nodes(instance_id_param);
    let nodes: HashMap<String, NodeRow> =
        node_rows.into_iter().map(|n| (n.id.clone(), n)).collect();

    // Shared with df.explain() so both views agree on skipped/superseded nodes.
    let inferred = infer_statuses(root_node.as_deref(), &nodes);

    type Row = (
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
        Option<TimestampWithTimeZone>,
    );

    let mut rows: Vec<Row> = Vec::with_capacity(nodes.len());
    for (id, n) in &nodes {
        let inf = inferred.get(id);
        let inferred_status = inf
            .map(|i| i.status.clone())
            .unwrap_or_else(|| n.status.clone().unwrap_or_else(|| "pending".to_string()));
        let from_anc = inf.and_then(|i| i.from_ancestor_id.clone());
        rows.push((
            id.clone(),
            n.node_type.clone(),
            n.query.clone(),
            n.result_name.clone(),
            n.left_node.clone(),
            n.right_node.clone(),
            n.status.clone(),
            n.result.clone(),
            n.status_details.clone(),
            inferred_status,
            from_anc,
            n.updated_at,
        ));
    }

    TableIterator::new(rows)
}

/// Compatibility wrapper for df.instance_nodes(text, integer).
///
/// A pure projection of df.nodes in the pre-0.2.4 result shape: no inference, no
/// execution-history fan-out, and a constant execution_id of 1. It selects only
/// columns present in every 0.2.x schema, so it behaves identically whether the
/// running schema has df.nodes.status_details (0.2.4) or not (0.2.3 under a newer
/// .so) — no column probe required. last_n_executions is ignored.
#[pg_extern(schema = "df")]
pub fn instance_nodes(
    instance_id_param: &str,
    _last_n_executions: i32,
) -> TableIterator<
    'static,
    (
        name!(execution_id, i64),
        name!(node_id, String),
        name!(node_type, String),
        name!(query, Option<String>),
        name!(result_name, Option<String>),
        name!(left_node, Option<String>),
        name!(right_node, Option<String>),
        name!(status, Option<String>),
        name!(result, Option<String>),
        name!(updated_at, Option<pgrx::datum::TimestampWithTimeZone>),
    ),
> {
    type CompatRow = (
        i64,
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<TimestampWithTimeZone>,
    );

    let instance_id = instance_id_param.to_string();
    let rows: Vec<CompatRow> = Spi::connect(|client| {
        let sql = "SELECT id, node_type, query, result_name, left_node, right_node,
                          status, result::text, updated_at
                   FROM df.nodes WHERE instance_id = $1";
        let mut rows = Vec::new();
        if let Ok(table) = client.select(sql, None, &[instance_id.as_str().into()]) {
            for row in table {
                if let Ok(Some(id)) = row.get::<String>(1) {
                    rows.push((
                        1i64,
                        id,
                        row.get::<String>(2).ok().flatten().unwrap_or_default(),
                        row.get(3).ok().flatten(),
                        row.get(4).ok().flatten(),
                        row.get(5).ok().flatten(),
                        row.get(6).ok().flatten(),
                        row.get(7).ok().flatten(),
                        row.get(8).ok().flatten(),
                        row.get(9).ok().flatten(),
                    ));
                }
            }
        }
        rows
    });

    TableIterator::new(rows)
}
