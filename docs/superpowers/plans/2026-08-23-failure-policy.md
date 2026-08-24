# Node Failure Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retry failing `df.sql()` / `df.http()` / `df.http_multipart()` nodes with
exponential backoff, and let an exhausted node either continue the enclosing loop's next
iteration or fail the instance, configured per instance on `df.start()`.

**Architecture:** Three new defaulted `df.start()` arguments become a `RetryPolicySpec`
carried in `FunctionInput` → `ExecutionContext` → `SubtreeInput`, so every generation and
every sub-orchestration inherits it from recorded history rather than from a GUC. The three
activity call sites switch to `ctx.schedule_activity_with_retry()`; exhaustion under
`'continue'` raises a new `NodeError::Continue`, which unwinds through compound nodes exactly
like `NodeError::Break` and is caught by the nearest enclosing loop.

**Tech Stack:** Rust, pgrx 0.16.1, duroxide 0.1.30 (`RetryPolicy` / `BackoffStrategy`),
PostgreSQL 17, SQL E2E tests.

**Spec:** `docs/superpowers/specs/2026-08-19-failure-policy-design.md`

## Global Constraints

- Target version `0.2.7`; `Cargo.toml` bumps from `0.2.6`, upgrade script is
  `sql/pg_durable--0.2.6--0.2.7.sql`.
- `src/orchestrations/execute_function_graph.rs` is deterministic-only: no I/O, no wall
  clock, no unordered-map iteration affecting durable operations.
- New serialized fields are `#[serde(default)]` and default to `'fail'` with
  `max_attempts = 1` so pre-0.2.7 histories replay unchanged.
- Defaults for new instances: `max_attempts => 5`, `max_backoff => '16s'`,
  `on_failure => 'continue'`.
- `cargo fmt -p pg_durable -- --check` and `cargo clippy --features pg17` must stay clean.
- No `Co-authored-by` / Copilot trailers in commits.

---

### Task 1: `RetryPolicySpec` in `src/types.rs`

**Files:**
- Modify: `src/types.rs` (next to `FunctionInput`, ~line 1273)
- Test: `src/types.rs` / `src/lib.rs` unit tests — pure serde, no PostgreSQL needed

**Interfaces:**
- Produces: `pub enum OnFailure { Continue, Fail }` (serde `rename_all = "lowercase"`);
  `pub struct RetryPolicySpec { pub max_attempts: u32, pub max_backoff_micros: i64, pub on_failure: OnFailure }`;
  `RetryPolicySpec::legacy()` (1 attempt, 16s, `Fail`) as the serde default;
  `RetryPolicySpec::default_for_start()` (5, 16s, `Continue`);
  `RetryPolicySpec::max_backoff(&self) -> Duration`;
  `FunctionInput::retry: RetryPolicySpec` with `#[serde(default = "RetryPolicySpec::legacy")]`.

- [ ] **Step 1: Write failing unit tests**

```rust
#[test]
fn function_input_without_retry_defaults_to_legacy() {
    let json = r#"{"instance_id":"abc","vars":{},"loop_iteration":0}"#;
    let input: FunctionInput = serde_json::from_str(json).unwrap();
    assert_eq!(input.retry.max_attempts, 1);
    assert_eq!(input.retry.on_failure, OnFailure::Fail);
}

#[test]
fn retry_policy_spec_round_trips_through_function_input() {
    let input = FunctionInput {
        instance_id: "abc".into(),
        label: None,
        vars: Default::default(),
        loop_iteration: 0,
        graph: None,
        retry: RetryPolicySpec {
            max_attempts: 5,
            max_backoff_micros: 16_000_000,
            on_failure: OnFailure::Continue,
        },
    };
    let json = serde_json::to_string(&input).unwrap();
    let back: FunctionInput = serde_json::from_str(&json).unwrap();
    assert_eq!(back.retry, input.retry);
}

#[test]
fn max_backoff_converts_micros_to_duration() {
    let spec = RetryPolicySpec {
        max_attempts: 5,
        max_backoff_micros: 16_000_000,
        on_failure: OnFailure::Fail,
    };
    assert_eq!(spec.max_backoff(), std::time::Duration::from_secs(16));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: compile error — `RetryPolicySpec` not found.

- [ ] **Step 3: Implement `OnFailure`, `RetryPolicySpec`, and the `FunctionInput` field**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OnFailure {
    Continue,
    Fail,
}

/// Per-instance retry + failure policy, recorded in orchestration input.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RetryPolicySpec {
    pub max_attempts: u32,
    pub max_backoff_micros: i64,
    pub on_failure: OnFailure,
}

impl RetryPolicySpec {
    /// Behavior of instances started before this feature existed: one try, then fail.
    pub fn legacy() -> Self {
        Self { max_attempts: 1, max_backoff_micros: 16_000_000, on_failure: OnFailure::Fail }
    }

    pub fn default_for_start() -> Self {
        Self { max_attempts: 5, max_backoff_micros: 16_000_000, on_failure: OnFailure::Continue }
    }

    pub fn max_backoff(&self) -> std::time::Duration {
        std::time::Duration::from_micros(self.max_backoff_micros.max(0) as u64)
    }
}
```

