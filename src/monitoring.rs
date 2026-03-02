//! Monitoring functions for pg_durable — SPI-based
//!
//! All monitoring queries run synchronously via SPI against the duroxide
//! stored procedures and pg_durable's own tables. No async runtime, no TCP
//! connections, no connection pools.

#![allow(clippy::type_complexity)] // Required for pgrx TableIterator return types

use pgrx::prelude::*;

use crate::types::DUROXIDE_SCHEMA;

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
    let results = Spi::connect(|client| {
        // 1. Get instance IDs from duroxide (filtered or all)
        let list_sql = if let Some(status) = status_filter {
            format!(
                "SELECT instance_id FROM {DUROXIDE_SCHEMA}.list_instances_by_status('{}') LIMIT {}",
                status.replace('\'', "''"),
                limit_count
            )
        } else {
            format!(
                "SELECT instance_id FROM {DUROXIDE_SCHEMA}.list_instances() LIMIT {limit_count}"
            )
        };

        let instance_ids: Vec<String> = match client.select(&list_sql, None, &[]) {
            Ok(table) => table
                .filter_map(|row| row.get::<String>(1).ok().flatten())
                .collect(),
            Err(_) => return vec![],
        };

        // 2. For each instance, get info from duroxide + label from df.instances
        let mut rows = Vec::new();
        for id in instance_ids {
            let info_sql = format!(
                "SELECT instance_id, orchestration_name, status, current_execution_id, output \
                 FROM {DUROXIDE_SCHEMA}.get_instance_info('{}')",
                id.replace('\'', "''")
            );
            if let Ok(table) = client.select(&info_sql, None, &[]) {
                for row in table {
                    let inst_id: String = match row.get(1).ok().flatten() {
                        Some(v) => v,
                        None => continue,
                    };
                    let function_name: String =
                        row.get::<String>(2).ok().flatten().unwrap_or_default();
                    let status: String = row.get::<String>(3).ok().flatten().unwrap_or_default();
                    let exec_id: i64 = row.get::<i64>(4).ok().flatten().unwrap_or(0);
                    let output: Option<String> = row.get(5).ok().flatten();

                    // Get label from df.instances
                    let label_sql = format!(
                        "SELECT label FROM df.instances WHERE id = '{}'",
                        inst_id.replace('\'', "''")
                    );
                    let label: Option<String> = client
                        .select(&label_sql, None, &[])
                        .ok()
                        .and_then(|t| t.into_iter().next())
                        .and_then(|r| r.get(1).ok().flatten());

                    rows.push((inst_id, label, function_name, status, exec_id, output));
                }
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
    let safe_id = instance_id.replace('\'', "''");

    let results = Spi::connect(|client| {
        // Get label from df.instances
        let label: Option<String> = client
            .select(
                &format!("SELECT label FROM df.instances WHERE id = '{safe_id}'"),
                None,
                &[],
            )
            .ok()
            .and_then(|t| t.into_iter().next())
            .and_then(|r| r.get(1).ok().flatten());

        // Get instance info from duroxide stored procedure
        let info_sql = format!(
            "SELECT instance_id, orchestration_name, orchestration_version, \
             current_execution_id, status, output \
             FROM {DUROXIDE_SCHEMA}.get_instance_info('{safe_id}')"
        );

        match client.select(&info_sql, None, &[]) {
            Ok(table) => {
                let mut rows = Vec::new();
                for row in table {
                    let inst_id: String = match row.get(1).ok().flatten() {
                        Some(v) => v,
                        None => continue,
                    };
                    let function_name: String =
                        row.get::<String>(2).ok().flatten().unwrap_or_default();
                    let function_version: String =
                        row.get::<String>(3).ok().flatten().unwrap_or_default();
                    let exec_id: i64 = row.get::<i64>(4).ok().flatten().unwrap_or(0);
                    let status: String = row.get::<String>(5).ok().flatten().unwrap_or_default();
                    let output: Option<String> = row.get(6).ok().flatten();

                    rows.push((
                        inst_id,
                        label.clone(),
                        function_name,
                        function_version,
                        exec_id,
                        status,
                        output,
                    ));
                }
                rows
            }
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
    let safe_id = instance_id.replace('\'', "''");

    let results = Spi::connect(|client| {
        // Get execution IDs (sorted descending, limited)
        let list_sql = format!(
            "SELECT execution_id FROM {DUROXIDE_SCHEMA}.list_executions('{safe_id}') \
             ORDER BY execution_id DESC LIMIT {limit_count}"
        );

        let exec_ids: Vec<i64> = match client.select(&list_sql, None, &[]) {
            Ok(table) => table
                .filter_map(|row| row.get::<i64>(1).ok().flatten())
                .collect(),
            Err(_) => return vec![],
        };

        let mut rows = Vec::new();
        for exec_id in exec_ids {
            let info_sql = format!(
                "SELECT execution_id, status, event_count, \
                 EXTRACT(EPOCH FROM (completed_at - started_at))::BIGINT * 1000 AS duration_ms, \
                 output \
                 FROM {DUROXIDE_SCHEMA}.get_execution_info('{safe_id}', {exec_id})"
            );

            if let Ok(table) = client.select(&info_sql, None, &[]) {
                for row in table {
                    let eid: i64 = row.get::<i64>(1).ok().flatten().unwrap_or(0);
                    let status: String = row.get::<String>(2).ok().flatten().unwrap_or_default();
                    let event_count: i64 = row.get::<i64>(3).ok().flatten().unwrap_or(0);
                    let duration_ms: i64 = row.get::<i64>(4).ok().flatten().unwrap_or(0);
                    let output: Option<String> = row.get(5).ok().flatten();

                    rows.push((eid, status, event_count, duration_ms, output));
                }
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
    let results = Spi::connect(|client| {
        let sql = format!(
            "SELECT total_instances, running_instances, completed_instances, \
             failed_instances, total_executions, total_events \
             FROM {DUROXIDE_SCHEMA}.get_system_metrics()"
        );

        match client.select(&sql, None, &[]) {
            Ok(table) => {
                let mut rows = Vec::new();
                for row in table {
                    let total_instances: i64 = row.get::<i64>(1).ok().flatten().unwrap_or(0);
                    let running: i64 = row.get::<i64>(2).ok().flatten().unwrap_or(0);
                    let completed: i64 = row.get::<i64>(3).ok().flatten().unwrap_or(0);
                    let failed: i64 = row.get::<i64>(4).ok().flatten().unwrap_or(0);
                    let total_executions: i64 = row.get::<i64>(5).ok().flatten().unwrap_or(0);
                    let total_events: i64 = row.get::<i64>(6).ok().flatten().unwrap_or(0);

                    rows.push((
                        total_instances,
                        running,
                        completed,
                        failed,
                        total_executions,
                        total_events,
                    ));
                }
                rows
            }
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

    let safe_id = instance_id_param.replace('\'', "''");

    let results = Spi::connect(|client| {
        // Get node definitions from df.nodes (including status, result and updated_at)
        let node_sql = format!(
            r#"SELECT id, node_type, query, result_name, left_node, right_node,
                      status, result::text, updated_at
               FROM df.nodes WHERE instance_id = '{safe_id}'"#
        );

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
        )> = match client.select(&node_sql, None, &[]) {
            Ok(table) => {
                let mut nodes = Vec::new();
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
                nodes
            }
            Err(_) => vec![],
        };

        // Get execution IDs from duroxide (sorted descending, limited)
        let exec_sql = format!(
            "SELECT execution_id FROM {DUROXIDE_SCHEMA}.list_executions('{safe_id}') \
             ORDER BY execution_id DESC LIMIT {last_n_executions}"
        );

        let exec_ids: Vec<i64> = client
            .select(&exec_sql, None, &[])
            .ok()
            .map(|t| {
                t.filter_map(|row| row.get::<i64>(1).ok().flatten())
                    .collect()
            })
            .unwrap_or_default();

        let mut rows = Vec::new();

        if exec_ids.is_empty() {
            // No executions found — return static node definitions
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
        } else {
            for exec_id in exec_ids {
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
                        exec_id,
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
        }

        rows
    });

    TableIterator::new(results)
}
