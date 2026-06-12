// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! ExecuteFunctionGraph orchestration - the main durable function executor
//!
//! ⚠️ DETERMINISTIC CODE ONLY in this file!
//! - No I/O except through activities
//! - No random numbers, current time, or other non-deterministic sources
//! - Same input must always produce the same scheduling decisions

use std::collections::HashMap;
use std::time::Duration;

use duroxide::OrchestrationContext;

use crate::activities;
use crate::types::{
    evaluate_condition, substitute_all, substitute_all_raw, FunctionGraph, FunctionInput,
    FunctionNode, SystemVars,
};

/// Orchestration name for ExecuteFunctionGraph
pub const NAME: &str = "pg_durable::orchestration::execute-function-graph";

/// Orchestration name for ExecuteSubtree (used for parallel JOIN/RACE)
pub const SUBTREE_NAME: &str = "pg_durable::orchestration::execute-subtree";

/// Execution context containing vars and metadata
#[derive(Clone)]
struct ExecutionContext {
    vars: HashMap<String, String>,
    label: Option<String>,
}

/// Control-flow-aware error type returned by every node handler.
///
/// `Break` is **not** a failure: it unwinds through compound nodes (THEN, IF, JOIN,
/// RACE, and the subtree boundary) via the `?` operator until the nearest enclosing
/// `execute_loop_node` catches it. `Failure` is a genuine error that propagates to the
/// orchestration result. Encoding break this way means forgetting to propagate it is a
/// compile error rather than a silently-ignored value (see issue #148 / #132).
#[derive(Debug)]
enum NodeError {
    /// A `df.break()` signal carrying its (already-stringified) value, caught by the loop.
    Break(String),
    /// A real failure; propagates to the orchestration's `Err` result.
    Failure(String),
}

/// All helper functions (`substitute_all`, `evaluate_condition`) and activity scheduling
/// return `Result<_, String>`. This conversion lets `?` turn those `String` errors into
/// `NodeError::Failure` automatically, so only genuine control flow needs explicit handling.
impl From<String> for NodeError {
    fn from(e: String) -> Self {
        NodeError::Failure(e)
    }
}

/// Mirrors `From<String>` for the many `.ok_or("literal")?` sites that yield `&str` errors,
/// preserving the ergonomics those calls had when handlers returned `Result<_, String>`.
impl From<&str> for NodeError {
    fn from(e: &str) -> Self {
        NodeError::Failure(e.to_string())
    }
}

/// Result type for node handlers: `Ok` value string, or a typed control-flow/failure error.
type NodeResult = Result<String, NodeError>;

/// Distinguishes a normal subtree result from one that unwound via `df.break()`.
/// `#[serde(default)]` on the envelope's field keeps envelopes recorded by an older binary
/// (which had no control field) deserializable as `Normal` across an in-flight upgrade.
#[derive(Default, serde::Serialize, serde::Deserialize)]
enum SubtreeControl {
    #[default]
    Normal,
    Break,
}

/// Envelope returned by `execute_subtree` containing the SQL result and the updated
/// named-results map so the parent orchestration can merge any new entries after join/race.
/// `control` carries a `df.break()` signal back across the sub-orchestration boundary so the
/// parent can re-raise it as `NodeError::Break` rather than smuggling a sentinel in `result`.
#[derive(serde::Serialize, serde::Deserialize)]
struct SubtreeEnvelope {
    #[serde(default)]
    control: SubtreeControl,
    result: String,
    results: HashMap<String, String>,
}