Add to `FunctionInput`:

```rust
    #[serde(default = "RetryPolicySpec::legacy")]
    pub retry: RetryPolicySpec,
```

and update the `loop_iteration` doc comment (it currently claims the field enforces a
maximum-iteration safeguard, which Task 5 removes) to say it is carried across
`continue_as_new` for tracing only.

- [ ] **Step 4: Run tests, expect PASS**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add src/types.rs src/lib.rs && git commit -m "Add RetryPolicySpec to orchestration input"
```

---

### Task 2: `df.start()` gains the three arguments

**Files:**
- Modify: `src/dsl.rs` (`start_v2` ~967, `start_in_caller_transaction`, `start_in_new_transaction`, `FunctionInput` construction ~1275)
- Modify: `src/client.rs` (`start_in_new_transaction` ~331, `start_on_new_session` ~264)
- Test: `src/lib.rs` `#[pg_test]` module

**Interfaces:**
- Consumes: `RetryPolicySpec`, `OnFailure` from Task 1.
- Produces: `df.start(fut, label, database, transaction_mode, max_attempts, max_backoff, on_failure)`
  backed by `start_v3_wrapper`;
  `dsl::parse_retry_policy(max_attempts: i32, max_backoff: Interval, on_failure: &str) -> Result<RetryPolicySpec, String>`.

- [ ] **Step 1: Write failing `#[pg_test]`s** in `src/lib.rs`

```rust
#[pg_test]
fn test_start_rejects_zero_max_attempts() {
    let err = Spi::get_one::<String>(
        "SELECT df.start('SELECT 1', 'x', NULL, 'caller', 0, '16s'::interval, 'continue')",
    );
    assert!(err.is_err(), "max_attempts = 0 must be rejected");
}

#[pg_test]
fn test_start_rejects_non_positive_max_backoff() {
    let err = Spi::get_one::<String>(
        "SELECT df.start('SELECT 1', 'x', NULL, 'caller', 3, '0s'::interval, 'continue')",
    );
    assert!(err.is_err(), "non-positive max_backoff must be rejected");
}

#[pg_test]
fn test_start_rejects_unknown_on_failure() {
    let err = Spi::get_one::<String>(
        "SELECT df.start('SELECT 1', 'x', NULL, 'caller', 3, '16s'::interval, 'explode')",
    );
    assert!(err.is_err(), "unknown on_failure must be rejected");
}
```

(If a `pgrx::error!` aborts the test transaction rather than returning `Err`, wrap each
statement in `Spi::connect` + subtransaction, or assert with
`PgTryBuilder::new(...).catch_others(...)`, whichever the surrounding tests already use.)

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `df.start` has no seven-argument form.

- [ ] **Step 3: Implement**

