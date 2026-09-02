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
use crate::activities::load_function_graph::{TransactionAwareLoadInput, TransactionGraphProbe};
use crate::types::{
    evaluate_condition, string_map_to_json, substitute_all, substitute_all_raw, FunctionGraph,
    FunctionInput, FunctionNode, SystemVars,
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
    /// Node id at the root of the *current* orchestration's node tree: `graph.root_node_id`
    /// for `execute`, the branch/loop node id for `execute_subtree`. A loop sitting on this
    /// node runs inline and drives this orchestration's own `continue_as_new`; any deeper
    /// loop is spawned as a child so its `continue_as_new` cannot re-execute an upstream
    /// prefix (#227).
    subtree_root: String,
    /// Shape of the input this orchestration re-enters itself with on loop `continue_as_new`.
    continuation: Continuation,
}

/// Which input envelope an inline loop must rebuild when it calls `continue_as_new`.
///
/// Both orchestrations that can host an inline loop re-enter themselves, but they are
/// registered with different input shapes, so the loop node handler picks the right one.
#[derive(Clone, Copy)]
enum Continuation {
    /// The root `execute` orchestration, whose input is a `FunctionInput`.
    Root,
    /// An `execute_subtree` child, whose input is a `SubtreeInput`.
    Subtree,
}

