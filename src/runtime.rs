//! Duroxide runtime and background worker for pg_durable

use pgrx::bgworkers::*;
use pgrx::prelude::*;
use std::sync::Arc;
use std::time::Duration;

use duroxide::{
    runtime::{self, registry::ActivityRegistry},
    ActivityContext, Client, OrchestrationContext, OrchestrationRegistry,
};
use sqlx::postgres::PgPoolOptions;
use sqlx::{Column, Row};

use crate::types::{
    calculate_cron_wait, evaluate_condition, postgres_connection_string, substitute_variables,
    FunctionGraph, FunctionInput, FunctionNode, DUROXIDE_SCHEMA,
};
use duroxide_pg::PostgresProvider;

// ============================================================================
// Background Worker Setup
// ============================================================================

/// Initialize the background worker
pub fn register_background_worker() {
    BackgroundWorkerBuilder::new("pg_durable_worker")
        .set_function("duroxide_worker_main")
        .set_library("pg_durable")
        .set_argument(0i32.into_datum())
        .enable_spi_access()
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .set_restart_time(Some(Duration::from_secs(5)))
        .load();
}

/// Check if PostgreSQL has requested shutdown
fn is_shutdown_requested() -> bool {
    unsafe { pgrx::pg_sys::ShutdownRequestPending != 0 }
}

/// Main duroxide background worker
#[pg_guard]
#[no_mangle]
pub extern "C-unwind" fn duroxide_worker_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    log!("pg_durable: duroxide background worker starting...");

    let rt = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            log!("pg_durable: failed to create tokio runtime: {}", e);
            return;
        }
    };

    rt.block_on(async {
        run_duroxide_runtime_with_shutdown().await;
    });

    rt.shutdown_timeout(Duration::from_secs(5));
    log!("pg_durable: duroxide background worker terminated cleanly");
}

// ============================================================================
// Duroxide Runtime
// ============================================================================