```rust
#[pg_extern(name = "start", schema = "df")]
#[allow(clippy::too_many_arguments)]
pub fn start_v3(
    fut: &str,
    label: default!(Option<&str>, "NULL"),
    database: default!(Option<&str>, "NULL"),
    transaction_mode: default!(&str, "'caller'"),
    max_attempts: default!(i32, "5"),
    max_backoff: default!(pgrx::datum::Interval, "'16 seconds'"),
    on_failure: default!(&str, "'continue'"),
) -> String {
    let retry = match parse_retry_policy(max_attempts, max_backoff, on_failure) {
        Ok(spec) => spec,
        Err(e) => pgrx::error!("{e}"),
    };
    start_dispatch(fut, label, database, transaction_mode, retry)
}
```

`parse_retry_policy` validates `max_attempts >= 1`, `max_backoff.as_micros() > 0` and fits
`i64`, and `on_failure` ∈ {`continue`, `fail`} case-insensitively, each with a message
naming the offending argument.

Demote the old entry point, following the `start()` precedent directly above it:

```rust
/// Legacy four-argument `df.start()`, retained for binary compatibility only.
#[pg_extern(sql = false)]
pub fn start_v2(
    fut: &str,
    label: Option<&str>,
    database: Option<&str>,
    transaction_mode: &str,
) -> String {
    start_dispatch(fut, label, database, transaction_mode, RetryPolicySpec::legacy())
}
```

`start_dispatch` holds what `start_v2` used to do (mode validation plus branch), threading
`retry` into `start_in_caller_transaction`, which puts it in `FunctionInput`.

For `transaction_mode => 'new'`, thread `Option<RetryPolicySpec>`: `start_v2` passes `None`
so the loopback keeps issuing today's three-positional `df.start($1,$2,$3)` (still resolving
on pre-0.2.5 schemas), and `start_v3` passes `Some(spec)` so the loopback issues
`SELECT df.start($1,$2,$3,'caller',$4,$5::interval,$6)` with the policy bound as an `i32`,
a `'<n> microseconds'` string cast to interval, and the `on_failure` text.

- [ ] **Step 4: Run tests, expect PASS**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

- [ ] **Step 5: Commit**

```bash
git add src/dsl.rs src/client.rs src/lib.rs
git commit -m "Add max_attempts, max_backoff, and on_failure to df.start()"
```

---

### Task 3: Thread the policy through the orchestration

**Files:**
- Modify: `src/orchestrations/execute_function_graph.rs` (`ExecutionContext` ~33, `SubtreeInput` ~71, `execute` ~240, `execute_subtree` ~365, `build_subtree_input` ~420, `execute_loop_node` continue_as_new ~985)
- Test: same file's `#[cfg(test)] mod tests`