/// Input envelope for `execute_subtree`.
///
/// Carries the serialized graph inline. A subtree therefore runs against the same immutable
/// snapshot its parent already validated, and an inline loop re-emits that snapshot across
/// `continue_as_new` — so `df.nodes` is read exactly once per instance and a post-start
/// tamper cannot change the identity a node executes under. Role deletion and privilege
/// revocation are still enforced on every node execution (`execute_sql` connects *as*
/// `submitted_by`; the HTTP activities re-check `EXECUTE` privilege per request).
///
/// `instance_id` is retained alongside the graph so a startup failure can still stamp the
/// subtree root even when the graph itself fails to parse. `iteration` is threaded across
/// `continue_as_new` when the subtree root is a loop.
#[derive(serde::Serialize, serde::Deserialize)]
struct SubtreeInput {
    instance_id: String,
    node_id: String,
    /// Serialized `FunctionGraph` snapshot inherited from the parent.
    graph: String,
    /// JSON-encoded named-results map inherited from the parent.
    results: String,
    /// JSON-encoded workflow vars map.
    #[serde(default)]
    vars: Option<String>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    iteration: u64,
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

const INITIAL_TRANSACTION_POLL_MS: u64 = 100;
const MAX_TRANSACTION_POLL_MS: u64 = 5_000;
const GRAPH_WAIT_POLLS_PER_EXECUTION: u32 = 64;
/// Bound on how many transient `Retry` outcomes (DB errors, query timeouts,
/// snapshot-visibility lag - see `probe_transaction`) a single graph admission
/// will absorb before failing the orchestration outright. Unlike waiting on
/// the caller's own open transaction (`InProgress`, legitimately unbounded),
/// these retries indicate the worker's own machinery is unhealthy, and
/// polling forever would hide a permanent problem behind misleading
/// "waiting on transaction" logs.
const MAX_GRAPH_RETRY_ATTEMPTS: u32 = 20;

/// Bound on how many times a *terminal* `df.instances` status write
/// (`completed`/`failed`) is durably retried before the orchestration gives up.
/// The engine execution is already terminal at these sites, so a dropped write
/// would leave `df.status()` / `df.await_instance()` trusting a stale
/// non-terminal row indefinitely. Retrying across durable timers lets a
/// transient management-plane outage self-heal once the database recovers,
/// while the bound still prevents an unhealthy worker from spinning forever.
const MAX_STATUS_FINALIZE_ATTEMPTS: u32 = 20;

fn transaction_poll_delay(attempt: u32) -> Duration {
    let multiplier = 1u64 << attempt.min(6);
    Duration::from_millis(
        INITIAL_TRANSACTION_POLL_MS
            .saturating_mul(multiplier)
            .min(MAX_TRANSACTION_POLL_MS),
    )
}

fn should_compact_graph_wait(polls_in_execution: u32) -> bool {
    polls_in_execution >= GRAPH_WAIT_POLLS_PER_EXECUTION
}

/// Whether the bounded transient-retry budget for graph admission has been
/// exhausted. Pure so the boundary (`== MAX_GRAPH_RETRY_ATTEMPTS` vs `>`) has
/// direct unit coverage.
fn graph_retry_budget_exceeded(retry_attempt: u32) -> bool {
    retry_attempt > MAX_GRAPH_RETRY_ATTEMPTS
}

fn graph_wait_continuation(
    input: &FunctionInput,
    next_wait_attempt: u32,
    next_retry_attempt: u32,
) -> Result<String, serde_json::Error> {
    let mut continuation = input.clone();
    continuation.graph_wait_attempt = next_wait_attempt;
    continuation.graph_retry_attempt = next_retry_attempt;
    serde_json::to_string(&continuation)
}

async fn load_initial_graph(
    ctx: &OrchestrationContext,
    input: &FunctionInput,
) -> Result<String, String> {
    let Some(origin_xid) = input.origin_xid.as_ref() else {
        // Replay compatibility: historical FunctionInput payloads have no xid.
        // They must schedule the original activity name with the exact original
        // raw instance-id input bytes.
        return ctx
            .schedule_activity(
                activities::load_function_graph::NAME,
                input.instance_id.clone(),
            )
            .await;
    };

    let probe_input = serde_json::to_string(&TransactionAwareLoadInput {
        instance_id: input.instance_id.clone(),
        origin_xid: origin_xid.clone(),
    })
    .map_err(|e| format!("Failed to serialize transaction-aware graph probe: {e}"))?;

    let mut wait_attempt = input.graph_wait_attempt;
    let mut retry_attempt = input.graph_retry_attempt;
    let mut polls_in_execution = 0u32;
    loop {
        let raw = ctx
            .schedule_activity(
                activities::load_function_graph::TRANSACTION_AWARE_NAME,
                probe_input.clone(),
            )
            .await?;
        let probe: TransactionGraphProbe = serde_json::from_str(&raw)
            .map_err(|e| format!("Failed to parse transaction-aware graph probe result: {e}"))?;

        match probe {
            TransactionGraphProbe::Ready { graph } => return Ok(graph),
            TransactionGraphProbe::InProgress => {
                let delay = transaction_poll_delay(wait_attempt);
                ctx.trace_info(format!(
                    "Instance {} graph is waiting on origin transaction {}; retrying in {:?}",
                    input.instance_id, origin_xid, delay
                ));
                ctx.schedule_timer(delay).await;
                wait_attempt = wait_attempt.saturating_add(1);
                polls_in_execution = polls_in_execution.saturating_add(1);

                if should_compact_graph_wait(polls_in_execution) {
                    let continuation_json =
                        graph_wait_continuation(input, wait_attempt, retry_attempt).map_err(
                            |e| format!("Failed to serialize graph-wait continuation: {e}"),
                        )?;
                    ctx.trace_info(format!(
                        "Compacting graph-admission history for instance {} after {} polls",
                        input.instance_id, polls_in_execution
                    ));
                    return ctx.continue_as_new(continuation_json).await;
                }
            }
            TransactionGraphProbe::Retry => {
                retry_attempt = retry_attempt.saturating_add(1);
                if graph_retry_budget_exceeded(retry_attempt) {
                    return Err(format!(
                        "Instance {} graph admission for origin transaction {} failed: \
                         exceeded {MAX_GRAPH_RETRY_ATTEMPTS} transient retries",
                        input.instance_id, origin_xid
                    ));
                }
                let delay = transaction_poll_delay(retry_attempt);
                ctx.trace_info(format!(
                    "Instance {} graph admission for origin transaction {} hit a transient \
                     failure ({}/{MAX_GRAPH_RETRY_ATTEMPTS}); retrying in {:?}",
                    input.instance_id, origin_xid, retry_attempt, delay
                ));
                ctx.schedule_timer(delay).await;
                polls_in_execution = polls_in_execution.saturating_add(1);

                if should_compact_graph_wait(polls_in_execution) {
                    let continuation_json =
                        graph_wait_continuation(input, wait_attempt, retry_attempt).map_err(
                            |e| format!("Failed to serialize graph-wait continuation: {e}"),
                        )?;
                    ctx.trace_info(format!(
                        "Compacting graph-admission history for instance {} after {} polls",
                        input.instance_id, polls_in_execution
                    ));
                    return ctx.continue_as_new(continuation_json).await;
                }
            }
            TransactionGraphProbe::Aborted => {
                return Err(format!(
                    "Instance {} origin transaction {} aborted before its graph became visible",
                    input.instance_id, origin_xid
                ))
            }
            TransactionGraphProbe::CommittedMissing => {
                return Err(format!(
                    "Instance {} origin transaction {} committed but its instance graph is absent \
                     (the start may have been rolled back to a savepoint)",
                    input.instance_id, origin_xid
                ))
            }
        }
    }
}

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
    #[serde(serialize_with = "crate::types::serialize_string_map")]
    results: HashMap<String, String>,
}

