# Proposal: Retry Support for pg_durable

**Status:** Proposal

## Problem

Today, any node failure (SQL error, terminated connection, transient network issue) immediately fails the entire durable function. There is no retry mechanism. This was confirmed experimentally:

- **Loop:** A single iteration failure (e.g., backend terminated during `pg_sleep`) causes the entire loop to fail permanently. The `await?` operator in `execute_loop_node` propagates the error immediately.
- **Sequence:** A failed step fails the entire sequence. Subsequent steps are never executed.
- **HTTP:** A transient 5xx or network timeout fails the function.

This is problematic for real-world use cases: heartbeat loops, polling jobs, webhook deliveries, and AI pipelines all encounter transient failures that should not kill the entire function.

## Duroxide Retry Support

Duroxide already has a fully implemented `schedule_activity_with_retry()` API. pg_durable simply doesn't use it yet — all 8 `schedule_activity` call sites in `execute_function_graph.rs` use the non-retry variant.

### Duroxide `RetryPolicy` API

```rust
use duroxide::{RetryPolicy, BackoffStrategy};

// Simple: 3 attempts with default exponential backoff (100ms base, 2x multiplier, 30s max)
let result = ctx.schedule_activity_with_retry("Task", input, RetryPolicy::new(3)).await?;

// Custom: 5 attempts, fixed 1s backoff, 30s per-attempt timeout
let policy = RetryPolicy::new(5)
    .with_timeout(Duration::from_secs(30))
    .with_backoff(BackoffStrategy::Fixed { delay: Duration::from_secs(1) });
let result = ctx.schedule_activity_with_retry("Task", input, policy).await?;
```

**`RetryPolicy` fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_attempts` | `u32` | 3 | Total attempts including initial (must be ≥ 1) |
| `backoff` | `BackoffStrategy` | Exponential(100ms, 2.0, 30s) | Delay between retry attempts |
| `timeout` | `Option<Duration>` | None | Per-attempt timeout; timeouts exit immediately (no retry) |

**`BackoffStrategy` variants:**

| Variant | Formula | Description |
|---------|---------|-------------|
| `None` | 0 | No delay between retries |
| `Fixed { delay }` | constant | Same delay every retry |
| `Linear { base, max }` | `base × attempt` | Linearly increasing, capped at max |
| `Exponential { base, multiplier, max }` | `base × multiplier^(attempt-1)` | Exponential growth, capped at max |

**Key semantics:**
- Activity *errors* trigger retries (with backoff delay between attempts)
- *Timeouts* exit immediately — they are NOT retried
- Fully deterministic: each retry creates a new `ActivityScheduled` event in the history, replays correctly
- No worker/provider changes needed — retries are orchestration-level control flow

**References:**
- [duroxide RetryPolicy API](https://github.com/microsoft/duroxide/blob/main/src/lib.rs#L1312-L1398)
- [schedule_activity_with_retry implementation](https://github.com/microsoft/duroxide/blob/main/src/lib.rs#L2805-L2855)
- [Activity Retry Policy proposal (IMPLEMENTED)](https://github.com/microsoft/duroxide/blob/main/docs/proposals-impl/activity-retry-policy.md)
- [Orchestration Guide — Retry with Backoff](https://github.com/microsoft/duroxide/blob/main/docs/ORCHESTRATION-GUIDE.md#L1356-L1425)
- [Retry tests](https://github.com/microsoft/duroxide/blob/main/tests/schedule_with_retry_tests.rs)

---

## Design

Two separate mechanisms:

1. **Node retries** — retry individual activity calls (SQL, HTTP) on transient failure
2. **Loop resilience** — a failed iteration doesn't kill the loop; the loop absorbs the error and continues

These are complementary. A SQL node inside a loop body might retry 3 times (node retry), and if it still fails, the loop absorbs that failure and moves to the next iteration (loop resilience).

---

## 1. Node Retries

### What changes

Replace `ctx.schedule_activity(NAME, input)` with `ctx.schedule_activity_with_retry(NAME, input, policy)` for SQL and HTTP nodes in `src/orchestrations/execute_function_graph.rs`.

### Which nodes get retries

| Node type | Retryable? | Rationale |
|-----------|------------|-----------|
| SQL | Yes | Connection drops, transient DB errors |
| HTTP | Yes | Network timeouts, 5xx errors |
| SLEEP | No | Deterministic timer, no I/O |
| SIGNAL | No | Deterministic wait, no I/O |
| LOOP, IF, THEN, JOIN, RACE, BREAK | No | Control flow — not activities |
| `update-node-status` | Yes | Status writes should be best-effort resilient |
| `update-instance-status` | Yes | Same |
| `load-function-graph` | No | Already has its own polling/retry for transaction visibility |

### Default retry policy

```
max_attempts: 3
backoff: Exponential { base: 100ms, multiplier: 2.0, max: 30s }
timeout: None
```

This is duroxide's `RetryPolicy::default()`. Suitable for most transient failures (connection drops, brief outages). Three attempts with 100ms → 200ms → 400ms delays.

### Code change (SQL node)

```rust
// Before:
let result = ctx
    .schedule_activity(activities::execute_sql::NAME, input.to_string())
    .await?;