/// Execute a complete function graph — the entry point for a durable function.
///
/// # Control flow
/// Internally every node handler returns `NodeResult`, where `NodeError::Break` is
/// **intentional control flow** (a `df.break()` signal), not a failure. Break unwinds
/// through compound nodes via `?` and is caught by the nearest enclosing
/// `execute_loop_node`; only `NodeError::Failure` represents a genuine error. This
/// boundary collapses the typed result back to `Result<String, String>`: a `Break`
/// that reaches here was used outside `df.loop()`, so it is surfaced as a clear failure
/// rather than completing with a control-flow value. Callers should treat the returned
/// `Err` strictly as a failure and must not add retry/recovery logic for break.
pub async fn execute(ctx: OrchestrationContext, input_json: String) -> Result<String, String> {
    let input: FunctionInput = serde_json::from_str(&input_json)
        .map_err(|e| format!("Invalid orchestration input: {e}"))?;

    let label_info = input
        .label
        .as_ref()
        .map(|l| format!(" ({l})"))
        .unwrap_or_default();
    ctx.trace_info(format!(
        "Starting ExecuteFunctionGraph for instance: {}{}",
        input.instance_id, label_info
    ));

    if !input.vars.is_empty() {
        // Sort keys for deterministic logging
        let mut keys: Vec<_> = input.vars.keys().collect();
        keys.sort();
        ctx.trace_info(format!("Workflow vars: {keys:?}"));
    }

    let graph_json = match ctx
        .schedule_activity(
            activities::load_function_graph::NAME,
            input.instance_id.clone(),
        )
        .await
    {
        Ok(json) => json,
        Err(e) => {
            // load_function_graph failed (e.g., superuser blocked).
            // Mark the instance as failed before propagating.
            let status_input = serde_json::json!({
                "instance_id": input.instance_id,
                "status": "failed"
            });
            let _ = ctx
                .schedule_activity(
                    activities::update_instance_status::NAME,
                    status_input.to_string(),
                )
                .await;
            return Err(e);
        }
    };

    let graph: FunctionGraph = serde_json::from_str(&graph_json)
        .map_err(|e| format!("Failed to parse function graph: {e}"))?;

    ctx.trace_info(format!(
        "Executing function with {} nodes, root: {}",
        graph.nodes.len(),
        graph.root_node_id
    ));

    // Mark the instance as running now that we have loaded the graph and are
    // about to execute.  This call is idempotent: on continue_as_new the
    // instance is already 'running', so re-issuing the update is harmless.
    let running_input = serde_json::json!({
        "instance_id": input.instance_id,
        "status": "running"
    });
    let _ = ctx
        .schedule_activity(
            activities::update_instance_status::NAME,
            running_input.to_string(),
        )
        .await;

    let mut results: HashMap<String, String> = HashMap::new();

    // Create execution context with vars
    let exec_ctx = ExecutionContext {
        vars: input.vars.clone(),
        label: input.label.clone(),
    };

    let function_outcome =
        execute_function_node_with_vars(&ctx, &graph, &graph.root_node_id, &mut results, &exec_ctx)
            .await;

    // Normalize the typed node result into the orchestration's String boundary. A `Break`
    // that reaches this point was never caught by a loop, i.e. `df.break()` was used outside
    // of `df.loop()` — surface it as a clear, actionable failure rather than completing with a
    // control-flow value as the function's result.
    let function_result: Result<String, String> = match function_outcome {
        Ok(result) => Ok(result),
        Err(NodeError::Failure(err)) => Err(err),
        Err(NodeError::Break(_)) => Err(
            "df.break() was called outside of a loop. df.break() may only be used inside df.loop()."
                .to_string(),
        ),
    };

    match &function_result {
        Ok(result) => {
            ctx.trace_info(format!("Function completed with result: {result}"));
            let status_input = serde_json::json!({
                "instance_id": input.instance_id,
                "status": "completed"
            });
            let _ = ctx
                .schedule_activity(
                    activities::update_instance_status::NAME,
                    status_input.to_string(),
                )
                .await;
        }
        Err(err) => {
            ctx.trace_info(format!("Function failed with error: {err}"));
            let status_input = serde_json::json!({
                "instance_id": input.instance_id,
                "status": "failed"
            });
            let _ = ctx
                .schedule_activity(
                    activities::update_instance_status::NAME,
                    status_input.to_string(),
                )
                .await;
        }
    }

    function_result
}

/// Execute a subtree of a function graph (used for parallel JOIN/RACE)
pub async fn execute_subtree(
    ctx: OrchestrationContext,
    input_json: String,
) -> Result<String, String> {
    let input: serde_json::Value = serde_json::from_str(&input_json)
        .map_err(|e| format!("Failed to parse ExecuteSubtree input: {e}"))?;

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
        .map_err(|e| format!("Failed to parse graph in ExecuteSubtree: {e}"))?;
    let mut results: HashMap<String, String> = serde_json::from_str(results_json)
        .map_err(|e| format!("Failed to parse results in ExecuteSubtree: {e}"))?;

    let vars: HashMap<String, String> = if let Some(vars_json) = input["vars"].as_str() {
        serde_json::from_str(vars_json)
            .map_err(|e| format!("Failed to parse vars in ExecuteSubtree: {e}"))?
    } else {
        HashMap::new()
    };
    let label: Option<String> = input["label"].as_str().map(|s| s.to_string());

    ctx.trace_info(format!("ExecuteSubtree: executing node {node_id}"));

    let exec_ctx = ExecutionContext { vars, label };

    // Build the envelope carrying the result, the updated named-results map, and a typed
    // control signal. A `Break` inside the subtree is re-encoded as `control: Break` (not a
    // sentinel smuggled inside `result`) so the parent can re-raise it as `NodeError::Break`.
    // A genuine `Failure` propagates as `Err` across the sub-orchestration boundary.
    let envelope =
        match execute_function_node_with_vars(&ctx, &graph, node_id, &mut results, &exec_ctx).await
        {
            Ok(result) => {
                ctx.trace_info(format!("ExecuteSubtree: node {node_id} completed"));
                SubtreeEnvelope {
                    control: SubtreeControl::Normal,
                    result,
                    results,
                }
            }
            Err(NodeError::Break(value)) => {
                ctx.trace_info(format!(
                    "ExecuteSubtree: node {node_id} broke (propagating)"
                ));
                SubtreeEnvelope {
                    control: SubtreeControl::Break,
                    result: value,
                    results,
                }
            }
            Err(NodeError::Failure(e)) => return Err(e),
        };

    serde_json::to_string(&envelope)
        .map_err(|e| format!("Failed to serialize subtree envelope: {e}"))
}

