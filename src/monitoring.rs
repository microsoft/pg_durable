//! Monitoring functions for pg_durable - using Duroxide Client Management API

#![allow(clippy::type_complexity)] // Required for pgrx TableIterator return types

use duroxide::Client;
use pgrx::prelude::*;

use crate::types::{new_backend_provider, postgres_connection_string};

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
        let store = match new_backend_provider(&pg_conn_str).await {
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
        let store = match new_backend_provider(&pg_conn_str).await {
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
    let pg_conn_str = postgres_connection_string();
    let instance_id_owned = instance_id.to_string();

    // Ownership check: SPI goes through RLS, so non-owned instances are invisible.
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
        Err(_) => return TableIterator::new(vec![]),
    };

    let results = rt.block_on(async {
        let store = match new_backend_provider(&pg_conn_str).await {
            Ok(s) => s,
            Err(_) => return vec![],
        };

        let client = Client::new(store);

        let execution_ids = match client.list_executions(&instance_id_owned).await {
            Ok(ids) => ids,
            Err(_) => return vec![],
        };

        let mut sorted_ids: Vec<_> = execution_ids.into_iter().collect();
        sorted_ids.sort_by(|a, b| b.cmp(a));
        let limited: Vec<_> = sorted_ids.into_iter().take(limit_count as usize).collect();

        let mut rows = Vec::new();
        for exec_id in limited {
            if let Ok(info) = client.get_execution_info(&instance_id_owned, exec_id).await {
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
        }
        rows
    });

    TableIterator::new(results)
}

/// Get system-wide durable function metrics.
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

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return TableIterator::new(vec![]),
    };

    let results = rt.block_on(async {
        let store = match new_backend_provider(&pg_conn_str).await {
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

/// Get function nodes for an instance with execution history.
#[pg_extern(schema = "df")]
pub fn instance_nodes(
    instance_id_param: &str,
    last_n_executions: default!(i32, "5"),
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
    use pgrx::datum::TimestampWithTimeZone;

    let instance_id = instance_id_param.to_string();
    let pg_conn_str = postgres_connection_string();

    // Get node definitions from PostgreSQL (including status, result and updated_at)
    let node_defs: Vec<(
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<TimestampWithTimeZone>,
    )> = Spi::connect(|client| {
        let sql = r#"SELECT id, node_type, query, result_name, left_node, right_node, status, result::text, updated_at
                   FROM df.nodes WHERE instance_id = $1"#;
        let mut nodes = Vec::new();
        if let Ok(table) = client.select(sql, None, &[instance_id.as_str().into()]) {
            for row in table {
                if let Ok(Some(id)) = row.get::<String>(1) {
                    let node_type: String = row.get(2).ok().flatten().unwrap_or_default();
                    let query: Option<String> = row.get(3).ok().flatten();
                    let result_name: Option<String> = row.get(4).ok().flatten();
                    let left_node: Option<String> = row.get(5).ok().flatten();
                    let right_node: Option<String> = row.get(6).ok().flatten();
                    let node_status: Option<String> = row.get(7).ok().flatten();
                    let node_result: Option<String> = row.get(8).ok().flatten();
                    let updated_at: Option<TimestampWithTimeZone> = row.get(9).ok().flatten();
                    nodes.push((
                        id,
                        node_type,
                        query,
                        result_name,
                        left_node,
                        right_node,
                        node_status,
                        node_result,
                        updated_at,
                    ));
                }
            }
        }
        nodes
    });

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return TableIterator::new(vec![]),
    };

    let results = rt.block_on(async {
        let store = match new_backend_provider(&pg_conn_str).await {
            Ok(s) => s,
            Err(_) => return vec![],
        };

        let client = Client::new(store);

        let execution_ids = match client.list_executions(&instance_id).await {
            Ok(ids) => ids,
            Err(_) => return vec![],
        };

        let mut sorted_ids: Vec<_> = execution_ids.into_iter().collect();
        sorted_ids.sort_by(|a, b| b.cmp(a));
        let limited: Vec<_> = sorted_ids
            .into_iter()
            .take(last_n_executions as usize)
            .collect();

        let mut rows = Vec::new();

        for exec_id in limited {
            for (
                node_id,
                node_type,
                query,
                result_name,
                left_node,
                right_node,
                node_status,
                node_result,
                updated_at,
            ) in &node_defs
            {
                rows.push((
                    exec_id as i64,
                    node_id.clone(),
                    node_type.clone(),
                    query.clone(),
                    result_name.clone(),
                    left_node.clone(),
                    right_node.clone(),
                    node_status.clone(),
                    node_result.clone(),
                    *updated_at,
                ));
            }
        }

        // If no executions found, return static node definitions
        if rows.is_empty() {
            for (
                node_id,
                node_type,
                query,
                result_name,
                left_node,
                right_node,
                node_status,
                node_result,
                updated_at,
            ) in node_defs
            {
                rows.push((
                    0i64,
                    node_id,
                    node_type,
                    query,
                    result_name,
                    left_node,
                    right_node,
                    node_status,
                    node_result,
                    updated_at,
                ));
            }
        }

        rows
    });

    TableIterator::new(results)
}