/// Durably drive a *terminal* `df.instances` status write to completion.
///
/// The engine execution is already terminal when this is called, so a
/// best-effort write that is silently dropped on a transient database/pool
/// failure would leave `df.status()` / `df.await_instance()` trusting a stale
/// non-terminal (`pending`/`running`) row while the engine is finished — the
/// two status surfaces diverging indefinitely. Retry the update activity across
/// durable timers so a transient management-plane outage self-heals once the
/// database recovers. The retry budget is bounded (`MAX_STATUS_FINALIZE_ATTEMPTS`)
/// so a persistently unhealthy worker cannot spin forever; on exhaustion the
/// divergence is at least surfaced in the trace rather than hidden.
///
/// This is deterministic: activity results and timer fires are recorded in
/// history, so replay follows the same attempt sequence.
async fn finalize_instance_status(ctx: &OrchestrationContext, instance_id: &str, status: &str) {
    let status_input = serde_json::json!({
        "instance_id": instance_id,
        "status": status,
    })
    .to_string();

    let mut attempt = 0u32;
    loop {
        match ctx
            .schedule_activity(
                activities::update_instance_status::NAME,
                status_input.clone(),
            )
            .await
        {
            Ok(_) => return,
            Err(e) => {
                if attempt >= MAX_STATUS_FINALIZE_ATTEMPTS {
                    ctx.trace_info(format!(
                        "Instance {instance_id}: giving up finalizing status to '{status}' after \
                         {MAX_STATUS_FINALIZE_ATTEMPTS} attempts; df.instances may remain \
                         non-terminal while the engine execution is terminal: {e}"
                    ));
                    return;
                }
                let delay = transaction_poll_delay(attempt);
                ctx.trace_info(format!(
                    "Instance {instance_id}: finalizing status to '{status}' failed \
                     (attempt {attempt}/{MAX_STATUS_FINALIZE_ATTEMPTS}); retrying in {delay:?}: {e}"
                ));
                ctx.schedule_timer(delay).await;
                attempt = attempt.saturating_add(1);
            }
        }
    }
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

    // Generation 0 loads the graph from the database; a root loop continuing as new carries
    // it inline, so an instance reads `df.nodes` exactly once however many iterations it runs.
    // That load is also the admission check (`submitted_by` resolution plus the superuser
    // guard), which belongs at instance start rather than on every iteration — re-reading
    // mid-flight would make a post-start tamper of `df.nodes.submitted_by` take effect
    // instead of being ignored.
    let graph_json = match input.graph.clone() {
        Some(json) => json,
        None => match load_initial_graph(&ctx, &input).await {
            Ok(json) => json,
            Err(e) => {
                // load_function_graph failed (e.g., superuser blocked).
                // Mark the instance as failed before propagating. The engine
                // execution is about to end terminally, so this terminal write
                // is retried durably rather than dropped — otherwise the row
                // would stay non-terminal while the engine is failed.
                finalize_instance_status(&ctx, &input.instance_id, "failed").await;
                return Err(e);
            }
        },
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
        subtree_root: graph.root_node_id.clone(),
        continuation: Continuation::Root,
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
            finalize_instance_status(&ctx, &input.instance_id, "completed").await;
        }
        Err(err) => {
            ctx.trace_info(format!("Function failed with error: {err}"));
            finalize_instance_status(&ctx, &input.instance_id, "failed").await;
        }
    }

    function_result
}