/// Recursively execute function nodes with vars support
async fn execute_function_node_with_vars(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    let node = graph
        .nodes
        .get(node_id)
        .ok_or_else(|| format!("Node not found: {node_id}"))?;

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
        .schedule_activity(
            activities::update_node_status::NAME,
            running_input.to_string(),
        )
        .await;

    let execute_result = execute_node_inner(ctx, graph, node_id, node, results, exec_ctx).await;

    // Update node with final status and result. A `Break` is control flow rather than a
    // failure: record the node as completed (carrying the break value) so observability is
    // unchanged from when break travelled as a normal `Ok` sentinel. Only `Failure` marks
    // the node failed.
    match &execute_result {
        Ok(result) => {
            let completed_input = serde_json::json!({
                "node_id": node_id,
                "status": "completed",
                "result": result
            });
            let _ = ctx
                .schedule_activity(
                    activities::update_node_status::NAME,
                    completed_input.to_string(),
                )
                .await;
        }
        Err(NodeError::Break(value)) => {
            let completed_input = serde_json::json!({
                "node_id": node_id,
                "status": "completed",
                "result": value
            });
            let _ = ctx
                .schedule_activity(
                    activities::update_node_status::NAME,
                    completed_input.to_string(),
                )
                .await;
        }
        Err(NodeError::Failure(err)) => {
            let failed_input = serde_json::json!({
                "node_id": node_id,
                "status": "failed",
                "result": err
            });
            let _ = ctx
                .schedule_activity(
                    activities::update_node_status::NAME,
                    failed_input.to_string(),
                )
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
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    // Build system vars
    let sys_vars = SystemVars {
        instance_id: graph.instance_id.clone(),
        label: exec_ctx.label.clone(),
    };

    match node.node_type.to_lowercase().as_str() {
        "sql" => execute_sql_node(ctx, node, node_id, results, exec_ctx, &sys_vars).await,
        "then" => execute_then_node(ctx, graph, node, node_id, results, exec_ctx).await,
        "sleep" => execute_sleep_node(ctx, node, node_id).await,
        "wait_schedule" => execute_wait_schedule_node(ctx, node, node_id).await,
        "loop" => execute_loop_node(ctx, graph, node, node_id, results, exec_ctx).await,
        "if" => execute_if_node(ctx, graph, node, node_id, results, exec_ctx).await,
        "join" => execute_join_node(ctx, graph, node, node_id, results, exec_ctx).await,
        "race" => execute_race_node(ctx, graph, node, node_id, results, exec_ctx).await,
        "http" => execute_http_node(ctx, node, node_id, results, exec_ctx, &sys_vars).await,
        "signal" => execute_signal_node(ctx, node, node_id, results).await,
        "break" => execute_break_node(ctx, node, node_id).await,
        other => Err(NodeError::Failure(format!("Unknown node type: {other}"))),
    }
}

// ============================================================================
// Node Type Handlers
// ============================================================================

async fn execute_sql_node(
    ctx: &OrchestrationContext,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
    sys_vars: &SystemVars,
) -> NodeResult {
    let query = node
        .query
        .as_ref()
        .ok_or_else(|| format!("SQL node {node_id} has no query"))?;

    let final_query = substitute_all(query, results, &exec_ctx.vars, sys_vars)?;
    ctx.trace_info(format!("Executing SQL: {final_query}"));

    let input = serde_json::json!({
        "query": final_query,
        "submitted_by": node.submitted_by,
        "database": node.database,
    });

    let result = ctx
        .schedule_activity(activities::execute_sql::NAME, input.to_string())
        .await?;

    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing result as ${name}"));
        results.insert(name.clone(), result.clone());
    }

    Ok(result)
}

fn store_named_result(
    ctx: &OrchestrationContext,
    node: &FunctionNode,
    result: &str,
    results: &mut HashMap<String, String>,
    node_label: &str,
) {
    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing {node_label} result as ${name}"));
        results.insert(name.clone(), result.to_string());
    }
}

async fn execute_then_node(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    let left_id = node
        .left_node
        .as_ref()
        .ok_or_else(|| format!("THEN node {node_id} has no left_node"))?;
    let right_id = node
        .right_node
        .as_ref()
        .ok_or_else(|| format!("THEN node {node_id} has no right_node"))?;

    // A `df.break()` anywhere in the left branch propagates automatically via `?` to the
    // enclosing loop, skipping the right branch — no explicit sentinel check needed.
    Box::pin(execute_function_node_with_vars(
        ctx, graph, left_id, results, exec_ctx,
    ))
    .await?;

    let right_result = Box::pin(execute_function_node_with_vars(
        ctx, graph, right_id, results, exec_ctx,
    ))
    .await?;

    store_named_result(ctx, node, &right_result, results, "THEN");

    Ok(right_result)
}