// After:
let result = ctx
    .schedule_activity_with_retry(
        activities::execute_sql::NAME,
        input.to_string(),
        retry_policy.clone(),
    )
    .await?;
```

Where `retry_policy` is constructed from the configured setting (see Configuration section).

### Code change (HTTP node)

Same pattern — replace `schedule_activity` with `schedule_activity_with_retry` at the HTTP call site.

### Code change (status updates)

Status updates (`update-node-status`, `update-instance-status`) already use `let _ =` to ignore errors. Adding retry makes them more reliably delivered without changing error semantics:

```rust
let _ = ctx
    .schedule_activity_with_retry(
        activities::update_node_status::NAME,
        input.to_string(),
        RetryPolicy::new(3).with_backoff(BackoffStrategy::Fixed {
            delay: Duration::from_secs(1),
        }),
    )
    .await;
```

---

## 2. Loop Resilience

### Problem

A loop's purpose is long-running, repeated execution: heartbeats, polling, periodic sync. A single iteration failure should not be fatal. Today, `execute_loop_node` does:

```rust
let body_result = Box::pin(execute_function_node_with_vars(...)).await?;
//                                                                  ^ error kills the loop
```

### Design: loops absorb iteration failures

When a loop body fails (after exhausting its own node retries), the loop catches the error, logs it, and continues to the next iteration via `continue_as_new`. The failed iteration is recorded but does not propagate.

```rust
// Proposed change in execute_loop_node:
let body_result = Box::pin(execute_function_node_with_vars(
    ctx, graph, body_id, results, exec_ctx,
)).await;

match body_result {
    Ok(result) => {
        if is_break_signal(&result) {
            return Ok(extract_break_value(&result));
        }
        // Success — check condition and continue
    }
    Err(err) => {
        ctx.trace_warn(format!("Loop iteration failed: {err}"));
        // Record failure but continue to next iteration
    }
}
```

The loop always continues (subject to its while-condition) regardless of whether the body succeeded or failed. Note: if the while-condition itself fails, that *does* fail the loop — the condition must be evaluable for the loop to make a continue/exit decision.

### This is not configurable

Loop resilience is always on. A loop that should fail on error can use `df.seq` outside the loop or use `df.if` inside the body to handle errors explicitly. The mental model: **a loop is a long-running supervisor** — it keeps going.

### Loop iteration metrics

Since failed iterations are absorbed, visibility is critical. The orchestration should track and log iteration outcomes. Proposed approach:

**Trace logging per iteration:**
```
Loop iteration 1: completed (result: ...)
Loop iteration 2: failed (error: SQL execution failed: connection terminated)
Loop iteration 3: completed (result: ...)
```

**Rolling window in orchestration state (passed via `continue_as_new`):**

Track iteration outcomes in the `FunctionInput` state passed across `continue_as_new` boundaries:

```rust
struct LoopMetrics {
    total_iterations: u64,
    total_successes: u64,
    total_failures: u64,
    // Last N iteration outcomes (ring buffer, carried across continue_as_new)
    recent_outcomes: Vec<IterationOutcome>,  // last 5
}

struct IterationOutcome {
    iteration: u64,
    succeeded: bool,
    error: Option<String>,  // truncated to ~200 chars
}
```

This state is:
- Logged as a trace at each iteration (visible in `~/.pgrx/17.log` / worker logs)
- Passed through `continue_as_new` so it survives history truncation
- Available for future monitoring queries (e.g., `df.loop_status(instance_id)`)

**Example trace output:**
```
Loop iteration 47: failed (error: connection terminated)
Loop stats: 47 iterations, 45 successes, 2 failures
Recent: [ok, ok, FAIL, ok, ok]
```

### Consecutive failure limit

To prevent a loop from spinning forever on a permanently broken query, add a **consecutive failure limit**. If N consecutive iterations fail (default: 10), the loop fails. This protects against:
- Permanently dropped table
- Revoked permissions
- Invalid SQL that will never succeed

This is a safety mechanism, not user-configurable in v1. The value 10 is chosen to tolerate bursts of transient failures while catching permanent ones.

---

## 3. Configuration

### Option A: GUC (global setting) — **Recommended for v1**

Add a single GUC that controls the default retry count for all activity nodes:

```
pg_durable.max_retries = 3  (default)
```

**Pros:**
- Simple to implement — one place to read the setting
- Consistent behavior across all functions
- DBA can tune for the environment (set to 1 for fail-fast testing, 5 for flaky networks)
- No DSL changes needed

**Implementation:**

```rust
pub static MAX_RETRIES: GucSetting<i32> = GucSetting::<i32>::new(3);