/// Run the duroxide runtime with proper shutdown handling
async fn run_duroxide_runtime_with_shutdown() {
    log!("pg_durable: initializing duroxide runtime with PostgreSQL store...");

    let pg_conn_str = postgres_connection_string();
    log!(
        "pg_durable: connecting to PostgreSQL at {} (schema: {})",
        pg_conn_str,
        DUROXIDE_SCHEMA
    );

    let store = match PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA)).await {
        Ok(s) => Arc::new(s),
        Err(e) => {
            log!("pg_durable: failed to create PostgreSQL store: {}", e);
            return;
        }
    };

    log!(
        "pg_durable: PostgreSQL store created in schema '{}'",
        DUROXIDE_SCHEMA
    );

    let pg_pool = match PgPoolOptions::new()
        .max_connections(5)
        .connect(&pg_conn_str)
        .await
    {
        Ok(pool) => {
            log!("pg_durable: PostgreSQL connection pool created");
            Arc::new(pool)
        }
        Err(e) => {
            log!("pg_durable: failed to create PostgreSQL pool: {}", e);
            Arc::new(PgPoolOptions::new().connect_lazy(&pg_conn_str).unwrap())
        }
    };

    let sql_pool = pg_pool.clone();
    let graph_pool = pg_pool.clone();
    let status_pool = pg_pool.clone();
    let node_status_pool = pg_pool.clone();

    // Register activities
    let activities = ActivityRegistry::builder()
        .register("ExecuteSQL", move |ctx: ActivityContext, query: String| {
            let pool = sql_pool.clone();
            async move {
                ctx.trace_info(format!("Executing SQL: {}", query));

                match sqlx::query(&query).fetch_all(pool.as_ref()).await {
                    Ok(rows) => {
                        let mut result_rows: Vec<serde_json::Value> = Vec::new();
                        for row in rows {
                            let columns = row.columns();
                            let mut row_obj = serde_json::Map::new();

                            for col in columns {
                                let col_name = col.name();
                                if let Ok(val) = row.try_get::<String, _>(col_name) {
                                    row_obj.insert(col_name.to_string(), serde_json::Value::String(val));
                                } else if let Ok(val) = row.try_get::<i64, _>(col_name) {
                                    row_obj.insert(col_name.to_string(), serde_json::Value::Number(val.into()));
                                } else if let Ok(val) = row.try_get::<i32, _>(col_name) {
                                    row_obj.insert(col_name.to_string(), serde_json::Value::Number(val.into()));
                                } else if let Ok(val) = row.try_get::<bool, _>(col_name) {
                                    row_obj.insert(col_name.to_string(), serde_json::Value::Bool(val));
                                } else if let Ok(val) = row.try_get::<f64, _>(col_name) {
                                    if let Some(n) = serde_json::Number::from_f64(val) {
                                        row_obj.insert(col_name.to_string(), serde_json::Value::Number(n));
                                    }
                                } else {
                                    row_obj.insert(col_name.to_string(), serde_json::Value::Null);
                                }
                            }
                            result_rows.push(serde_json::Value::Object(row_obj));
                        }

                        let result = serde_json::json!({
                            "rows": result_rows,
                            "row_count": result_rows.len()
                        });

                        ctx.trace_info(format!("SQL returned {} rows", result_rows.len()));
                        Ok(result.to_string())
                    }
                    Err(e) => {
                        let err_msg = format!("SQL execution failed: {}", e);
                        ctx.trace_info(&err_msg);
                        Err(err_msg)
                    }
                }
            }
        })
        .register("LoadFunctionGraph", move |ctx: ActivityContext, instance_id: String| {
            let pool = graph_pool.clone();
            async move {
                ctx.trace_info(format!("Loading function graph for instance: {}", instance_id));

                let instance_query = format!(
                    "SELECT root_node FROM df.instances WHERE id = '{}'",
                    instance_id
                );

                let root_node_id: String = match sqlx::query_scalar(&instance_query)
                    .fetch_one(pool.as_ref())
                    .await
                {
                    Ok(id) => id,
                    Err(e) => return Err(format!("Failed to load instance: {}", e)),
                };

                let nodes_query = format!(
                    r#"SELECT id, node_type, query, result_name,
                       left_node, right_node
                    FROM df.nodes WHERE instance_id = '{}'"#,
                    instance_id
                );

                let rows = match sqlx::query(&nodes_query)
                    .fetch_all(pool.as_ref())
                    .await
                {
                    Ok(rows) => rows,
                    Err(e) => return Err(format!("Failed to load function nodes: {}", e)),
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
                    };
                    nodes.insert(id, node);
                }

                let graph = FunctionGraph {
                    instance_id,
                    root_node_id,
                    nodes,
                };

                ctx.trace_info(format!("Loaded function graph with {} nodes", graph.nodes.len()));

                serde_json::to_string(&graph)
                    .map_err(|e| format!("Failed to serialize graph: {}", e))
            }
        })
        .register("UpdateInstanceStatus", move |ctx: ActivityContext, input_json: String| {
            let pool = status_pool.clone();
            async move {
                let input: serde_json::Value = serde_json::from_str(&input_json)
                    .map_err(|e| format!("Failed to parse status update input: {}", e))?;

                let instance_id = input["instance_id"].as_str().ok_or("Missing instance_id")?;
                let status = input["status"].as_str().ok_or("Missing status")?;

                ctx.trace_info(format!("Updating instance {} status to {}", instance_id, status));

                let update_query = if status == "completed" {
                    format!(
                        "UPDATE df.instances SET status = 'completed', completed_at = now(), updated_at = now() WHERE id = '{}'",
                        instance_id
                    )
                } else {
                    format!(
                        "UPDATE df.instances SET status = '{}', updated_at = now() WHERE id = '{}'",
                        status, instance_id
                    )
                };

                match sqlx::query(&update_query).execute(pool.as_ref()).await {
                    Ok(_) => {
                        ctx.trace_info(format!("Instance {} status updated to {}", instance_id, status));
                        Ok(format!("Status updated to {}", status))
                    }
                    Err(e) => {
                        let err_msg = format!("Failed to update instance status: {}", e);
                        ctx.trace_info(&err_msg);
                        Err(err_msg)
                    }
                }
            }
        })
        .register("UpdateNodeStatus", move |ctx: ActivityContext, input_json: String| {
            let pool = node_status_pool.clone();
            async move {
                let input: serde_json::Value = serde_json::from_str(&input_json)
                    .map_err(|e| format!("Failed to parse node status input: {}", e))?;

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
                        "UPDATE df.nodes SET status = '{}', result = $json${}$json$::jsonb, updated_at = now() WHERE id = '{}'",
                        status, json_result, node_id
                    )
                } else {
                    format!(
                        "UPDATE df.nodes SET status = '{}', updated_at = now() WHERE id = '{}'",
                        status, node_id
                    )
                };

                match sqlx::query(&update_query).execute(pool.as_ref()).await {
                    Ok(_) => Ok("Node status updated".to_string()),
                    Err(e) => {
                        let err_msg = format!("Failed to update node status: {}", e);
                        ctx.trace_info(&err_msg);
                        Err(err_msg)
                    }
                }
            }
        })
        .register("ExecuteHTTP", move |ctx: ActivityContext, config_json: String| {
            use crate::types::HttpConfig;

            async move {
                let config: HttpConfig = serde_json::from_str(&config_json)
                    .map_err(|e| format!("Invalid HTTP config: {}", e))?;

                let start = std::time::Instant::now();
                ctx.trace_info(format!("HTTP {} {}", config.method, config.url));

                // Build client with timeout
                let client = reqwest::Client::builder()
                    .timeout(Duration::from_secs(config.timeout_seconds))
                    .build()
                    .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

                // Build request based on method
                let mut request = match config.method.as_str() {
                    "GET" => client.get(&config.url),
                    "POST" => client.post(&config.url),
                    "PUT" => client.put(&config.url),
                    "DELETE" => client.delete(&config.url),
                    "PATCH" => client.patch(&config.url),
                    _ => return Err(format!("Unsupported HTTP method: {}", config.method)),
                };

                // Add headers
                if let Some(headers) = &config.headers {
                    if let Some(obj) = headers.as_object() {
                        for (key, value) in obj {
                            if let Some(v) = value.as_str() {
                                request = request.header(key, v);
                            }
                        }
                    }
                }

                // Add body (for POST/PUT/PATCH)
                if let Some(body) = &config.body {
                    request = request.body(body.clone());
                }

                // Execute request
                let response = request.send().await.map_err(|e| {
                    if e.is_timeout() {
                        format!("HTTP timeout after {}s: {}", config.timeout_seconds, config.url)
                    } else if e.is_connect() {
                        format!("HTTP connection failed to {}: {}", config.url, e)
                    } else {
                        format!("HTTP request failed: {}", e)
                    }
                })?;

                let status = response.status();
                let status_code = status.as_u16();

                // Collect response headers
                let response_headers: serde_json::Map<String, serde_json::Value> = response
                    .headers()
                    .iter()
                    .filter_map(|(k, v)| {
                        v.to_str()
                            .ok()
                            .map(|s| (k.to_string(), serde_json::Value::String(s.to_string())))
                    })
                    .collect();

                let response_body = response
                    .text()
                    .await
                    .map_err(|e| format!("Failed to read response body: {}", e))?;

                let duration_ms = start.elapsed().as_millis() as u64;
                let is_ok = status.is_success();

                // Build response object
                let result = serde_json::json!({
                    "status": status_code,
                    "body": response_body,
                    "headers": response_headers,
                    "ok": is_ok,
                    "duration_ms": duration_ms
                });

                ctx.trace_info(format!(
                    "HTTP {} completed: status={}, ok={}, duration={}ms",
                    config.method, status_code, is_ok, duration_ms
                ));

                // Fail on 5xx server errors (transient, should retry)
                if status.is_server_error() {
                    return Err(format!(
                        "HTTP {} {} returned {}: {}",
                        config.method, config.url, status_code, response_body
                    ));
                }

                // Return response for all other cases (including 4xx)
                // 4xx are client errors - user should handle in workflow logic
                Ok(result.to_string())
            }
        })
        .build();

    // Register durable functions
    let functions = OrchestrationRegistry::builder()
        .register(
            "ExecuteWorkflow",
            |ctx: OrchestrationContext, input_json: String| async move {
                let (instance_id, label) = if input_json.starts_with('{') {
                    match serde_json::from_str::<FunctionInput>(&input_json) {
                        Ok(input) => (input.instance_id, input.label),
                        Err(_) => (input_json.clone(), None),
                    }
                } else {
                    (input_json.clone(), None)
                };

                let label_info = label
                    .as_ref()
                    .map(|l| format!(" ({})", l))
                    .unwrap_or_default();
                ctx.trace_info(format!(
                    "Starting ExecuteWorkflow for instance: {}{}",
                    instance_id, label_info
                ));

                let graph_json = ctx
                    .schedule_activity("LoadFunctionGraph", instance_id.clone())
                    .into_activity()
                    .await?;

                let graph: FunctionGraph = serde_json::from_str(&graph_json)
                    .map_err(|e| format!("Failed to parse function graph: {}", e))?;

                ctx.trace_info(format!(
                    "Executing function with {} nodes, root: {}",
                    graph.nodes.len(),
                    graph.root_node_id
                ));

                let mut results: std::collections::HashMap<String, String> =
                    std::collections::HashMap::new();

                let function_result =
                    execute_function_node(&ctx, &graph, &graph.root_node_id, &mut results).await;

                match &function_result {
                    Ok(result) => {
                        ctx.trace_info(format!("Function completed with result: {}", result));
                        let status_input = serde_json::json!({
                            "instance_id": instance_id,
                            "status": "completed"
                        });
                        let _ = ctx
                            .schedule_activity("UpdateInstanceStatus", status_input.to_string())
                            .into_activity()
                            .await;
                    }
                    Err(err) => {
                        ctx.trace_info(format!("Function failed with error: {}", err));
                        let status_input = serde_json::json!({
                            "instance_id": instance_id,
                            "status": "failed"
                        });
                        let _ = ctx
                            .schedule_activity("UpdateInstanceStatus", status_input.to_string())
                            .into_activity()
                            .await;
                    }
                }

                function_result
            },
        )
        .register(
            "ExecuteSubtree",
            |ctx: OrchestrationContext, input_json: String| async move {
                let input: serde_json::Value = serde_json::from_str(&input_json)
                    .map_err(|e| format!("Failed to parse ExecuteSubtree input: {}", e))?;

                let graph_json = input["graph"]
                    .as_str()
                    .ok_or("Missing graph in ExecuteSubtree input")?;
                let node_id = input["node_id"]
                    .as_str()
                    .ok_or("Missing node_id in ExecuteSubtree input")?;
                let results_json = input["results"]
                    .as_str()
                    .ok_or("Missing results in ExecuteSubtree input")?;

                let graph: FunctionGraph = serde_json::from_str(graph_json)
                    .map_err(|e| format!("Failed to parse graph in ExecuteSubtree: {}", e))?;
                let mut results: std::collections::HashMap<String, String> =
                    serde_json::from_str(results_json)
                        .map_err(|e| format!("Failed to parse results in ExecuteSubtree: {}", e))?;

                ctx.trace_info(format!("ExecuteSubtree: executing node {}", node_id));

                let result = execute_function_node(&ctx, &graph, node_id, &mut results).await?;

                ctx.trace_info(format!("ExecuteSubtree: node {} completed", node_id));
                Ok(result)
            },
        )
        .build();

    let duroxide_runtime =
        runtime::Runtime::start_with_store(store.clone(), Arc::new(activities), functions).await;

    log!("pg_durable: duroxide runtime started, processing durable functions...");

    // Create a client for starting orchestrations
    // Keep runtime alive until shutdown signal
    loop {
        tokio::time::sleep(Duration::from_millis(100)).await;

        let should_shutdown = tokio::task::spawn_blocking(is_shutdown_requested)
            .await
            .unwrap_or(false);

        if should_shutdown {
            log!("pg_durable: shutdown signal received, stopping duroxide runtime...");
            break;
        }
    }

    log!("pg_durable: initiating duroxide runtime shutdown...");
    duroxide_runtime.shutdown(Some(10_000)).await;
    log!("pg_durable: duroxide runtime shutdown complete");
}

