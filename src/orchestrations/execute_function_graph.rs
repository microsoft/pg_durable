// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! ExecuteFunctionGraph orchestration - the main durable function executor
//!
//! ⚠️ DETERMINISTIC CODE ONLY in this file!
//! - No I/O except through activities
//! - No random numbers, current time, or other non-deterministic sources
//! - Same input must always produce the same scheduling decisions

use std::collections::HashMap;
use std::str::FromStr;
use std::time::Duration;

use chrono::{DateTime, Utc};
use cron::Schedule as CronSchedule;
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
    /// Loop iteration counter (persisted across continue_as_new generations).
    loop_iteration: u64,
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
///
/// Stored as `Option<SubtreeControl>` in the envelope (see `SubtreeEnvelope::control`): a
/// missing field deserializes to `None`, which unambiguously marks an envelope recorded by a
/// pre-#148 binary (`<= v0.2.2`, no control field). A new binary always writes an explicit
/// `Some(Normal)` / `Some(Break)`, so the legacy break-sentinel fallback can be gated to
/// `None` only — keeping a user payload from impersonating control flow on a fresh envelope.
#[derive(serde::Serialize, serde::Deserialize)]
enum SubtreeControl {
    Normal,
    Break,
}

/// Envelope returned by `execute_subtree` containing the SQL result and the updated
/// named-results map so the parent orchestration can merge any new entries after join/race.
/// `control` carries a `df.break()` signal back across the sub-orchestration boundary so the
/// parent can re-raise it as `NodeError::Break` rather than smuggling a sentinel in `result`.
#[derive(serde::Serialize, serde::Deserialize)]
struct SubtreeEnvelope {
    /// `None` only when deserialized from a pre-#148 envelope that had no `control` field; a
    /// new binary always serializes `Some(..)`. `parse_subtree_envelope` relies on this to run
    /// the legacy break-sentinel fallback exclusively on old envelopes.
    #[serde(default)]
    control: Option<SubtreeControl>,
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
        loop_iteration: input.loop_iteration,
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

    let exec_ctx = ExecutionContext {
        vars,
        label,
        loop_iteration: 0,
    };

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
                    control: Some(SubtreeControl::Normal),
                    result,
                    results,
                }
            }
            Err(NodeError::Break(value)) => {
                ctx.trace_info(format!(
                    "ExecuteSubtree: node {node_id} broke (propagating)"
                ));
                SubtreeEnvelope {
                    control: Some(SubtreeControl::Break),
                    result: value,
                    results,
                }
            }
            Err(NodeError::Failure(e)) => return Err(e),
        };

    serde_json::to_string(&envelope)
        .map_err(|e| format!("Failed to serialize subtree envelope: {e}"))
}