// In _PG_init():
GucRegistry::define_int_guc(
    c"pg_durable.max_retries",
    c"Maximum retry attempts for SQL and HTTP activities (default 3)",
    c"",
    &MAX_RETRIES,
    1,    // min
    100,  // max
    GucContext::Sighup,  // reloadable without restart
    GucFlags::default(),
);
```

The orchestration reads this value when constructing the retry policy. Since `GucContext::Sighup`, changes take effect on `pg_ctl reload` without restart.

The backoff strategy is hardcoded to `Exponential { base: 100ms, multiplier: 2.0, max: 30s }` — suitable for most workloads and not worth exposing as a GUC in v1.

### Option B: Per-function configuration (future)

Allow users to set retry policy per `df.start()` call:

```sql
SELECT df.start(
    df.sql('SELECT process_batch()'),
    'batch-job',
    retries => 5
);
```

Or per node:

```sql
df.sql('SELECT flaky_query()', retries => 10)
```

This requires:
- Adding a `retries` parameter to DSL functions
- Storing it in `df.nodes`
- Reading it in the orchestration per-node

**Recommendation:** Defer to a future version. The GUC provides adequate control for v1, and per-node configuration adds complexity to the DSL, node schema, and orchestration.

### Option C: Per-function via `df.start()` parameter (reasonable v1.1)

A middle ground between A and B — set retry policy per durable function invocation:

```sql
SELECT df.start(
    df.sql('SELECT 1') ~> df.sql('SELECT 2'),
    'my-function',
    max_retries => 5
);
```

This is passed through `FunctionInput.vars` (or a dedicated field) and read by the orchestration. All nodes in that function share the same retry policy. This avoids both the rigidity of a global GUC and the complexity of per-node configuration.

---

## Implementation Plan

### Phase 1: Node retries via GUC

1. Add `pg_durable.max_retries` GUC
2. In `execute_sql_node` and `execute_http_node`, replace `schedule_activity` with `schedule_activity_with_retry` using the GUC value
3. Add retry to `update_node_status` and `update_instance_status` calls (hardcoded 3 attempts, fixed 1s backoff)
4. Add E2E test: start function, kill backend mid-execution, verify function completes after retry

### Phase 2: Loop resilience

1. Change `execute_loop_node` to catch body errors instead of propagating
2. Add `LoopMetrics` struct, carry through `continue_as_new`
3. Add consecutive failure limit (10)
4. Add trace logging for iteration outcomes
5. Add E2E test: loop with intermittent failures, verify loop continues and metrics are logged

### Phase 3: Per-function retries (future)

1. Add `max_retries` parameter to `df.start()`
2. Carry through `FunctionInput`
3. Orchestration reads per-function setting, falls back to GUC

---

## E2E Test Sketches

### Test: Node retry on backend termination

```sql
-- Start a function with a long-running SQL
SELECT df.start(
    df.sql('SELECT pg_sleep(120)'),
    'retry-test'
) AS instance_id;

-- Find and kill the backend
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE query = 'SELECT pg_sleep(120)' AND pid != pg_backend_pid();

-- With retries enabled, the function should retry the SQL node
-- and eventually complete (the retry will start a new pg_sleep)
-- For testing, use a shorter sleep or a query that succeeds on retry
```

### Test: Loop resilience

```sql
-- Set up a table that causes failure on specific iterations
CREATE TABLE loop_test (iteration int, ts timestamptz DEFAULT now());

-- Create a function referenced by the SQL:
-- Fails on every 3rd call by dividing by zero
CREATE OR REPLACE FUNCTION flaky_insert(iter int) RETURNS void AS $$
BEGIN
    IF iter % 3 = 0 THEN
        RAISE EXCEPTION 'simulated failure on iteration %', iter;
    END IF;
    INSERT INTO loop_test VALUES (iter);
END;
$$ LANGUAGE plpgsql;

-- Loop that calls the flaky function
SELECT df.start(
    df.loop(
        df.sql('SELECT flaky_insert(nextval(''loop_counter''))'),
        'SELECT currval(''loop_counter'') < 10'
    ),
    'loop-resilience-test'
);

-- After completion: loop_test should have ~7 rows (iterations 1,2,4,5,7,8,10)
-- Iterations 3, 6, 9 failed but the loop continued
```

---

## Open Questions

1. **Should retries apply to the while-condition of a loop?** Proposed: no — if the condition fails, the loop fails. The condition should be a simple, reliable query. A flaky condition makes the loop's behavior unpredictable.

2. **Should `update_node_status` retries block the orchestration?** Today, status updates use `let _ =` (fire-and-forget for errors). With retry, a status update could block for seconds during backoff. Proposed: keep fire-and-forget semantics but use `schedule_activity_with_retry` — duroxide will retry in the background without blocking the orchestration's critical path. (Need to verify this is how duroxide handles it — TBD.)

3. **Should we expose retry metrics via SQL?** E.g., `df.node_retries(instance_id)` showing how many retries each node needed. This is naturally available in duroxide's history (multiple `ActivityScheduled` events for the same logical activity). Proposed: defer to Phase 3.

4. **Per-attempt timeout:** The GUC controls `max_attempts` only. Should we also expose a per-attempt timeout GUC (`pg_durable.activity_timeout`)? For SQL nodes, PostgreSQL's `statement_timeout` already provides this. For HTTP nodes, `timeout_seconds` is already in the `df.http()` DSL. Proposed: no additional GUC needed in v1.