// ============================================================================
// Node Execution
// ============================================================================

/// Recursively execute function nodes
async fn execute_function_node(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node_id: &str,
    results: &mut std::collections::HashMap<String, String>,
) -> Result<String, String> {
    let node = graph
        .nodes
        .get(node_id)
        .ok_or_else(|| format!("Node not found: {}", node_id))?;

    ctx.trace_info(format!(
        "Executing node {} (type: {})",
        node_id, node.node_type
    ));

    // Mark node as running
    let running_input = serde_json::json!({
        "node_id": node_id,
        "status": "running"
    });
    let _ = ctx
        .schedule_activity("UpdateNodeStatus", running_input.to_string())
        .into_activity()
        .await;

    let execute_result = execute_node_inner(ctx, graph, node_id, node, results).await;

    // Update node with final status and result
    match &execute_result {
        Ok(result) => {
            let completed_input = serde_json::json!({
                "node_id": node_id,
                "status": "completed",
                "result": result
            });
            let _ = ctx
                .schedule_activity("UpdateNodeStatus", completed_input.to_string())
                .into_activity()
                .await;
        }
        Err(err) => {
            let failed_input = serde_json::json!({
                "node_id": node_id,
                "status": "failed",
                "result": err
            });
            let _ = ctx
                .schedule_activity("UpdateNodeStatus", failed_input.to_string())
                .into_activity()
                .await;
        }
    }

    execute_result
}