/// Execute a subtree of a function graph rooted at `node_id`.
///
/// Used for JOIN/RACE branches and for any non-root `df.loop()`. Structurally this mirrors
/// `execute`: it roots an `ExecutionContext` at its own node and — when that node is a loop —
/// lets the loop drive `continue_as_new` on *this* orchestration. Because the subtree has no
/// upstream prefix, re-entering from its root lands back on the same loop node each
/// generation, exactly as it does for a root loop in `execute`.
///
/// Unlike `execute`, this never loads the graph (the parent passes it inline) and never
/// touches instance-level status: the parent owns that.
pub async fn execute_subtree(
    ctx: OrchestrationContext,
    input_json: String,
) -> Result<String, String> {
    let input: SubtreeInput = serde_json::from_str(&input_json)
        .map_err(|e| format!("Failed to parse ExecuteSubtree input: {e}"))?;

    // The subtree root is owned by this child instance, so stamp it failed on any startup
    // error. Without this a child that dies before `execute_function_node_with_vars` runs
    // would leave its root node stuck in a non-terminal state (the parent does not stamp
    // branch roots).
    let fail = |ctx: &OrchestrationContext, e: String| {
        let stamp = format!("{}::{}", ctx.instance_id(), ctx.execution_id());
        let status_input = serde_json::json!({
            "node_id": input.node_id,
            "instance_id": input.instance_id,
            "status": "failed",
            "result": e,
            "execution_id": stamp,
        });
        (status_input.to_string(), e)
    };

    ctx.trace_info(format!(
        "ExecuteSubtree: executing node {} (iteration {})",
        input.node_id, input.iteration
    ));

    // The graph arrives inline from the parent — no database read here. The subtree runs
    // against the snapshot the parent already validated, and an inline loop re-emits it on
    // `continue_as_new`, so nothing re-reads `df.nodes` mid-flight.
    let parsed = serde_json::from_str::<FunctionGraph>(&input.graph)
        .map_err(|e| format!("Failed to parse graph in ExecuteSubtree: {e}"))
        .and_then(|graph| {
            let results: HashMap<String, String> = serde_json::from_str(&input.results)
                .map_err(|e| format!("Failed to parse results in ExecuteSubtree: {e}"))?;
            let vars: HashMap<String, String> = match input.vars.as_deref() {
                Some(vars_json) => serde_json::from_str(vars_json)
                    .map_err(|e| format!("Failed to parse vars in ExecuteSubtree: {e}"))?,
                None => HashMap::new(),
            };
            Ok((graph, results, vars))
        });

    let (graph, mut results, vars) = match parsed {
        Ok(parsed) => parsed,
        Err(e) => {
            let (status_input, e) = fail(&ctx, e);
            let _ = ctx
                .schedule_activity(activities::update_node_status::NAME, status_input)
                .await;
            return Err(e);
        }
    };

    let exec_ctx = ExecutionContext {
        vars,
        label: input.label.clone(),
        loop_iteration: input.iteration,
        subtree_root: input.node_id.clone(),
        continuation: Continuation::Subtree,
    };

    // Build the envelope carrying the result, the updated named-results map, and a typed
    // control signal. A `Break` inside the subtree is re-encoded as `control: Break` (not a
    // sentinel smuggled inside `result`) so the parent can re-raise it as `NodeError::Break`.
    // A genuine `Failure` propagates as `Err` across the sub-orchestration boundary.
    //
    // When the root node is a loop that needs another iteration it calls `continue_as_new`,
    // whose future never resolves — so none of the arms below run for a continuing
    // generation, and no envelope is produced until the loop actually exits.
    let envelope = match execute_function_node_with_vars(
        &ctx,
        &graph,
        &input.node_id,
        &mut results,
        &exec_ctx,
    )
    .await
    {
        Ok(result) => {
            ctx.trace_info(format!("ExecuteSubtree: node {} completed", input.node_id));
            SubtreeEnvelope {
                control: Some(SubtreeControl::Normal),
                result,
                results,
            }
        }
        Err(NodeError::Break(value)) => {
            ctx.trace_info(format!(
                "ExecuteSubtree: node {} broke (propagating)",
                input.node_id
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

/// Build the `execute_subtree` input for a child rooted at `node_id`.
///
/// Shared by JOIN/RACE branch scheduling and by non-root loop spawning — all three are the
/// same operation now: run this node in its own durable instance.
fn build_subtree_input(
    graph: &FunctionGraph,
    node_id: &str,
    results: &HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> Result<String, String> {
    let input = SubtreeInput {
        instance_id: graph.instance_id.clone(),
        node_id: node_id.to_string(),
        graph: serde_json::to_string(graph)
            .map_err(|e| format!("Failed to serialize graph: {e}"))?,
        results: string_map_to_json(results)
            .map_err(|e| format!("Failed to serialize results: {e}"))?,
        vars: Some(
            string_map_to_json(&exec_ctx.vars)
                .map_err(|e| format!("Failed to serialize vars: {e}"))?,
        ),
        label: exec_ctx.label.clone(),
        iteration: 0,
    };
    serde_json::to_string(&input).map_err(|e| format!("Failed to serialize subtree input: {e}"))
}

/// Compose the deterministic instance id for a JOIN/RACE branch sub-orchestration.
///
/// `schedule_sub_orchestration_with_id` uses this value verbatim (no parent prefix), so we
/// build `{parent_instance_id}::{parent_execution_id}::{child_root_node_id}`. This guarantees
/// a complete parent-to-child lineage and per-generation uniqueness: the parent execution id
/// advances on every loop `continue_as_new`, while the child root node id distinguishes sibling
/// branches. df.instance_nodes() and the write fence walk the full composed lineage.
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

    // A loop that is NOT the root of the current orchestration's node tree runs as a child
    // sub-orchestration, so its `continue_as_new` restarts only the loop body rather than
    // re-executing the upstream prefix (#227), and a loop nested in a parallel branch gets
    // its own durable instance (#233). The parent does NOT stamp such a loop node
    // running/terminal: the child owns the node as its root and stamps it there. Intercept
    // here, before any status stamping.
    //
    // A loop that IS this orchestration's root falls through and runs inline via
    // `execute_loop_node`, driving `continue_as_new` on this orchestration. That is safe
    // precisely because there is no upstream prefix to re-execute: re-entering from the root
    // lands back on this same loop node. This holds identically for the root `execute`
    // orchestration and for an `execute_subtree` child rooted at a loop.
    if node.node_type.eq_ignore_ascii_case("loop") && node_id != exec_ctx.subtree_root {
        return execute_loop_suborchestration(ctx, graph, node, node_id, results, exec_ctx).await;
    }

    // Stamp identifying which orchestration generation is transitioning this
    // node: "{orchestration_instance_id}::{execution_id}". For the root
    // orchestration this is "{df_instance_id}::{loop_generation}"; for a JOIN/RACE
    // sub-orchestration the instance id already carries the composed lineage (see
    // `subtree_instance_id`). df.instance_nodes() and update_node_status walk the
    // lineage generations to infer superseded nodes and fence stale writes. Both
    // reads are deterministic (instance_id/execution_id are stable within an execution).
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
        "http_multipart" => {
            execute_http_multipart_node(ctx, node, node_id, results, exec_ctx, &sys_vars).await
        }
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

/// Stamp a loop node's status from its *parent* orchestration.
///
/// A non-root loop node is the root of its own child instance, so the child normally owns
/// its status transitions (via `execute_function_node_with_vars`). This helper covers the
/// cases where the child never got far enough to stamp itself — spawn failure, a failed
/// branch future, or a losing RACE branch — and the parent must record a terminal state so
/// the node does not linger as running.
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

async fn fail_loop_before_start(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    loop_node_id: &str,
    error: String,
) -> NodeResult {
    let execution_stamp = format!("{}::{}", ctx.instance_id(), ctx.execution_id());
    stamp_loop_node(
        ctx,
        &graph.instance_id,
        loop_node_id,
        "failed",
        Some(&error),
        &execution_stamp,
    )
    .await;
    Err(NodeError::Failure(error))
}

async fn fail_loop_child_future(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    loop_node_id: &str,
    error: String,
) -> NodeResult {
    let child_stamp = format!("{}::1", subtree_instance_id(ctx, loop_node_id));
    stamp_loop_node(
        ctx,
        &graph.instance_id,
        loop_node_id,
        "failed",
        Some(&error),
        &child_stamp,
    )
    .await;
    Err(NodeError::Failure(error))
}

/// Run one iteration of a loop body (and its optional while-condition).
///
/// Shared by both inline loop paths: a loop at the root of the root orchestration and a
/// loop at the root of an `execute_subtree` child.
///
/// Returns `Ok(Some(final_result))` when the loop should exit (a `df.break()` in the body,
/// or the while-condition evaluating false), `Ok(None)` when another iteration is needed,
/// and `Err` when the body or condition fails.
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

/// Execute a loop node inline, driving the *current* orchestration's `continue_as_new`.
///
/// Only a loop sitting at `exec_ctx.subtree_root` reaches this function; a deeper loop is
/// intercepted in `execute_function_node_with_vars` and delegated to a child. Running the
/// root loop inline is safe because there is no upstream prefix to re-execute: re-entering
/// this orchestration from its root lands back on this same loop node each generation.
///
/// Both hosts are handled: the root `execute` orchestration and an `execute_subtree` child
/// rooted at the loop node. They differ only in the input envelope they re-enter with, which
/// `exec_ctx.continuation` selects.
///
/// Note that `ctx.continue_as_new()` returns a future that never resolves, so on a
/// continuing generation this function does not return and the caller's terminal node
/// stamping never runs — the loop node stays `running` until it actually exits.
async fn execute_loop_node(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    debug_assert_eq!(
        node_id, exec_ctx.subtree_root,
        "inline loop must be the current orchestration's root"
    );

    let body_id = node
        .left_node
        .as_ref()
        .ok_or_else(|| format!("LOOP node {node_id} has no body"))?;

    // Capture the iteration start time so we can rate-limit `continue_as_new`
    // below.  `utc_now()` is duroxide's deterministic clock (recorded in
    // history and replayed verbatim), so this remains replay-safe.
    let iter_started = ctx.utc_now().await.ok();

    ctx.trace_info("Executing loop iteration");

    if let Some(final_result) = Box::pin(run_loop_iteration(
        ctx, graph, node, node_id, body_id, results, exec_ctx,
    ))
    .await
    .map_err(NodeError::Failure)?
    {
        return Ok(final_result);
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

    // Rebuild this orchestration's own input for the next generation. The root
    // orchestration re-enters with a `FunctionInput` (named results are rebuilt from
    // scratch, as they always have been); an `execute_subtree` child re-enters with a
    // `SubtreeInput` that threads the accumulated named results forward.
    // Rebuild this orchestration's own input for the next generation. The root
    // orchestration re-enters with a `FunctionInput` (named results are rebuilt from
    // scratch, as they always have been); an `execute_subtree` child re-enters with a
    // `SubtreeInput` that threads the accumulated named results forward. Both carry the
    // graph snapshot forward so no generation re-reads `df.nodes`.
    let graph_json =
        serde_json::to_string(graph).map_err(|e| format!("Failed to serialize graph: {e}"))?;
    let new_input_json = match exec_ctx.continuation {
        Continuation::Root => {
            let new_input = FunctionInput {
                instance_id: graph.instance_id.clone(),
                label: exec_ctx.label.clone(),
                vars: exec_ctx.vars.clone(),
                loop_iteration: next_iteration,
                graph: Some(graph_json),
                origin_xid: None,
                graph_wait_attempt: 0,
                graph_retry_attempt: 0,
            };
            serde_json::to_string(&new_input)
                .map_err(|e| format!("Failed to serialize loop input: {e}"))?
        }
        Continuation::Subtree => {
            let new_input = SubtreeInput {
                instance_id: graph.instance_id.clone(),
                node_id: node_id.to_string(),
                graph: graph_json,
                results: string_map_to_json(results)
                    .map_err(|e| format!("Failed to serialize updated results: {e}"))?,
                vars: Some(
                    string_map_to_json(&exec_ctx.vars)
                        .map_err(|e| format!("Failed to serialize vars: {e}"))?,
                ),
                label: exec_ctx.label.clone(),
                iteration: next_iteration,
            };
            serde_json::to_string(&new_input)
                .map_err(|e| format!("Failed to serialize loop input: {e}"))?
        }
    };

    // duroxide: continue_as_new returns an awaitable future - return it directly
    ctx.continue_as_new(new_input_json)
        .await
        .map(|_| String::new())
        .map_err(|e| NodeError::Failure(format!("continue_as_new failed: {e:?}")))
}

/// Run a loop that is *not* the current orchestration's root as a child sub-orchestration.
///
/// Such a loop must not run inline: its `continue_as_new` would restart the parent
/// orchestration and re-execute the upstream prefix (#227), and a loop nested inside a
/// parallel branch needs its own durable instance (#233). The child is an ordinary
/// `execute_subtree` rooted at the loop node, which then runs the loop inline and advances
/// iterations via its own `continue_as_new` — so the parent's prefix is preserved.
///
/// The child instance id is built with `subtree_instance_id`, preserving every ancestor
/// scope and generation for node-status inference and the write fence. It is unique per
/// iteration because the parent execution id advances on each generation, so a loop inside
/// a parallel branch never collides across iterations. The loop node itself is the
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
    if node.left_node.is_none() {
        return fail_loop_before_start(
            ctx,
            graph,
            node_id,
            format!("LOOP node {node_id} has no body"),
        )
        .await;
    }

    let loop_input = match build_subtree_input(graph, node_id, results, exec_ctx) {
        Ok(input) => input,
        Err(e) => {
            return fail_loop_before_start(ctx, graph, node_id, e).await;
        }
    };

    ctx.trace_info(format!(
        "Spawning loop sub-orchestration for node {node_id}"
    ));

    let raw = match ctx
        .schedule_sub_orchestration_with_id(
            SUBTREE_NAME,
            subtree_instance_id(ctx, node_id),
            loop_input,
        )
        .await
    {
        Ok(raw) => raw,
        Err(e) => {
            return fail_loop_child_future(
                ctx,
                graph,
                node_id,
                format!("Loop sub-orchestration failed: {e}"),
            )
            .await;
        }
    };

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

async fn cancel_losing_loop_branch(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    branch_node_id: &str,
) {
    let is_loop = graph
        .nodes
        .get(branch_node_id)
        .map(|node| node.node_type.eq_ignore_ascii_case("loop"))
        .unwrap_or(false);
    if !is_loop {
        return;
    }

    let child_instance_id = subtree_instance_id(ctx, branch_node_id);
    let child_stamp = format!("{child_instance_id}::1");
    stamp_loop_node(
        ctx,
        &graph.instance_id,
        branch_node_id,
        "failed",
        Some("Loop branch cancelled after losing RACE"),
        &child_stamp,
    )
    .await;
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

    // Schedule each branch as an `execute_subtree` child rooted at the branch node. A branch
    // whose root is a loop needs no special case: `execute_subtree` runs a root loop inline
    // and drives its own `continue_as_new`, so exactly one child instance is created either
    // way, and every branch returns a `SubtreeEnvelope`.
    let mut durable_futures = Vec::new();
    for child_root in &branch_ids {
        let input = build_subtree_input(graph, child_root, results, exec_ctx)?;
        let fut = ctx.schedule_sub_orchestration_with_id(
            SUBTREE_NAME,
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
                if graph
                    .nodes
                    .get(&branch_ids[i])
                    .map(|branch| branch.node_type.eq_ignore_ascii_case("loop"))
                    .unwrap_or(false)
                {
                    return fail_loop_child_future(
                        ctx,
                        graph,
                        &branch_ids[i],
                        format!("JOIN branch {} failed: {}", i + 1, e),
                    )
                    .await;
                }
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

    // Schedule each branch as an `execute_subtree` child with a deterministic,
    // generation-stamped instance id so its node stamps carry the root loop generation (see
    // `subtree_instance_id`). A branch whose root is a loop needs no special case:
    // `execute_subtree` runs a root loop inline and drives its own `continue_as_new`.
    let left_input = build_subtree_input(graph, left_id, results, exec_ctx)?;
    let right_input = build_subtree_input(graph, right_id, results, exec_ctx)?;
    let left_fut = ctx.schedule_sub_orchestration_with_id(
        SUBTREE_NAME,
        subtree_instance_id(ctx, left_id),
        left_input,
    );
    let right_fut = ctx.schedule_sub_orchestration_with_id(
        SUBTREE_NAME,
        subtree_instance_id(ctx, right_id),
        right_input,
    );

    // Use ctx.select2() - first to complete wins
    // select2 now returns Either2<Left, Right> instead of (winner_idx, DurableOutput)
    let raw = match ctx.select2(left_fut, right_fut).await {
        duroxide::Either2::First(Ok(r)) => {
            ctx.trace_info("RACE completed - left branch won");
            cancel_losing_loop_branch(ctx, graph, right_id).await;
            Ok(r)
        }
        duroxide::Either2::First(Err(e)) => {
            cancel_losing_loop_branch(ctx, graph, right_id).await;
            if graph
                .nodes
                .get(left_id)
                .map(|branch| branch.node_type.eq_ignore_ascii_case("loop"))
                .unwrap_or(false)
            {
                return fail_loop_child_future(
                    ctx,
                    graph,
                    left_id,
                    format!("RACE left branch failed: {e}"),
                )
                .await;
            }
            Err(format!("RACE left branch failed: {e}"))
        }
        duroxide::Either2::Second(Ok(r)) => {
            ctx.trace_info("RACE completed - right branch won");
            cancel_losing_loop_branch(ctx, graph, left_id).await;
            Ok(r)
        }
        duroxide::Either2::Second(Err(e)) => {
            cancel_losing_loop_branch(ctx, graph, left_id).await;
            if graph
                .nodes
                .get(right_id)
                .map(|branch| branch.node_type.eq_ignore_ascii_case("loop"))
                .unwrap_or(false)
            {
                return fail_loop_child_future(
                    ctx,
                    graph,
                    right_id,
                    format!("RACE right branch failed: {e}"),
                )
                .await;
            }
            Err(format!("RACE right branch failed: {e}"))
        }
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

async fn execute_http_multipart_node(
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
        .ok_or_else(|| format!("HTTP_MULTIPART node {node_id} has no config"))?;

    let mut config: serde_json::Value = serde_json::from_str(config_str)
        .map_err(|e| format!("Invalid multipart HTTP config: {e}"))?;

    // Substitute variables in URL.
    if let Some(url) = config.get("url").and_then(|u| u.as_str()) {
        let substituted_url = substitute_all_raw(url, results, &exec_ctx.vars, sys_vars)?;
        config["url"] = serde_json::Value::String(substituted_url);
    }

    // Substitute variables in headers (same pattern as execute_http_node).
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

    // Substitute variables in each part's text metadata (name, filename) with
    // the usual inline rules.
    //
    // `data_b64` follows a stricter rule: it is substituted only when its entire
    // value is a single reference (e.g. `$speech.body` or `{payload}`). That is
    // what lets one step's output become the next step's upload. Splicing a
    // substitution into the *middle* of a base64 string, by contrast, can only
    // corrupt the payload, so partial interpolation is rejected outright rather
    // than silently producing garbage. The base64 alphabet contains neither `$`
    // nor `{`, so their presence is unambiguously an attempted reference.
    if let Some(parts) = config.get_mut("parts").and_then(|p| p.as_array_mut()) {
        for part in parts.iter_mut() {
            if let Some(name) = part.get("name").and_then(|n| n.as_str()) {
                let substituted = substitute_all_raw(name, results, &exec_ctx.vars, sys_vars)?;
                part["name"] = serde_json::Value::String(substituted);
            }
            if let Some(filename) = part.get("filename").and_then(|f| f.as_str()) {
                let substituted = substitute_all_raw(filename, results, &exec_ctx.vars, sys_vars)?;
                part["filename"] = serde_json::Value::String(substituted);
            }
            if let Some(data_b64) = part.get("data_b64").and_then(|d| d.as_str()) {
                if crate::types::is_whole_value_reference(data_b64) {
                    let substituted =
                        substitute_all_raw(data_b64, results, &exec_ctx.vars, sys_vars)?;
                    part["data_b64"] = serde_json::Value::String(substituted);
                } else if data_b64.contains('$') || data_b64.contains('{') {
                    let part_name = part.get("name").and_then(|n| n.as_str()).unwrap_or("?");
                    return Err(NodeError::Failure(format!(
                        "HTTP_MULTIPART node {node_id}: data_b64 for part '{part_name}' mixes a \
                         variable reference with other text. Only a whole-value reference is \
                         supported (e.g. data_b64 => '$result' or '{{myvar}}'), because splicing \
                         into base64 would corrupt the payload."
                    )));
                }
            }
        }
    }

    // Inject audit context from the function node.
    config["submitted_by"] = serde_json::Value::String(node.submitted_by.clone());

    let final_config = config.to_string();
    let url = config["url"].as_str().unwrap_or("?");
    let method = config["method"].as_str().unwrap_or("POST");
    ctx.trace_info(format!("Executing HTTP_MULTIPART {method} {url}"));

    let result = ctx
        .schedule_activity(activities::execute_multipart::NAME, final_config)
        .await?;

    // Store result if named
    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing HTTP_MULTIPART result as ${name}"));
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
    fn transaction_poll_backoff_is_deterministic_and_capped() {
        assert_eq!(transaction_poll_delay(0), Duration::from_millis(100));
        assert_eq!(transaction_poll_delay(1), Duration::from_millis(200));
        assert_eq!(transaction_poll_delay(5), Duration::from_millis(3_200));
        assert_eq!(transaction_poll_delay(6), Duration::from_millis(5_000));
        assert_eq!(
            transaction_poll_delay(u32::MAX),
            Duration::from_millis(5_000)
        );
        assert!(!should_compact_graph_wait(
            GRAPH_WAIT_POLLS_PER_EXECUTION - 1
        ));
        assert!(should_compact_graph_wait(GRAPH_WAIT_POLLS_PER_EXECUTION));
        assert!(should_compact_graph_wait(u32::MAX));
    }

    #[test]
    fn graph_wait_compaction_preserves_admission_state_only() {
        let input = FunctionInput {
            instance_id: "deadbeef".to_string(),
            label: Some("waiting".to_string()),
            vars: HashMap::from([("key".to_string(), "value".to_string())]),
            loop_iteration: 7,
            graph: None,
            origin_xid: Some("12345".to_string()),
            graph_wait_attempt: 63,
            graph_retry_attempt: 2,
        };

        let json = graph_wait_continuation(&input, 64, 3).unwrap();
        let continued: FunctionInput = serde_json::from_str(&json).unwrap();
        assert_eq!(continued.instance_id, input.instance_id);
        assert_eq!(continued.label, input.label);
        assert_eq!(continued.vars, input.vars);
        assert_eq!(continued.loop_iteration, 7);
        assert_eq!(continued.graph, None);
        assert_eq!(continued.origin_xid.as_deref(), Some("12345"));
        assert_eq!(continued.graph_wait_attempt, 64);
        assert_eq!(continued.graph_retry_attempt, 3);
    }

    #[test]
    fn graph_retry_budget_exceeded_allows_exactly_max_attempts() {
        assert!(!graph_retry_budget_exceeded(0));
        assert!(!graph_retry_budget_exceeded(MAX_GRAPH_RETRY_ATTEMPTS));
        assert!(graph_retry_budget_exceeded(MAX_GRAPH_RETRY_ATTEMPTS + 1));
        assert!(graph_retry_budget_exceeded(u32::MAX));
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