async fn execute_sleep_node(
    ctx: &OrchestrationContext,
    node: &FunctionNode,
    node_id: &str,
) -> NodeResult {
    let seconds_str = node
        .query
        .as_ref()
        .ok_or_else(|| format!("SLEEP node {node_id} has no duration"))?;

    let seconds: u64 = seconds_str
        .parse()
        .map_err(|_| format!("Invalid sleep duration: {seconds_str}"))?;

    ctx.trace_info(format!("Sleeping for {seconds} seconds"));
    ctx.schedule_timer(Duration::from_secs(seconds)).await;

    Ok(format!(r#"{{"slept": true, "seconds": {seconds}}}"#))
}

async fn execute_wait_schedule_node(
    ctx: &OrchestrationContext,
    node: &FunctionNode,
    node_id: &str,
) -> NodeResult {
    let config_str = node
        .query
        .as_ref()
        .ok_or_else(|| format!("WAIT_SCHEDULE node {node_id} has no config"))?;

    // Parse pre-computed config from DSL time
    let config: serde_json::Value = serde_json::from_str(config_str)
        .map_err(|e| format!("Invalid WAIT_SCHEDULE config: {e}"))?;

    let wait_seconds = config["wait_seconds"]
        .as_u64()
        .ok_or_else(|| "WAIT_SCHEDULE missing wait_seconds".to_string())?;

    let cron_expr = config["cron_expr"].as_str().unwrap_or("?");

    ctx.trace_info(format!(
        "Waiting {wait_seconds} seconds until schedule: {cron_expr}"
    ));
    ctx.schedule_timer(Duration::from_secs(wait_seconds)).await;

    Ok(r#"{"scheduled": true}"#.to_string())
}

/// Minimum wall-clock duration that every loop iteration must take before
/// `continue_as_new` is called.  If the body (plus any while-condition
/// evaluation) completes faster than this, a compensating timer makes up the
/// deficit so an empty-bodied loop can't busy-spin via continue_as_new.
const LOOP_MIN_ITER_DURATION: Duration = Duration::from_secs(1);

async fn execute_loop_node(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    let body_id = node
        .left_node
        .as_ref()
        .ok_or_else(|| format!("LOOP node {node_id} has no body"))?;

    // Capture the iteration start time so we can rate-limit `continue_as_new`
    // below.  `utc_now()` is duroxide's deterministic clock (recorded in
    // history and replayed verbatim), so this remains replay-safe.
    let iter_started = ctx.utc_now().await.ok();

    ctx.trace_info("Executing loop iteration");

    // The loop is the only place that catches `NodeError::Break`: a break unwinds through
    // every compound node in the body via `?` and is converted here into a normal loop exit.
    // A `Failure` still propagates out of the loop unchanged.
    let body_result = match Box::pin(execute_function_node_with_vars(
        ctx, graph, body_id, results, exec_ctx,
    ))
    .await
    {
        Ok(v) => v,
        Err(NodeError::Break(break_value)) => {
            ctx.trace_info(format!(
                "Loop terminated by break with value: {break_value}"
            ));
            store_named_result(ctx, node, &break_value, results, "LOOP");
            return Ok(break_value);
        }
        Err(e @ NodeError::Failure(_)) => return Err(e),
    };

    // Check while-condition if present
    if let Some(ref config_str) = node.query {
        if let Ok(config) = serde_json::from_str::<serde_json::Value>(config_str) {
            if let Some(condition_node_id) = config["condition_node"].as_str() {
                ctx.trace_info("Evaluating loop condition");
                let condition_result = Box::pin(execute_function_node_with_vars(
                    ctx,
                    graph,
                    condition_node_id,
                    results,
                    exec_ctx,
                ))
                .await?;

                // Parse condition result to check truthiness (uses evaluate_condition to extract boolean from SQL result)
                let should_continue = evaluate_condition(&condition_result).unwrap_or(false);
                ctx.trace_info(format!(
                    "Loop condition evaluated to: {condition_result} (continue={should_continue})"
                ));

                if !should_continue {
                    ctx.trace_info("Loop condition false, exiting loop");
                    store_named_result(ctx, node, &body_result, results, "LOOP");
                    return Ok(body_result);
                }
            }
        }
    }

    ctx.trace_info("Continuing as new for next loop iteration");

    // Enforce a minimum per-iteration wall-clock duration to prevent
    // busy-looping (e.g. `df.loop(df.sleep(0))`).  Compute the elapsed time
    // from the deterministic clock; if the iteration finished faster than
    // LOOP_MIN_ITER_DURATION, schedule a timer for the deficit so the next
    // continue_as_new is gated by at least that much real-clock time.
    if let Some(started) = iter_started {
        if let Ok(now) = ctx.utc_now().await {
            let elapsed = now.duration_since(started).unwrap_or(Duration::ZERO);
            if elapsed < LOOP_MIN_ITER_DURATION {
                let deficit = LOOP_MIN_ITER_DURATION - elapsed;
                ctx.trace_info(format!(
                    "Loop iteration took {elapsed:?} (< {LOOP_MIN_ITER_DURATION:?}); \
                     adding {deficit:?} rate-limit delay"
                ));
                ctx.schedule_timer(deficit).await;
            }
        }
    }

    // Preserve vars in continue_as_new input
    let new_input = FunctionInput {
        instance_id: graph.instance_id.clone(),
        label: exec_ctx.label.clone(),
        vars: exec_ctx.vars.clone(),
    };

    // duroxide 0.1.1: continue_as_new returns an awaitable future - return it directly
    return ctx
        .continue_as_new(serde_json::to_string(&new_input).unwrap_or(graph.instance_id.clone()))
        .await
        .map(|_| body_result)
        .map_err(|e| NodeError::Failure(format!("continue_as_new failed: {e:?}")));
}

async fn execute_break_node(
    ctx: &OrchestrationContext,
    node: &FunctionNode,
    node_id: &str,
) -> NodeResult {
    let break_value = node
        .query
        .as_ref()
        .and_then(|config_str| serde_json::from_str::<serde_json::Value>(config_str).ok())
        .and_then(|config| config.get("break_value").cloned())
        .and_then(|v| {
            if v.is_null() {
                None
            } else {
                v.as_str().map(|s| s.to_string())
            }
        });

    ctx.trace_info(format!(
        "BREAK node {node_id} executed with value: {break_value:?}"
    ));

    // Encode the break value as the stringified JSON the loop will surface as its result:
    // a value that parses as JSON is preserved as-is (e.g. `{"status":"done"}`), a bare
    // string round-trips as a quoted JSON string, and an absent value becomes `null`.
    // The signal travels as a typed `NodeError::Break`, so `?` unwinds it to the loop.
    let value = match break_value {
        Some(v) => serde_json::from_str::<serde_json::Value>(&v)
            .unwrap_or(serde_json::Value::String(v))
            .to_string(),
        None => "null".to_string(),
    };

    Err(NodeError::Break(value))
}

async fn execute_if_node(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    let config_str = node
        .query
        .as_ref()
        .ok_or_else(|| format!("IF node {node_id} has no config"))?;
    let config: serde_json::Value =
        serde_json::from_str(config_str).map_err(|e| format!("Invalid IF config: {e}"))?;

    let then_id = node
        .left_node
        .as_ref()
        .ok_or_else(|| format!("IF node {node_id} has no then branch"))?;
    let else_id = node
        .right_node
        .as_ref()
        .ok_or_else(|| format!("IF node {node_id} has no else branch"))?;

    let is_true =
        if config.get("condition_type").and_then(|ct| ct.as_str()) == Some("result_has_rows") {
            // df.if_rows: check row_count from in-memory results — no activity needed
            let result_name = config["result_name"]
                .as_str()
                .ok_or_else(|| "df.if_rows: missing result_name".to_string())?;
            let result_json = results
                .get(result_name)
                .ok_or_else(|| format!("df.if_rows: result '{result_name}' not found"))?;
            let parsed: serde_json::Value = serde_json::from_str(result_json)
                .map_err(|e| format!("df.if_rows: invalid result JSON: {e}"))?;
            let row_count = parsed
                .get("row_count")
                .and_then(|rc| rc.as_u64())
                .ok_or_else(|| {
                    format!(
                    "df.if_rows: result '{result_name}' is not a SQL result (missing row_count)"
                )
                })?;
            ctx.trace_info(format!("if_rows '{result_name}': {row_count} rows"));
            row_count > 0
        } else {
            // df.if: execute condition node as SQL
            let condition_node_id = config["condition_node"]
                .as_str()
                .ok_or_else(|| "IF node missing condition_node".to_string())?;

            ctx.trace_info("Evaluating IF condition");
            let condition_result = Box::pin(execute_function_node_with_vars(
                ctx,
                graph,
                condition_node_id,
                results,
                exec_ctx,
            ))
            .await?;

            evaluate_condition(&condition_result)?
        };

    ctx.trace_info(format!("Condition evaluated to: {is_true}"));

    if is_true {
        let result = Box::pin(execute_function_node_with_vars(
            ctx, graph, then_id, results, exec_ctx,
        ))
        .await?;
        store_named_result(ctx, node, &result, results, "IF");
        Ok(result)
    } else {
        let result = Box::pin(execute_function_node_with_vars(
            ctx, graph, else_id, results, exec_ctx,
        ))
        .await?;
        store_named_result(ctx, node, &result, results, "IF");
        Ok(result)
    }
}

/// Sentinel key used by pre-#148 binaries (<= v0.2.2) to encode a `df.break()` *inside* the
/// subtree envelope's `result` string, as `{"__break__": true, "value": ...}`. This binary no
/// longer writes it (break now travels as the typed `control` field), but it is still read on
/// the in-flight upgrade path: see `parse_subtree_envelope`.
const LEGACY_BREAK_SENTINEL: &str = "__break__";

/// Decode a pre-#148 break sentinel for in-flight upgrade compatibility.
///
/// Returns `Some(value)` if `raw` is a legacy `{"__break__": true, "value": ...}` object,
/// where `value` is the break value stringified exactly as the old `extract_break_value`
/// produced it (the JSON value's `to_string()`, or `"null"` when absent). Returns `None` for
/// any normal result. New breaks never reach this path because they carry `control = Break`.
fn parse_legacy_break_sentinel(raw: &str) -> Option<String> {
    let value = serde_json::from_str::<serde_json::Value>(raw).ok()?;
    if value.get(LEGACY_BREAK_SENTINEL).and_then(|b| b.as_bool()) != Some(true) {
        return None;
    }
    Some(
        value
            .get("value")
            .cloned()
            .map(|v| v.to_string())
            .unwrap_or_else(|| "null".to_string()),
    )
}

/// Parse the JSON envelope returned by `execute_subtree`, extract the SQL result string,
/// and merge the branch's named results into `parent_results`. A branch that broke out via
/// `df.break()` carries `control = Break`, which is re-raised here as `NodeError::Break` so
/// the enclosing loop catches it.
fn parse_subtree_envelope(
    raw: &str,
    context: &str,
    parent_results: &mut HashMap<String, String>,
) -> NodeResult {
    let envelope: SubtreeEnvelope =
        serde_json::from_str(raw).map_err(|e| format!("{context} envelope parse error: {e}"))?;
    parent_results.extend(envelope.results);
    match envelope.control {
        SubtreeControl::Break => Err(NodeError::Break(envelope.result)),
        // `Normal` also covers envelopes recorded by a pre-#148 binary (<= v0.2.2), which had
        // no `control` field (so it defaults to `Normal`) and instead smuggled a break as a
        // `{"__break__": true, ...}` sentinel inside `result`. Re-raise such a legacy sentinel
        // as a typed `Break` so a JOIN/RACE-in-loop break still unwinds correctly when an
        // orchestration started under the old binary resumes under this one, instead of being
        // silently swallowed and treated as a normal branch result.
        SubtreeControl::Normal => match parse_legacy_break_sentinel(&envelope.result) {
            Some(value) => Err(NodeError::Break(value)),
            None => Ok(envelope.result),
        },
    }
}

async fn execute_join_node(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    let left_id = node
        .left_node
        .as_ref()
        .ok_or_else(|| format!("JOIN node {node_id} has no left branch"))?;
    let right_id = node
        .right_node
        .as_ref()
        .ok_or_else(|| format!("JOIN node {node_id} has no right branch"))?;

    ctx.trace_info("Executing JOIN branches in parallel");

    let graph_json =
        serde_json::to_string(&graph).map_err(|e| format!("Failed to serialize graph: {e}"))?;
    let results_json =
        serde_json::to_string(&results).map_err(|e| format!("Failed to serialize results: {e}"))?;
    let vars_json = serde_json::to_string(&exec_ctx.vars)
        .map_err(|e| format!("Failed to serialize vars: {e}"))?;

    let left_input = serde_json::json!({
        "graph": graph_json,
        "node_id": left_id,
        "results": results_json,
        "vars": vars_json,
        "label": exec_ctx.label
    })
    .to_string();

    let right_input = serde_json::json!({
        "graph": graph_json,
        "node_id": right_id,
        "results": results_json,
        "vars": vars_json,
        "label": exec_ctx.label
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
                            "results": results_json,
                            "vars": vars_json,
                            "label": exec_ctx.label
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
        let fut = ctx.schedule_sub_orchestration(SUBTREE_NAME, input);
        durable_futures.push(fut);
    }

    // Use ctx.join() - Duroxide's proper join method for parallel execution
    let results_vec = ctx.join(durable_futures).await;

    // Process results - join now returns Vec<Result<String, String>> directly.
    // Each Ok value is a JSON envelope {"result": "...", "results": {...}} produced by
    // execute_subtree; unwrap it and merge the branch's named results into the parent map.
    let mut join_results: Vec<serde_json::Value> = Vec::new();
    for (i, result) in results_vec.into_iter().enumerate() {
        match result {
            Ok(r) => {
                let context = format!("JOIN branch {}", i + 1);
                // A break in any branch surfaces as `NodeError::Break` from
                // `parse_subtree_envelope` and unwinds via `?` to the enclosing loop.
                let branch_result = parse_subtree_envelope(&r, &context, results)?;
                let parsed = serde_json::from_str::<serde_json::Value>(&branch_result)
                    .map_err(|e| format!("JOIN branch {} result parse error: {}", i + 1, e))?;
                join_results.push(parsed);
            }
            Err(e) => {
                return Err(NodeError::Failure(format!(
                    "JOIN branch {} failed: {}",
                    i + 1,
                    e
                )));
            }
        }
    }

    ctx.trace_info(format!(
        "JOIN completed with {} results",
        join_results.len()
    ));

    let result = serde_json::to_string(&join_results).unwrap_or_else(|_| "[]".to_string());

    // Store result if named
    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing JOIN result as ${name}"));
        results.insert(name.clone(), result.clone());
    }

    Ok(result)
}

async fn execute_race_node(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    let left_id = node
        .left_node
        .as_ref()
        .ok_or_else(|| format!("RACE node {node_id} has no left branch"))?;
    let right_id = node
        .right_node
        .as_ref()
        .ok_or_else(|| format!("RACE node {node_id} has no right branch"))?;

    ctx.trace_info("Executing RACE branches in parallel (first wins)");

    let graph_json =
        serde_json::to_string(&graph).map_err(|e| format!("Failed to serialize graph: {e}"))?;
    let results_json =
        serde_json::to_string(&results).map_err(|e| format!("Failed to serialize results: {e}"))?;
    let vars_json = serde_json::to_string(&exec_ctx.vars)
        .map_err(|e| format!("Failed to serialize vars: {e}"))?;

    let left_input = serde_json::json!({
        "graph": graph_json,
        "node_id": left_id,
        "results": results_json,
        "vars": vars_json,
        "label": exec_ctx.label
    })
    .to_string();

    let right_input = serde_json::json!({
        "graph": graph_json,
        "node_id": right_id,
        "results": results_json,
        "vars": vars_json,
        "label": exec_ctx.label
    })
    .to_string();

    // Schedule sub-orchestrations
    let left_fut = ctx.schedule_sub_orchestration(SUBTREE_NAME, left_input);
    let right_fut = ctx.schedule_sub_orchestration(SUBTREE_NAME, right_input);

    // Use ctx.select2() - first to complete wins
    // select2 now returns Either2<Left, Right> instead of (winner_idx, DurableOutput)
    let raw = match ctx.select2(left_fut, right_fut).await {
        duroxide::Either2::First(Ok(r)) => {
            ctx.trace_info("RACE completed - left branch won");
            Ok(r)
        }
        duroxide::Either2::First(Err(e)) => Err(format!("RACE left branch failed: {e}")),
        duroxide::Either2::Second(Ok(r)) => {
            ctx.trace_info("RACE completed - right branch won");
            Ok(r)
        }
        duroxide::Either2::Second(Err(e)) => Err(format!("RACE right branch failed: {e}")),
    }?;

    // Parse the subtree output envelope produced by execute_subtree and merge any named
    // results from the winning branch into the parent results map. If the winning branch
    // broke out via `df.break()`, `parse_subtree_envelope` returns `NodeError::Break`, which
    // unwinds via `?` to the enclosing loop.
    let result = parse_subtree_envelope(&raw, "RACE branch", results)?;

    // Store result if named
    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing RACE result as ${name}"));
        results.insert(name.clone(), result.clone());
    }

    Ok(result)
}

async fn execute_http_node(
    ctx: &OrchestrationContext,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
    sys_vars: &SystemVars,
) -> NodeResult {
    let config_str = node
        .query
        .as_ref()
        .ok_or_else(|| format!("HTTP node {node_id} has no config"))?;

    // Parse config to substitute variables in body and URL
    let mut config: serde_json::Value =
        serde_json::from_str(config_str).map_err(|e| format!("Invalid HTTP config: {e}"))?;

    // Substitute variables in body if present
    if let Some(body) = config.get("body").and_then(|b| b.as_str()) {
        let substituted_body = substitute_all_raw(body, results, &exec_ctx.vars, sys_vars)?;
        config["body"] = serde_json::Value::String(substituted_body);
    }

    // Substitute variables in URL if present
    if let Some(url) = config.get("url").and_then(|u| u.as_str()) {
        let substituted_url = substitute_all_raw(url, results, &exec_ctx.vars, sys_vars)?;
        config["url"] = serde_json::Value::String(substituted_url);
    }

    // Substitute variables in headers if present
    // Sort keys for deterministic iteration order
    if let Some(headers) = config.get("headers").and_then(|h| h.as_object()) {
        let mut new_headers = serde_json::Map::new();
        let mut sorted_keys: Vec<_> = headers.keys().collect();
        sorted_keys.sort();
        for key in sorted_keys {
            if let Some(value) = headers.get(key) {
                if let Some(v) = value.as_str() {
                    let substituted = substitute_all_raw(v, results, &exec_ctx.vars, sys_vars)?;
                    new_headers.insert(key.clone(), serde_json::Value::String(substituted));
                } else {
                    new_headers.insert(key.clone(), value.clone());
                }
            }
        }
        config["headers"] = serde_json::Value::Object(new_headers);
    }

    // Inject audit context from the function node
    config["submitted_by"] = serde_json::Value::String(node.submitted_by.clone());

    let final_config = config.to_string();
    let url = config["url"].as_str().unwrap_or("?");
    let method = config["method"].as_str().unwrap_or("POST");
    ctx.trace_info(format!("Executing HTTP {method} {url}"));

    let result = ctx
        .schedule_activity(activities::execute_http::NAME, final_config)
        .await?;

    // Store result if named
    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing HTTP result as ${name}"));
        results.insert(name.clone(), result.clone());
    }

    Ok(result)
}

async fn execute_signal_node(
    ctx: &OrchestrationContext,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
) -> NodeResult {
    let parse_signal_data = |data_str: &str| {
        serde_json::from_str::<serde_json::Value>(data_str)
            .unwrap_or_else(|_| serde_json::Value::String(data_str.to_string()))
    };

    let config_str = node
        .query
        .as_ref()
        .ok_or_else(|| format!("SIGNAL node {node_id} has no config"))?;

    let config: serde_json::Value =
        serde_json::from_str(config_str).map_err(|e| format!("Invalid SIGNAL config: {e}"))?;

    let signal_name = config["signal_name"]
        .as_str()
        .ok_or("Missing signal_name in SIGNAL config")?;
    let timeout_seconds = config["timeout_seconds"].as_i64();

    ctx.trace_info(format!(
        "Waiting for signal: {}{}",
        signal_name,
        timeout_seconds
            .map(|t| format!(" (timeout: {t}s)"))
            .unwrap_or_default()
    ));

    let result = if let Some(timeout_secs) = timeout_seconds {
        // Race between signal and timeout using select2
        let signal_fut = ctx.schedule_wait(signal_name);
        let timeout_fut = ctx.schedule_timer(Duration::from_secs(timeout_secs as u64));

        // select2 now returns Either2<String, ()> instead of (winner_idx, DurableOutput)
        match ctx.select2(signal_fut, timeout_fut).await {
            duroxide::Either2::First(data_str) => {
                // Signal received - data_str is String directly
                let data = parse_signal_data(&data_str);
                serde_json::json!({
                    "signal_name": signal_name,
                    "timed_out": false,
                    "data": data
                })
            }
            duroxide::Either2::Second(()) => {
                // Timeout
                serde_json::json!({
                    "signal_name": signal_name,
                    "timed_out": true,
                    "data": null
                })
            }
        }
    } else {
        // Wait forever - schedule_wait returns String directly now
        let data_str = ctx.schedule_wait(signal_name).await;
        let data = parse_signal_data(&data_str);
        serde_json::json!({
            "signal_name": signal_name,
            "timed_out": false,
            "data": data
        })
    };

    let result_str = result.to_string();

    // Store result if named
    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing signal result as ${name}"));
        results.insert(name.clone(), result_str.clone());
    }

    Ok(result_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build an envelope JSON string the way `execute_subtree` serializes a `SubtreeEnvelope`.
    /// When `control` is `None` the field is omitted entirely, reproducing an envelope recorded
    /// by a pre-#148 binary (<= v0.2.2) that had no `control` field.
    fn envelope_json(control: Option<&str>, result: &str, results: serde_json::Value) -> String {
        let mut obj = serde_json::Map::new();
        if let Some(c) = control {
            obj.insert(
                "control".to_string(),
                serde_json::Value::String(c.to_string()),
            );
        }
        obj.insert(
            "result".to_string(),
            serde_json::Value::String(result.to_string()),
        );
        obj.insert("results".to_string(), results);
        serde_json::Value::Object(obj).to_string()
    }

    /// Reproduce the exact break sentinel string a pre-#148 binary stored inside the envelope's
    /// `result` field for a `df.break(value)`.
    fn legacy_sentinel(value: serde_json::Value) -> String {
        serde_json::json!({ "__break__": true, "value": value }).to_string()
    }

    fn expect_break(result: NodeResult) -> String {
        match result {
            Err(NodeError::Break(v)) => v,
            other => panic!("expected NodeError::Break, got {other:?}"),
        }
    }

    fn expect_ok(result: NodeResult) -> String {
        match result {
            Ok(v) => v,
            other => panic!("expected Ok, got {other:?}"),
        }
    }

    #[test]
    fn parse_legacy_break_sentinel_decodes_string_value() {
        // A JSON string value round-trips as the quoted JSON string, matching the old
        // `extract_break_value` (which called `Value::to_string()` on the `value`).
        assert_eq!(
            parse_legacy_break_sentinel(&legacy_sentinel(serde_json::json!("hello"))),
            Some("\"hello\"".to_string())
        );
    }

    #[test]
    fn parse_legacy_break_sentinel_decodes_object_value() {
        assert_eq!(
            parse_legacy_break_sentinel(&legacy_sentinel(serde_json::json!({"status": "done"}))),
            Some("{\"status\":\"done\"}".to_string())
        );
    }

    #[test]
    fn parse_legacy_break_sentinel_decodes_null_value() {
        assert_eq!(
            parse_legacy_break_sentinel(&legacy_sentinel(serde_json::Value::Null)),
            Some("null".to_string())
        );
    }

    #[test]
    fn parse_legacy_break_sentinel_ignores_non_break_json() {
        assert_eq!(parse_legacy_break_sentinel(r#"{"status":"done"}"#), None);
        assert_eq!(parse_legacy_break_sentinel(r#"{"__break__":false}"#), None);
        assert_eq!(parse_legacy_break_sentinel(r#""just a string""#), None);
        assert_eq!(parse_legacy_break_sentinel("not json at all"), None);
    }

    #[test]
    fn envelope_new_format_break_is_reraised() {
        let raw = envelope_json(Some("Break"), "\"done\"", serde_json::json!({}));
        let mut parent = HashMap::new();
        assert_eq!(
            expect_break(parse_subtree_envelope(&raw, "JOIN", &mut parent)),
            "\"done\""
        );
    }

    #[test]
    fn envelope_new_format_normal_passes_through() {
        let raw = envelope_json(Some("Normal"), "42", serde_json::json!({}));
        let mut parent = HashMap::new();
        assert_eq!(
            expect_ok(parse_subtree_envelope(&raw, "JOIN", &mut parent)),
            "42"
        );
    }

    // --- In-flight upgrade path (pre-#148 envelopes, no `control` field) ---

    #[test]
    fn legacy_envelope_break_is_reraised_not_swallowed() {
        // Regression guard for the v0.2.2 -> 0.2.3 upgrade: an envelope recorded by the old
        // binary smuggled the break as a sentinel in `result` and had no `control` field. The
        // new binary must re-raise it as a typed Break instead of returning it as a normal
        // result (which would silently swallow the break and let the loop keep iterating).
        let raw = envelope_json(
            None,
            &legacy_sentinel(serde_json::json!("v")),
            serde_json::json!({}),
        );
        let mut parent = HashMap::new();
        assert_eq!(
            expect_break(parse_subtree_envelope(&raw, "JOIN", &mut parent)),
            "\"v\""
        );
    }

    #[test]
    fn legacy_envelope_null_break_is_reraised() {
        let raw = envelope_json(
            None,
            &legacy_sentinel(serde_json::Value::Null),
            serde_json::json!({}),
        );
        let mut parent = HashMap::new();
        assert_eq!(
            expect_break(parse_subtree_envelope(&raw, "RACE branch", &mut parent)),
            "null"
        );
    }

    #[test]
    fn legacy_envelope_normal_result_passes_through() {
        // An old envelope whose result is a real value (not a sentinel) is unaffected.
        let raw = envelope_json(None, r#"{"rows":1}"#, serde_json::json!({}));
        let mut parent = HashMap::new();
        assert_eq!(
            expect_ok(parse_subtree_envelope(&raw, "JOIN", &mut parent)),
            r#"{"rows":1}"#
        );
    }

    #[test]
    fn envelope_merges_named_results_even_on_break() {
        // Named results produced inside the branch must still be merged into the parent map
        // before the break unwinds, on both the new and legacy paths.
        let raw = envelope_json(
            Some("Break"),
            "\"x\"",
            serde_json::json!({"branch_result": "stored"}),
        );
        let mut parent = HashMap::new();
        let _ = parse_subtree_envelope(&raw, "JOIN", &mut parent);
        assert_eq!(
            parent.get("branch_result").map(String::as_str),
            Some("stored")
        );
    }
}