/// Inner function that actually executes the node logic
async fn execute_node_inner(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node_id: &str,
    node: &FunctionNode,
    results: &mut std::collections::HashMap<String, String>,
) -> Result<String, String> {
    match node.node_type.to_lowercase().as_str() {
        "sql" => {
            let query = node
                .query
                .as_ref()
                .ok_or_else(|| format!("SQL node {} has no query", node_id))?;

            let final_query = substitute_variables(query, results);
            ctx.trace_info(format!("Executing SQL: {}", final_query));

            let result = ctx
                .schedule_activity("ExecuteSQL", final_query)
                .into_activity()
                .await?;

            if let Some(name) = &node.result_name {
                ctx.trace_info(format!("Storing result as ${}", name));
                results.insert(name.clone(), result.clone());
            }

            Ok(result)
        }
        "then" => {
            let left_id = node
                .left_node
                .as_ref()
                .ok_or_else(|| format!("THEN node {} has no left_node", node_id))?;
            let right_id = node
                .right_node
                .as_ref()
                .ok_or_else(|| format!("THEN node {} has no right_node", node_id))?;

            let _left_result =
                Box::pin(execute_function_node(ctx, graph, left_id, results)).await?;
            let right_result =
                Box::pin(execute_function_node(ctx, graph, right_id, results)).await?;

            Ok(right_result)
        }
        "sleep" => {
            let seconds_str = node
                .query
                .as_ref()
                .ok_or_else(|| format!("SLEEP node {} has no duration", node_id))?;

            let seconds: u64 = seconds_str
                .parse()
                .map_err(|_| format!("Invalid sleep duration: {}", seconds_str))?;

            ctx.trace_info(format!("Sleeping for {} seconds", seconds));
            ctx.schedule_timer(Duration::from_secs(seconds))
                .into_timer()
                .await;

            Ok(format!(r#"{{"slept": true, "seconds": {}}}"#, seconds))
        }
        "wait_schedule" => {
            let cron_expr = node
                .query
                .as_ref()
                .ok_or_else(|| format!("WAIT_SCHEDULE node {} has no cron expression", node_id))?;

            let duration = calculate_cron_wait(cron_expr)?;

            ctx.trace_info(format!(
                "Waiting {} seconds until schedule: {}",
                duration.as_secs(),
                cron_expr
            ));
            ctx.schedule_timer(duration).into_timer().await;

            Ok(r#"{"scheduled": true}"#.to_string())
        }
        "loop" => {
            let body_id = node
                .left_node
                .as_ref()
                .ok_or_else(|| format!("LOOP node {} has no body", node_id))?;

            ctx.trace_info("Executing loop iteration");
            let body_result = Box::pin(execute_function_node(ctx, graph, body_id, results)).await?;

            ctx.trace_info("Continuing as new for next loop iteration");
            ctx.continue_as_new(graph.instance_id.clone());

            Ok(body_result)
        }
        "if" => {
            let config_str = node
                .query
                .as_ref()
                .ok_or_else(|| format!("IF node {} has no config", node_id))?;
            let config: serde_json::Value = serde_json::from_str(config_str)
                .map_err(|e| format!("Invalid IF config: {}", e))?;

            let condition_node_id = config["condition_node"]
                .as_str()
                .ok_or_else(|| "IF node missing condition_node".to_string())?;

            let then_id = node
                .left_node
                .as_ref()
                .ok_or_else(|| format!("IF node {} has no then branch", node_id))?;
            let else_id = node
                .right_node
                .as_ref()
                .ok_or_else(|| format!("IF node {} has no else branch", node_id))?;

            ctx.trace_info("Evaluating IF condition");
            let condition_result = Box::pin(execute_function_node(
                ctx,
                graph,
                condition_node_id,
                results,
            ))
            .await?;

            let is_true = evaluate_condition(&condition_result)?;
            ctx.trace_info(format!("Condition evaluated to: {}", is_true));

            if is_true {
                Box::pin(execute_function_node(ctx, graph, then_id, results)).await
            } else {
                Box::pin(execute_function_node(ctx, graph, else_id, results)).await
            }
        }
        "join" => {
            let left_id = node
                .left_node
                .as_ref()
                .ok_or_else(|| format!("JOIN node {} has no left branch", node_id))?;
            let right_id = node
                .right_node
                .as_ref()
                .ok_or_else(|| format!("JOIN node {} has no right branch", node_id))?;

            ctx.trace_info("Executing JOIN branches in parallel");

            let graph_json = serde_json::to_string(&graph)
                .map_err(|e| format!("Failed to serialize graph: {}", e))?;
            let results_json = serde_json::to_string(&results)
                .map_err(|e| format!("Failed to serialize results: {}", e))?;

            let left_input = serde_json::json!({
                "graph": graph_json,
                "node_id": left_id,
                "results": results_json
            })
            .to_string();

            let right_input = serde_json::json!({
                "graph": graph_json,
                "node_id": right_id,
                "results": results_json
            })
            .to_string();

            // Build list of branch inputs
            let mut branch_inputs = vec![left_input, right_input];

            // Check for extra nodes (join3)
            if let Some(config_str) = &node.query {
                if let Ok(config) = serde_json::from_str::<serde_json::Value>(config_str) {
                    if let Some(extra_nodes) = config["extra_nodes"].as_array() {
                        for extra_node_val in extra_nodes {
                            if let Some(extra_id) = extra_node_val.as_str() {
                                let extra_input = serde_json::json!({
                                    "graph": graph_json,
                                    "node_id": extra_id,
                                    "results": results_json
                                })
                                .to_string();
                                branch_inputs.push(extra_input);
                            }
                        }
                    }
                }
            }

            // Schedule sub-orchestrations and collect DurableFutures
            let mut durable_futures = Vec::new();
            for input in branch_inputs {
                let fut = ctx.schedule_sub_orchestration("ExecuteSubtree", input);
                durable_futures.push(fut);
            }

            // Use ctx.join() - Duroxide's proper join method for parallel execution
            let results_vec = ctx.join(durable_futures).await;

            // Process results - DurableOutput is an enum wrapping the result
            let mut join_results = Vec::new();
            for (i, result) in results_vec.into_iter().enumerate() {
                match result {
                    duroxide::DurableOutput::SubOrchestration(Ok(r)) => join_results.push(r),
                    duroxide::DurableOutput::SubOrchestration(Err(e)) => {
                        return Err(format!("JOIN branch {} failed: {}", i + 1, e));
                    }
                    duroxide::DurableOutput::Activity(Ok(r)) => join_results.push(r),
                    duroxide::DurableOutput::Activity(Err(e)) => {
                        return Err(format!("JOIN branch {} failed: {}", i + 1, e));
                    }
                    _ => return Err(format!("JOIN branch {} returned unexpected type", i + 1)),
                }
            }

            ctx.trace_info(format!(
                "JOIN completed with {} results",
                join_results.len()
            ));

            let result = serde_json::to_string(&join_results).unwrap_or_else(|_| "[]".to_string());

            // Store result if named
            if let Some(name) = &node.result_name {
                ctx.trace_info(format!("Storing JOIN result as ${}", name));
                results.insert(name.clone(), result.clone());
            }

            Ok(result)
        }
        "race" => {
            let left_id = node
                .left_node
                .as_ref()
                .ok_or_else(|| format!("RACE node {} has no left branch", node_id))?;
            let right_id = node
                .right_node
                .as_ref()
                .ok_or_else(|| format!("RACE node {} has no right branch", node_id))?;

            ctx.trace_info("Executing RACE branches in parallel (first wins)");

            let graph_json = serde_json::to_string(&graph)
                .map_err(|e| format!("Failed to serialize graph: {}", e))?;
            let results_json = serde_json::to_string(&results)
                .map_err(|e| format!("Failed to serialize results: {}", e))?;

            let left_input = serde_json::json!({
                "graph": graph_json,
                "node_id": left_id,
                "results": results_json
            })
            .to_string();

            let right_input = serde_json::json!({
                "graph": graph_json,
                "node_id": right_id,
                "results": results_json
            })
            .to_string();

            // Schedule sub-orchestrations
            let left_fut = ctx.schedule_sub_orchestration("ExecuteSubtree", left_input);
            let right_fut = ctx.schedule_sub_orchestration("ExecuteSubtree", right_input);

            // Use ctx.select2() - first to complete wins
            // select2 returns (usize, DurableOutput) where usize is the winning branch index
            let (_winner_idx, output) = ctx.select2(left_fut, right_fut).await;

            let result = match output {
                duroxide::DurableOutput::SubOrchestration(Ok(r)) => {
                    ctx.trace_info("RACE completed - first result received");
                    Ok(r)
                }
                duroxide::DurableOutput::SubOrchestration(Err(e)) => {
                    Err(format!("RACE failed: {}", e))
                }
                duroxide::DurableOutput::Activity(Ok(r)) => {
                    ctx.trace_info("RACE completed - first result received");
                    Ok(r)
                }
                duroxide::DurableOutput::Activity(Err(e)) => Err(format!("RACE failed: {}", e)),
                _ => Err("RACE returned unexpected type".to_string()),
            }?;

            // Store result if named
            if let Some(name) = &node.result_name {
                ctx.trace_info(format!("Storing RACE result as ${}", name));
                results.insert(name.clone(), result.clone());
            }

            Ok(result)
        }
        "http" => {
            let config_str = node
                .query
                .as_ref()
                .ok_or_else(|| format!("HTTP node {} has no config", node_id))?;

            // Parse config to substitute variables in body and URL
            let mut config: serde_json::Value = serde_json::from_str(config_str)
                .map_err(|e| format!("Invalid HTTP config: {}", e))?;

            // Substitute variables in body if present
            if let Some(body) = config.get("body").and_then(|b| b.as_str()) {
                let substituted_body = substitute_variables(body, results);
                config["body"] = serde_json::Value::String(substituted_body);
            }

            // Substitute variables in URL if present (for dynamic endpoints)
            if let Some(url) = config.get("url").and_then(|u| u.as_str()) {
                let substituted_url = substitute_variables(url, results);
                config["url"] = serde_json::Value::String(substituted_url);
            }

            let final_config = config.to_string();
            let url = config["url"].as_str().unwrap_or("?");
            let method = config["method"].as_str().unwrap_or("POST");
            ctx.trace_info(format!("Executing HTTP {} {}", method, url));

            let result = ctx
                .schedule_activity("ExecuteHTTP", final_config)
                .into_activity()
                .await?;

            // Store result if named
            if let Some(name) = &node.result_name {
                ctx.trace_info(format!("Storing HTTP result as ${}", name));
                results.insert(name.clone(), result.clone());
            }

            Ok(result)
        }
        other => Err(format!("Unknown node type: {}", other)),
    }
}

// ============================================================================
// Client Functions
// ============================================================================

/// Start a durable function via the shared PostgreSQL store.
pub fn start_durable_function(
    function_name: &str,
    instance_id: &str,
    input: &str,
) -> Result<(), String> {
    let pg_conn_str = postgres_connection_string();
    log!("pg_durable: start_durable_function - connecting to PostgreSQL");

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("Failed to create tokio runtime: {}", e))?;

    rt.block_on(async {
        let store = Arc::new(
            PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA))
                .await
                .map_err(|e| format!("Failed to connect to duroxide store: {}", e))?,
        );

        let client = Client::new(store);
        client
            .start_orchestration(instance_id, function_name, input)
            .await
            .map_err(|e| format!("Failed to start durable function: {:?}", e))?;

        Ok(())
    })
}

/// Cancel a durable function.
pub fn cancel_durable_function(instance_id: &str, reason: &str) -> Result<(), String> {
    let pg_conn_str = postgres_connection_string();

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("Failed to create tokio runtime: {}", e))?;

    rt.block_on(async {
        let store = Arc::new(
            PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA))
                .await
                .map_err(|e| format!("Failed to connect to duroxide store: {}", e))?,
        );

        let client = Client::new(store);
        client
            .cancel_instance(instance_id, reason)
            .await
            .map_err(|e| format!("Failed to cancel durable function: {:?}", e))?;

        Ok(())
    })
}
