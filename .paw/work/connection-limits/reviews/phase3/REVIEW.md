# Phase 3 Review — User-Execution Backpressure

**Reviewer**: impl-review (local)  
**Diff**: `8dd480f..adec7f5`  
**Verdict**: **PASS**

---

## Checklist

| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| 1 | Semaphore correctly sized from GUC | ✅ | `Semaphore::new(get_max_user_connections() as usize)` — GUC min=1, max=1000, `i32→usize` cast is safe |
| 2 | Timeout handling — `Err(_)` (elapsed) | ✅ | Returns descriptive error with limit and timeout values |
| 3 | Timeout handling — `Ok(Err(_))` (closed semaphore) | ✅ | Returns distinct error ("Semaphore closed unexpectedly") |
| 4 | Permit held for correct duration | ✅ | `_permit` lives until end of `execute()`, covers `connect_as_user` + `fetch_all` |
| 5 | Permit released on all paths (success, SQL error) | ✅ | `_permit` is dropped on both `Ok` and `Err` return from the `match` at line 79 |
| 6 | Registry wiring correct | ✅ | `semaphore` passed through `create_activity_registry` → cloned into `execute_sql` closure |
| 7 | Other activities unchanged | ✅ | `load_function_graph`, `update_instance_status`, `update_node_status`, `execute_http` still use pool/no-pool as before |
| 8 | Error message matches plan format | ✅ | Timeout path: `"pg_durable: connection limit reached (max_user_connections={limit}). Timed out after {timeout}s …"` — matches ImplementationPlan §Phase 3 |
| 9 | Spec alignment — FR-004 (semaphore gate) | ✅ | Semaphore gates `connect_as_user()` — concurrent user-execution connections bounded by `max_user_connections` |
| 10 | Spec alignment — FR-005 / FR-008 (timeout with error) | ✅ | `tokio::time::timeout` + GUC-driven duration; descriptive error on expiry |
| 11 | Spec alignment — FR-007 (backpressure queues) | ✅ | Async `semaphore.acquire()` yields to tokio runtime — no deadlock on single-threaded executor |
| 12 | No deadlock risk in current-thread runtime | ✅ | `tokio::sync::Semaphore::acquire` is async-aware; `tokio::time::timeout` is also cooperative — safe on `new_current_thread` |
| 13 | Semaphore created inside retry loop | ⚠️ | Observation only — see below |

## Observations

### 1. Semaphore recreated on each retry (minor, acceptable)

The semaphore is created inside the `initialize_duroxide_runtime` retry loop (worker.rs:470–472). If provider creation fails and the loop retries, a new semaphore is allocated each iteration. This is **harmless** — the old semaphore is dropped (no permits outstanding since no runtime was running), and the GUC value is immutable (Postmaster context). The cost is a trivial allocation. No action needed.

### 2. `timeout.as_secs()` truncates sub-second precision

The error message uses `timeout.as_secs()` (line 65). Since the GUC is an integer number of seconds, `Duration::from_secs(n)` always has zero sub-seconds, so `as_secs()` is lossless. Correct as-is.

### 3. `pool` parameter kept in registry signature

`create_activity_registry` still accepts `pool: Arc<PgPool>` for the other activities (graph loading, status updates). The `execute_sql` closure no longer captures the pool — clean separation. Good design.

## Summary

The implementation is clean, correct, and well-aligned with the spec and plan. The semaphore is properly sized, timeout handling covers both the elapsed and closed-semaphore cases, the permit lifetime spans the full SQL execution, and the error messages are descriptive and actionable. No issues found.