**Interfaces:**
- Consumes: `RetryPolicySpec` (Task 1), `FunctionInput::retry` (Task 1).
- Produces: `ExecutionContext.retry: RetryPolicySpec`; `SubtreeInput.retry` with
  `#[serde(default = "RetryPolicySpec::legacy")]`.

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn subtree_input_without_retry_defaults_to_legacy() {
    let json = r#"{"instance_id":"i","node_id":"n","graph":"{}","results":"{}"}"#;
    let input: SubtreeInput = serde_json::from_str(json).unwrap();
    assert_eq!(input.retry.max_attempts, 1);
    assert_eq!(input.retry.on_failure, crate::types::OnFailure::Fail);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — no `retry` field on `SubtreeInput`.

- [ ] **Step 3: Implement the threading**

Add `retry: RetryPolicySpec` to `SubtreeInput` (with the serde default) and to
`ExecutionContext`; populate it from `input.retry` in both `execute` and `execute_subtree`;
copy `exec_ctx.retry` in `build_subtree_input`; carry it in both `continue_as_new` arms of
`execute_loop_node`.

- [ ] **Step 4: Run tests, expect PASS**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add src/orchestrations/execute_function_graph.rs
git commit -m "Thread the retry policy through subtree and loop generations"
```

---

### Task 4: Retry the activities and add `NodeError::Continue`

**Files:**
- Modify: `src/orchestrations/execute_function_graph.rs` (`NodeError` ~97, `SubtreeControl` ~132, `execute_sql_node` ~605, `execute_http_node` ~1572, `execute_http_multipart_node` ~1671, and the six explicit `match` sites)

**Interfaces:**
- Consumes: `ExecutionContext.retry` (Task 3).
- Produces: `NodeError::Continue(String)`; `SubtreeControl::Continue`;
  `build_retry_policy(&RetryPolicySpec) -> duroxide::RetryPolicy`;
  `schedule_node_activity(ctx, name, input, exec_ctx) -> NodeResult`, the single helper all
  three node types call.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn retry_policy_backoff_sequence_is_1_2_4_8_capped() {
    let spec = crate::types::RetryPolicySpec {
        max_attempts: 5,
        max_backoff_micros: 16_000_000,
        on_failure: crate::types::OnFailure::Continue,
    };
    let policy = build_retry_policy(&spec);
    assert_eq!(policy.max_attempts, 5);
    let delays: Vec<u64> = (1..=6)
        .map(|n| policy.backoff.delay_for_attempt(n).as_secs())
        .collect();
    assert_eq!(delays, vec![1, 2, 4, 8, 16, 16]);
}

#[test]
fn continue_error_is_distinct_from_break_and_failure() {
    let e = NodeError::Continue("boom".into());
    assert!(matches!(e, NodeError::Continue(ref m) if m == "boom"));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `build_retry_policy` and `NodeError::Continue` do not exist.

- [ ] **Step 3: Implement**

```rust
fn build_retry_policy(spec: &crate::types::RetryPolicySpec) -> duroxide::RetryPolicy {
    duroxide::RetryPolicy {
        max_attempts: spec.max_attempts.max(1),
        backoff: duroxide::BackoffStrategy::Exponential {
            base: Duration::from_secs(1),
            multiplier: 2.0,
            max: spec.max_backoff(),
        },
        timeout: None,
    }
}

async fn schedule_node_activity(
    ctx: &OrchestrationContext,
    name: &str,
    input: String,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    match ctx
        .schedule_activity_with_retry(name, input, build_retry_policy(&exec_ctx.retry))
        .await
    {
        Ok(result) => Ok(result),
        Err(e) => match exec_ctx.retry.on_failure {
            crate::types::OnFailure::Continue => Err(NodeError::Continue(e)),
            crate::types::OnFailure::Fail => Err(NodeError::Failure(e)),
        },
    }
}
```

Point the three node handlers at it, add the `NodeError::Continue` and
`SubtreeControl::Continue` variants, and extend the six match sites:

| Site | New arm |
|---|---|
| `run_loop_iteration` body | `Err(NodeError::Continue(e))` → trace a warning, return `Ok(None)` so the loop starts the next iteration |
| `run_loop_iteration` condition | same |
| `execute_function_node_with_vars` status | `("failed", e.as_str())` |
| `execute_subtree` envelope | `control: Some(SubtreeControl::Continue)`, `result: e` |
| `parse_subtree_envelope` | `Some(SubtreeControl::Continue) => Err(NodeError::Continue(...))` |
| `execute` top level | `Err(NodeError::Continue(e)) => Err(e)` — no loop to unwind to, so the instance fails with the node's error |

`run_loop_iteration` returns `Result<Option<String>, String>` today, which cannot express
"continue"; change it to `Result<Option<String>, NodeError>` and let `execute_loop_node` map
the arms.

- [ ] **Step 4: Run tests, expect PASS**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add src/orchestrations/execute_function_graph.rs
git commit -m "Retry node activities and unwind exhausted nodes to the enclosing loop"
```

---

### Task 5: Remove the iteration cap

**Files:**
- Modify: `src/orchestrations/execute_function_graph.rs` (`MAX_LOOP_ITERATIONS` ~753, check ~949)

- [ ] **Step 1: Delete the constant and the `next_iteration >= MAX_LOOP_ITERATIONS` block.**

- [ ] **Step 2: Verify nothing else refers to it**

Run: `grep -rn "MAX_LOOP_ITERATIONS" src/ tests/ docs/ | grep -v superpowers`
Expected: no output.

- [ ] **Step 3: Build clean**

Run: `cargo clippy --features pg17 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add src/orchestrations/execute_function_graph.rs
git commit -m "Remove the 100,000-iteration loop cap"
```

---

### Task 6: Upgrade script, version bump, and upgrade docs

**Files:**
- Modify: `Cargo.toml` (`version = "0.2.7"`)
- Create: `sql/pg_durable--0.2.6--0.2.7.sql`
- Modify: `docs/upgrade-testing.md` ("v0.2.6 → v0.2.7" section)

- [ ] **Step 1: Bump `Cargo.toml` to `0.2.7`.**

- [ ] **Step 2: Generate the fresh-install DDL for `df.start`**

Run: `cargo pgrx schema pg17 2>/dev/null | grep -B 2 -A 12 'start_v3_wrapper'`
Copy the emitted `CREATE FUNCTION` verbatim.

- [ ] **Step 3: Write `sql/pg_durable--0.2.6--0.2.7.sql`**

A header comment explaining why the four-argument form is dropped (ambiguous overload),
then `DROP FUNCTION IF EXISTS df.start(text, text, text, text);` followed by the copied
`CREATE FUNCTION df."start"(...)` bound to `start_v3_wrapper`. Keep the DDL
schema-qualified for the pgspot gate.

- [ ] **Step 4: Run the upgrade tests**

Run: `./scripts/test-upgrade.sh --verbose 2>&1 | tail -30`
Expected: Scenario A schema diff empty; B1 passes.

- [ ] **Step 5: Document in `docs/upgrade-testing.md`** under "Version-Specific Changes":
      the DDL change, the B1 story, and the behavior change for callers who keep calling the
      four-argument form.

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml Cargo.lock sql/pg_durable--0.2.6--0.2.7.sql docs/upgrade-testing.md
git commit -m "Add the 0.2.6 to 0.2.7 upgrade script for the new df.start() signature"
```

---

### Task 7: E2E coverage

**Files:**
- Create: `tests/e2e/sql/67_failure_policy.sql`

- [ ] **Step 1: Write the test** following the repository template (temp state table, poll
      `df.status()`, raise on mismatch, `SELECT 'TEST PASSED'`). Each case pins
      `max_attempts` and a short `max_backoff` so the file stays inside the polling budget:
  1. Transient recovery: a counter-backed function that raises on its first two calls;
     assert the instance completes and the counter reads 3.
  2. Continue: a loop whose body always fails; assert the instance is still `running`, that
     `df.instance_nodes()` shows failed nodes, and that the body ran more than once.
  3. No enclosing loop under `'continue'`: assert the instance ends `failed`.
  4. `on_failure => 'fail', max_attempts => 1`: assert exactly one attempt and `failed`.
  5. Graph error under `'continue'`: an unknown node type fails immediately.

- [ ] **Step 2: Run it**

Run: `./scripts/test-e2e-local.sh 67_failure_policy --verbose 2>&1 | tail -40`
Expected: `TEST PASSED`.

- [ ] **Step 3: Run the whole suite for regressions**

Run: `./scripts/test-e2e-local.sh 2>&1 | tail -20`

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/sql/67_failure_policy.sql
git commit -m "Add E2E coverage for the node failure policy"
```

---

### Task 8: User-facing documentation

**Files:**
- Modify: `USER_GUIDE.md` (`df.start` section ~163 and the API table ~260)
- Modify: `CHANGELOG.md` (new `## [0.2.7] - Unreleased` section)

- [ ] **Step 1: Document the three arguments,** the defaults, the loop-continue semantics,
      and the monitoring consequence (a healthy instance status no longer means a healthy
      workflow — watch for failed nodes under running instances).

- [ ] **Step 2: Add the changelog entry,** including the behavior change for existing
      four-argument callers and the `on_failure => 'fail', max_attempts => 1` escape hatch.

- [ ] **Step 3: Commit**

```bash
git add USER_GUIDE.md CHANGELOG.md
git commit -m "Document the node failure policy"
```

---

### Task 9: Open the draft PR

- [ ] **Step 1: Final gate**

Run: `cargo fmt -p pg_durable -- --check && cargo clippy --features pg17 2>&1 | tail -5 && ./scripts/test-unit.sh 2>&1 | tail -5 && ./scripts/test-e2e-local.sh 2>&1 | tail -5`

- [ ] **Step 2: Push the branch and open a draft PR** summarizing the API, the default
      behavior change, the removed iteration cap, and the upgrade story.