/// Compose the deterministic instance id for a JOIN/RACE branch sub-orchestration.
///
/// `schedule_sub_orchestration_with_id` uses this value verbatim (no parent prefix), so we
/// build `{parent_instance_id}::{parent_execution_id}::{child_root_node_id}`. This guarantees
/// (a) the second `::`-token is always the ROOT loop generation — the parent instance id
/// already begins with `{df_instance_id}::{generation}` at every nesting level, so the
/// generation token survives nesting; and (b) per-iteration uniqueness — the parent execution
/// id advances on every loop `continue_as_new`, while the child root node id distinguishes
/// sibling branches. df.instance_nodes() and the write fence both rely on that second token.
fn subtree_instance_id(ctx: &OrchestrationContext, child_root_node_id: &str) -> String {
    format!(
        "{}::{}::{}",
        ctx.instance_id(),
        ctx.execution_id(),
        child_root_node_id
    )
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

    // A *non-root* loop runs as a child sub-orchestration so its `continue_as_new` restarts
    // only the loop body (not the upstream prefix; #227) and a loop nested in a parallel
    // branch gets its own durable instance (#233). The parent does NOT stamp the loop node
    // running/terminal: the child sub-orchestration owns the node as its root and stamps it
    // (see `execute_loop`). Intercept here, before any status stamping. A *root* loop falls
    // through and runs inline via `execute_loop_node`.
    if node.node_type.eq_ignore_ascii_case("loop") && node_id != graph.root_node_id {
        return execute_loop_suborchestration(ctx, graph, node, node_id, results, exec_ctx).await;
    }

    // Stamp identifying which orchestration generation is transitioning this
    // node: "{orchestration_instance_id}::{execution_id}". For the root
    // orchestration this is "{df_instance_id}::{loop_generation}"; for a JOIN/RACE
    // sub-orchestration the instance id already carries the composed lineage (see
    // `subtree_instance_id`), so the second "::"-token is always the root loop
    // generation. df.instance_nodes() parses that token to derive pending/skipped
    // and update_node_status uses it to fence stale writes. Both reads are
    // deterministic (instance_id/execution_id are stable within an execution).
    let execution_stamp = format!("{}::{}", ctx.instance_id(), ctx.execution_id());

    // Mark node as running
    let running_input = serde_json::json!({
        "node_id": node_id,
        "instance_id": graph.instance_id,
        "status": "running",
        "execution_id": execution_stamp,
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
    // the node failed. All three arms schedule exactly one `update_node_status`, so collapse
    // them to a single (status, result) pair to keep the recorded history identical.
    let (status, status_result) = match &execute_result {
        Ok(result) => ("completed", result.as_str()),
        Err(NodeError::Break(value)) => ("completed", value.as_str()),
        Err(NodeError::Failure(err)) => ("failed", err.as_str()),
    };
    let status_input = serde_json::json!({
        "node_id": node_id,
        "instance_id": graph.instance_id,
        "status": status,
        "result": status_result,
        "execution_id": execution_stamp,
    });
    let _ = ctx
        .schedule_activity(
            activities::update_node_status::NAME,
            status_input.to_string(),
        )
        .await;

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

    let config: serde_json::Value = serde_json::from_str(config_str)
        .map_err(|e| format!("Invalid WAIT_SCHEDULE config: {e}"))?;

    let cron_expr = config["cron_expr"]
        .as_str()
        .ok_or_else(|| "WAIT_SCHEDULE missing cron_expr".to_string())?;

    // A cron schedule is a function of "now", so the next tick MUST be computed
    // when this node actually executes — not at df.start() time — so that any
    // delay before execution, and every iteration of a recurring `@>` loop,
    // targets the correct upcoming tick.
    //
    // `ctx.utc_now()` is duroxide's deterministic clock (the only sanctioned way
    // to read wall-clock time in this deterministic file): the value is recorded
    // in history and replayed verbatim. The cron math below is pure given `now`,
    // so the whole computation is replay-safe. The "0 " prefix supplies the
    // seconds field the `cron` crate expects (mirrors df.wait_for_schedule()).
    let now: DateTime<Utc> = ctx
        .utc_now()
        .await
        .map_err(|e| format!("WAIT_SCHEDULE failed to read deterministic clock: {e}"))?
        .into();

    let cron_with_seconds = format!("0 {cron_expr}");
    let schedule = CronSchedule::from_str(&cron_with_seconds)
        .map_err(|e| format!("Invalid cron expression '{cron_expr}': {e}"))?;
    let next = schedule
        .after(&now)
        .next()
        .ok_or_else(|| format!("No upcoming schedule found for '{cron_expr}'"))?;

    // Clamp to zero if the tick is already in the past by the time we get here.
    //
    // NOTE: once duroxide gains an absolute-deadline timer
    // (https://github.com/microsoft/duroxide/issues/34), this `now`-read +
    // subtraction can be replaced with `ctx.schedule_timer_until(next)`, which
    // targets the absolute tick directly and drops the extra utc_now() syscall.
    let wait = (next - now).to_std().unwrap_or(Duration::ZERO);

    ctx.trace_info(format!(
        "Waiting {}s until next schedule tick {next} (cron: {cron_expr})",
        wait.as_secs()
    ));
    ctx.schedule_timer(wait).await;

    Ok(r#"{"scheduled": true}"#.to_string())
}

/// Minimum wall-clock duration that every loop iteration must take before
/// `continue_as_new` is called.  If the body (plus any while-condition
/// evaluation) completes faster than this, a compensating timer makes up the
/// deficit so an empty-bodied loop can't busy-spin via continue_as_new.
const LOOP_MIN_ITER_DURATION: Duration = Duration::from_secs(1);

/// Maximum loop iterations before the orchestration is forcibly terminated.
/// This prevents runaway infinite loops from consuming resources indefinitely.
/// At the minimum 1-second rate limit, this allows ~27 hours of looping.
const MAX_LOOP_ITERATIONS: u64 = 100_000;

/// Orchestration name for the loop sub-orchestration.
///
/// Each `df.loop()` node spawns a child orchestration under this name.  The
/// child handles all iterations via `continue_as_new`; when the loop exits it
/// returns a `SubtreeEnvelope` to the parent.  The parent link is preserved
/// across `continue_as_new` generations by duroxide (see duroxide PR #31), so
/// the parent orchestration is notified when the loop finally completes.
pub const LOOP_NAME: &str = "pg_durable::orchestration::execute-loop";

/// Build the `SubtreeEnvelope` a loop returns to its parent on exit.
///
/// A loop always exits with a *normal* result: a `df.break()` inside the body is the loop's
/// own terminator (caught here as `NodeError::Break`), not a break that should unwind past
/// the loop, so the envelope is always tagged `Normal`. `execute_loop_node` merges `results`
/// back into the parent map via `parse_subtree_envelope`.
fn loop_exit_envelope(result: String, results: HashMap<String, String>) -> Result<String, String> {
    let envelope = SubtreeEnvelope {
        control: Some(SubtreeControl::Normal),
        result,
        results,
    };
    serde_json::to_string(&envelope).map_err(|e| format!("Failed to serialize loop envelope: {e}"))
}

/// Stamp the loop node's status from inside its own (`execute_loop`) sub-orchestration.
///
/// The loop node is the *root* of this child instance, so the child owns its status
/// transitions: `running` at the start of every generation, then `completed`/`failed` on
/// exit. `stamp` is `{child_instance_id}::{execution_id}` — the same `execution_stamp`
/// scheme `execute_function_node_with_vars` uses — whose trailing `::`-token is this child's
/// `continue_as_new` generation. df.instance_nodes()/df.explain() and the write fence read
/// that token to fence stale writes and infer pending/skipped.
async fn stamp_loop_node(
    ctx: &OrchestrationContext,
    instance_id: &str,
    loop_node_id: &str,
    status: &str,
    result: Option<&str>,
    stamp: &str,
) {
    let mut input = serde_json::json!({
        "node_id": loop_node_id,
        "instance_id": instance_id,
        "status": status,
        "execution_id": stamp,
    });
    if let Some(r) = result {
        input["result"] = serde_json::Value::String(r.to_string());
    }
    let _ = ctx
        .schedule_activity(activities::update_node_status::NAME, input.to_string())
        .await;
}

/// Run one iteration of a loop body (and its optional while-condition) for the
/// `execute_loop` sub-orchestration.
///
/// Returns `Ok(Some(final_result))` when the loop should exit (a `df.break()` in the body,
/// or the while-condition evaluating false), `Ok(None)` when another iteration is needed,
/// and `Err` when the body or condition fails. Named results are stored on exit, mirroring
/// the inline root-loop path in `execute_loop_node`.
async fn run_loop_iteration(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    loop_node_id: &str,
    body_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> Result<Option<String>, String> {
    // The loop is where `NodeError::Break` is caught: a break unwinds through the body via
    // `?` and is converted here into the loop's normal exit value.  A `Failure` propagates
    // out of the sub-orchestration unchanged.
    let body_result =
        match execute_function_node_with_vars(ctx, graph, body_id, results, exec_ctx).await {
            Ok(v) => v,
            Err(NodeError::Break(break_value)) => {
                ctx.trace_info(format!(
                    "Loop terminated by break with value: {break_value}"
                ));
                store_named_result(ctx, node, &break_value, results, "LOOP");
                return Ok(Some(break_value));
            }
            Err(NodeError::Failure(e)) => return Err(e),
        };

    // While-condition: if present and false, exit the loop.
    if let Some(ref config_str) = node.query {
        let config: serde_json::Value = serde_json::from_str(config_str).map_err(|e| {
            // M8: Malformed condition config should fail the loop rather than
            // silently creating an infinite loop without exit condition.
            format!("LOOP node {loop_node_id}: failed to parse condition config: {e}")
        })?;
        if let Some(condition_node_id) = config["condition_node"].as_str() {
            ctx.trace_info("Evaluating loop condition");
            let condition_result = match execute_function_node_with_vars(
                ctx,
                graph,
                condition_node_id,
                results,
                exec_ctx,
            )
            .await
            {
                Ok(v) => v,
                Err(NodeError::Break(break_value)) => {
                    store_named_result(ctx, node, &break_value, results, "LOOP");
                    return Ok(Some(break_value));
                }
                Err(NodeError::Failure(e)) => return Err(e),
            };

            // Parse condition result to check truthiness (uses evaluate_condition to extract boolean from SQL result)
            let should_continue = evaluate_condition(&condition_result).unwrap_or(false);
            ctx.trace_info(format!(
                "Loop condition evaluated to: {condition_result} (continue={should_continue})"
            ));

            if !should_continue {
                ctx.trace_info("Loop condition false, exiting loop");
                store_named_result(ctx, node, &body_result, results, "LOOP");
                return Ok(Some(body_result));
            }
        }
    }

    Ok(None)
}

/// Sub-orchestration that runs a single loop iteration and either returns or
/// calls `continue_as_new` for the next iteration.
///
/// Input JSON:
/// ```json
/// { "instance_id": "...", "loop_node_id": "...",
///   "results": "<results_json>", "vars": "<vars_json>", "label": "...",
///   "iteration": 0 }
/// ```
///
/// `load_function_graph` is called at the start of **every** generation
/// (including after `continue_as_new`) so that cross-iteration security
/// tampering is caught and the instance is failed — the same guarantee the
/// main `execute()` orchestration provides at its generation boundary.
///
/// On loop exit the function returns a `SubtreeEnvelope` containing the final
/// result and any named results accumulated during the loop.
pub async fn execute_loop(ctx: OrchestrationContext, input_json: String) -> Result<String, String> {
    let input: serde_json::Value = serde_json::from_str(&input_json)
        .map_err(|e| format!("Failed to parse ExecuteLoop input: {e}"))?;

    let instance_id = input["instance_id"]
        .as_str()
        .ok_or("Missing instance_id in ExecuteLoop input")?
        .to_string();
    let loop_node_id = input["loop_node_id"]
        .as_str()
        .ok_or("Missing loop_node_id in ExecuteLoop input")?
        .to_string();
    let results_json = input["results"]
        .as_str()
        .ok_or("Missing results in ExecuteLoop input")?;

    // Iteration counter threaded across continue_as_new generations (M7).
    // Absent on the first generation (spawned by execute_loop_node), so default to 0.
    let iteration = input["iteration"].as_u64().unwrap_or(0);

    // re-load the graph from the database on every generation — this re-validates
    // submitted_by and catches cross-iteration security tampering.
    let graph_json = ctx
        .schedule_activity(activities::load_function_graph::NAME, instance_id.clone())
        .await?;
    let graph: FunctionGraph = serde_json::from_str(&graph_json)
        .map_err(|e| format!("Failed to parse graph in ExecuteLoop: {e}"))?;

    let mut results: HashMap<String, String> = serde_json::from_str(results_json)
        .map_err(|e| format!("Failed to parse results in ExecuteLoop: {e}"))?;

    let vars: HashMap<String, String> = if let Some(vars_str) = input["vars"].as_str() {
        serde_json::from_str(vars_str)
            .map_err(|e| format!("Failed to parse vars in ExecuteLoop: {e}"))?
    } else {
        HashMap::new()
    };
    let label: Option<String> = input["label"].as_str().map(|s| s.to_string());

    let exec_ctx = ExecutionContext {
        vars,
        label,
        loop_iteration: iteration,
    };

    let node = graph
        .nodes
        .get(&loop_node_id)
        .ok_or_else(|| format!("Loop node not found: {loop_node_id}"))?;

    let body_id = node
        .left_node
        .as_ref()
        .ok_or_else(|| format!("LOOP node {loop_node_id} has no body"))?
        .clone();

    // Capture iteration start time for rate-limiting continue_as_new.
    let iter_started = ctx.utc_now().await.ok();

    // Stamp this loop node as running for the current generation. The loop node is the ROOT
    // of this sub-orchestration, so it is owned and stamped here (not by the parent):
    // running on each generation, completed/failed on exit. The stamp's instance id carries
    // the composed lineage (subtree_instance_id), so the trailing `::`-token is this child's
    // continue_as_new generation — what df.instance_nodes()/df.explain() and the write fence
    // read to infer pending/skipped and to fence stale writes.
    let execution_stamp = format!("{}::{}", ctx.instance_id(), ctx.execution_id());
    stamp_loop_node(
        &ctx,
        &instance_id,
        &loop_node_id,
        "running",
        None,
        &execution_stamp,
    )
    .await;

    ctx.trace_info("Executing loop iteration");

    match run_loop_iteration(
        &ctx,
        &graph,
        node,
        &loop_node_id,
        &body_id,
        &mut results,
        &exec_ctx,
    )
    .await
    {
        Ok(Some(final_result)) => {
            stamp_loop_node(
                &ctx,
                &instance_id,
                &loop_node_id,
                "completed",
                Some(&final_result),
                &execution_stamp,
            )
            .await;
            return loop_exit_envelope(final_result, results);
        }
        Ok(None) => {}
        Err(e) => {
            stamp_loop_node(
                &ctx,
                &instance_id,
                &loop_node_id,
                "failed",
                Some(&e),
                &execution_stamp,
            )
            .await;
            return Err(e);
        }
    }

    ctx.trace_info("Continuing as new for next loop iteration");

    // M7: Enforce maximum iteration count to prevent runaway infinite loops
    let next_iteration = exec_ctx.loop_iteration + 1;
    if next_iteration >= MAX_LOOP_ITERATIONS {
        let e = format!(
            "Loop exceeded maximum iteration count of {MAX_LOOP_ITERATIONS}. \
             Use df.break() to exit the loop or restructure the workflow."
        );
        stamp_loop_node(
            &ctx,
            &instance_id,
            &loop_node_id,
            "failed",
            Some(&e),
            &execution_stamp,
        )
        .await;
        return Err(e);
    }

    // Enforce a minimum per-iteration wall-clock duration to prevent busy-looping.
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

    // Another iteration needed: continue_as_new within this sub-orchestration.
    // The parent orchestration keeps its awaiting handle because duroxide preserves
    // the parent link across continue_as_new (duroxide PR #31).
    ctx.trace_info(format!(
        "Loop continuing with continue_as_new at node {loop_node_id}"
    ));
    let new_results_json = serde_json::to_string(&results)
        .map_err(|e| format!("Failed to serialize updated results: {e}"))?;
    let mut new_input = input.clone();
    new_input["results"] = serde_json::Value::String(new_results_json);
    // Persist the incremented iteration counter for the next generation (M7).
    new_input["iteration"] = serde_json::Value::Number(next_iteration.into());
    let new_input_json = serde_json::to_string(&new_input)
        .map_err(|e| format!("Failed to serialize loop input: {e}"))?;
    ctx.continue_as_new(new_input_json)
        .await
        .map(|_| String::new())
        .map_err(|e| format!("continue_as_new failed: {e:?}"))
}

/// Execute a loop node.
///
/// Only a *root* loop reaches this function: a non-root loop is intercepted in
/// `execute_function_node_with_vars` and delegated to a child sub-orchestration
/// (`execute_loop`) before any status stamping. A root loop runs inline because its
/// `continue_as_new` restarts the root orchestration, and with no upstream prefix to
/// re-execute, re-entering from the root lands back on this same loop node each
/// generation. Running inline also keeps the body's node stamps under the root df
/// instance id (so the second `::`-token of every stamp is the loop generation), which
/// df.instance_nodes()/df.explain() and the write fence rely on.
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
        match serde_json::from_str::<serde_json::Value>(config_str) {
            Ok(config) => {
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
            Err(e) => {
                // M8: Malformed condition config should fail the loop rather than
                // silently creating an infinite loop without exit condition.
                return Err(NodeError::Failure(format!(
                    "LOOP node {node_id}: failed to parse condition config: {e}"
                )));
            }
        }
    }

    ctx.trace_info("Continuing as new for next loop iteration");

    // M7: Enforce maximum iteration count to prevent runaway infinite loops
    let next_iteration = exec_ctx.loop_iteration + 1;
    if next_iteration >= MAX_LOOP_ITERATIONS {
        return Err(NodeError::Failure(format!(
            "Loop exceeded maximum iteration count of {MAX_LOOP_ITERATIONS}. \
             Use df.break() to exit the loop or restructure the workflow."
        )));
    }

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
        loop_iteration: next_iteration,
    };

    // duroxide: continue_as_new returns an awaitable future - return it directly
    ctx.continue_as_new(serde_json::to_string(&new_input).unwrap_or(graph.instance_id.clone()))
        .await
        .map(|_| body_result)
        .map_err(|e| NodeError::Failure(format!("continue_as_new failed: {e:?}")))
}

/// Run a *non-root* loop as a child sub-orchestration.
///
/// A non-root loop must not run inline: its `continue_as_new` would restart the parent
/// orchestration and re-execute the upstream prefix (#227), and a loop nested inside a
/// parallel branch needs its own durable instance (#233). The child (`execute_loop`)
/// advances iterations via its own `continue_as_new`, so the parent's prefix is preserved.
///
/// The child instance id is built with `subtree_instance_id`, giving it the root loop
/// generation as the second `::`-token (for node-status inference and the write fence) and a
/// per-iteration-unique id (the parent execution id advances on each generation, so a loop
/// inside a parallel branch never collides across iterations). The loop node itself is the
/// root of this child instance and is stamped (running/completed/failed) there — NOT by the
/// parent — so the parent invokes this *before* any status stamping (see
/// `execute_function_node_with_vars`).
async fn execute_loop_suborchestration(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    // Validate the loop has a body before spawning the child sub-orchestration.
    node.left_node
        .as_ref()
        .ok_or_else(|| format!("LOOP node {node_id} has no body"))?;

    let results_json =
        serde_json::to_string(results).map_err(|e| format!("Failed to serialize results: {e}"))?;
    let vars_json = serde_json::to_string(&exec_ctx.vars)
        .map_err(|e| format!("Failed to serialize vars: {e}"))?;

    let loop_input = serde_json::json!({
        "instance_id": graph.instance_id,
        "loop_node_id": node_id,
        "results": results_json,
        "vars": vars_json,
        "label": exec_ctx.label,
        "iteration": 0,
    })
    .to_string();

    ctx.trace_info(format!(
        "Spawning loop sub-orchestration for node {node_id}"
    ));

    let raw = ctx
        .schedule_sub_orchestration_with_id(
            LOOP_NAME,
            subtree_instance_id(ctx, node_id),
            loop_input,
        )
        .await
        .map_err(|e| format!("Loop sub-orchestration failed: {e}"))?;

    // Merge named results from the loop sub-orchestration back into the parent map and
    // return the loop's final result.  The loop always returns a `Normal` envelope (a break
    // inside the body is the loop's own terminator), so `parse_subtree_envelope` will not
    // re-raise a `NodeError::Break` here.
    parse_subtree_envelope(&raw, "LOOP", results)
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
/// any normal result. Only envelopes with an absent `control` field (pre-#148 binaries) reach
/// this path; anything written by the new binary carries an explicit `control` and skips it.
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
        Some(SubtreeControl::Break) => Err(NodeError::Break(envelope.result)),
        // A new binary always writes an explicit `control`, so `Some(Normal)` is a genuine
        // normal result and must NOT be run through the legacy sentinel check: otherwise a
        // branch whose real SQL result happens to be shaped like `{"__break__": true, ...}`
        // would be falsely re-raised as a `Break` — exactly the payload-impersonates-control
        // bug class #148 set out to remove.
        Some(SubtreeControl::Normal) => Ok(envelope.result),
        // `None` means the envelope was recorded by a pre-#148 binary (`<= v0.2.2`): it had no
        // `control` field and instead smuggled a break as a `{"__break__": true, ...}`
        // sentinel inside `result`. Re-raise such a legacy sentinel as a typed `Break` so a
        // JOIN/RACE-in-loop break still unwinds when an orchestration started under the old
        // binary resumes under this one, instead of being silently swallowed and treated as a
        // normal branch result.
        None => match parse_legacy_break_sentinel(&envelope.result) {
            Some(value) => Err(NodeError::Break(value)),
            None => Ok(envelope.result),
        },
    }
}

/// Choose the child orchestration (name + input JSON) used to run a JOIN/RACE branch.
///
/// A branch whose root node is a loop is spawned *directly* as an `execute_loop` child: the
/// loop is already the root of its own orchestration and advances via its own
/// `continue_as_new`, so wrapping it in an extra `execute_subtree` layer (which would then
/// itself spawn the loop child) is both redundant and wrong — it would create a third
/// sub-orchestration where only two are expected. Every other branch runs as an
/// `execute_subtree` child. Both children return a `SubtreeEnvelope`, so `parse_subtree_envelope`
/// handles the result identically regardless of which was chosen.
fn branch_child_orchestration(
    graph: &FunctionGraph,
    branch_node_id: &str,
    graph_json: &str,
    results_json: &str,
    vars_json: &str,
    label: &Option<String>,
) -> (&'static str, String) {
    let is_loop = graph
        .nodes
        .get(branch_node_id)
        .map(|n| n.node_type.eq_ignore_ascii_case("loop"))
        .unwrap_or(false);

    if is_loop {
        let input = serde_json::json!({
            "instance_id": graph.instance_id,
            "loop_node_id": branch_node_id,
            "results": results_json,
            "vars": vars_json,
            "label": label,
            "iteration": 0,
        })
        .to_string();
        (LOOP_NAME, input)
    } else {
        let input = serde_json::json!({
            "graph": graph_json,
            "node_id": branch_node_id,
            "results": results_json,
            "vars": vars_json,
            "label": label,
        })
        .to_string();
        (SUBTREE_NAME, input)
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

    // Collect the branch root node ids (left, right, and any join3 extras). Each branch is
    // spawned as its own child sub-orchestration with a deterministic, generation-stamped
    // instance id (see `subtree_instance_id`) so its node stamps carry the root loop
    // generation and remain unique across loop iterations.
    let mut branch_ids: Vec<String> = vec![left_id.clone(), right_id.clone()];

    // Check for extra nodes (join3)
    if let Some(config_str) = &node.query {
        if let Ok(config) = serde_json::from_str::<serde_json::Value>(config_str) {
            if let Some(extra_nodes) = config["extra_nodes"].as_array() {
                for extra_node_val in extra_nodes {
                    if let Some(extra_id) = extra_node_val.as_str() {
                        branch_ids.push(extra_id.to_string());
                    }
                }
            }
        }
    }

    // Schedule each branch. A branch whose root is a loop is spawned directly as an
    // `execute_loop` child (it is already the root of its own orchestration, so it must not
    // be wrapped in an extra `execute_subtree` layer); every other branch runs as an
    // `execute_subtree` child. Both return a `SubtreeEnvelope`.
    let mut durable_futures = Vec::new();
    for child_root in &branch_ids {
        let (name, input) = branch_child_orchestration(
            graph,
            child_root,
            &graph_json,
            &results_json,
            &vars_json,
            &exec_ctx.label,
        );
        let fut = ctx.schedule_sub_orchestration_with_id(
            name,
            subtree_instance_id(ctx, child_root),
            input,
        );
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

    // Schedule each branch with a deterministic, generation-stamped instance id so its node
    // stamps carry the root loop generation (see `subtree_instance_id`). A branch whose root
    // is a loop is spawned directly as an `execute_loop` child (it is already the root of its
    // own orchestration, so it must not be wrapped in an extra `execute_subtree` layer);
    // every other branch runs as an `execute_subtree` child.
    let (left_name, left_input) = branch_child_orchestration(
        graph,
        left_id,
        &graph_json,
        &results_json,
        &vars_json,
        &exec_ctx.label,
    );
    let (right_name, right_input) = branch_child_orchestration(
        graph,
        right_id,
        &graph_json,
        &results_json,
        &vars_json,
        &exec_ctx.label,
    );
    let left_fut = ctx.schedule_sub_orchestration_with_id(
        left_name,
        subtree_instance_id(ctx, left_id),
        left_input,
    );
    let right_fut = ctx.schedule_sub_orchestration_with_id(
        right_name,
        subtree_instance_id(ctx, right_id),
        right_input,
    );

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

    #[test]
    fn envelope_new_format_normal_with_sentinel_shaped_result_is_not_reraised() {
        // Regression guard for the #229 review finding: a new-binary `Normal` envelope whose
        // genuine result happens to be shaped like the legacy break sentinel must pass through
        // untouched. The legacy fallback now runs only when `control` is absent (`None`), so a
        // JOIN/RACE branch result can no longer impersonate control flow under the new binary.
        let payload = legacy_sentinel(serde_json::json!("not-a-break"));
        let raw = envelope_json(Some("Normal"), &payload, serde_json::json!({}));
        let mut parent = HashMap::new();
        assert_eq!(
            expect_ok(parse_subtree_envelope(&raw, "JOIN", &mut parent)),
            payload
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
