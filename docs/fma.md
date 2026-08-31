# pg_durable Failure Mode Analysis

**Status**: Draft
**Created**: 2026-03-24

---

## 1. Overview

This document catalogs production failure modes for pg_durable, a PostgreSQL extension providing durable SQL function execution. pg_durable runs entirely inside the PostgreSQL server — a single background worker process orchestrates durable functions via [duroxide](https://github.com/anthropics/duroxide), while user sessions build function graphs through DSL operators.

**Scope**: Failures that affect a pg_durable deployment on a PostgreSQL-as-a-Service (PaaS) platform. Covers the background worker, activity execution, orchestration logic, client-side DSL, extension lifecycle, and operational concerns.

**Methodology**: Static analysis of `src/`, `sql/`, and `tests/` combined with architectural reasoning about the PostgreSQL process model and duroxide runtime behavior.

---

## 2. Severity Definitions

| Level | Definition |
|-------|-----------|
| **SEV-1** | All durable functions for all users are blocked or data loss is possible. Requires immediate operator intervention. |
| **SEV-2** | Subset of users or workloads affected, or degraded functionality system-wide. |
| **SEV-3** | Single-user or single-instance failure with no broader impact. Self-recoverable or cosmetic. |

---

## 3. Failure Modes

### FM-1: Background Worker Fails to Start

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-1 |
| **Component** | `src/worker.rs` — `duroxide_worker_main` |
| **Trigger** | Tokio runtime creation fails (fd exhaustion, OOM), `shared_preload_libraries` misconfigured, or PostgreSQL crashes the worker on startup. |
| **Impact** | No durable functions execute. `df.start()` succeeds (rows written to `df.instances`/`df.nodes`), but instances remain `pending` indefinitely. Users see workflows that never progress. |
| **Detection — existing** | PostgreSQL log: `"pg_durable: failed to create tokio runtime: {}"`. PostgreSQL's built-in `pg_stat_activity` shows no `pg_durable_worker` background worker. The `df._worker_epoch` table remains empty. |
| **Detection — gap** | **No health-check SQL function** (e.g., `df.worker_alive()`) exists for users or monitoring dashboards to query. The only detection is log-scraping or direct system catalog inspection. |
| **Programmatic mitigation** | PostgreSQL auto-restarts background workers after the configured `set_restart_time(Some(Duration::from_secs(5)))`. The worker registers with `BgWorkerStartTime::RecoveryFinished`, so it starts after crash recovery completes. |
| **Process mitigation** | PaaS alerting on `pg_stat_activity` background worker presence. Log-based alert on `"failed to create tokio runtime"`. |
| **User recommendation** | Check `SELECT * FROM df._worker_epoch` — a recent `last_seen_at` timestamp confirms the worker is alive. If the table is empty or `last_seen_at` is stale, contact your database administrator. |

---

### FM-2: Worker Cannot Connect to PostgreSQL

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-1 |
| **Component** | `src/worker.rs` — poll pool creation, store initialization |
| **Trigger** | The `pg_durable.worker_role` GUC names a role that doesn't exist, has been dropped, or whose password/auth has changed. The `pg_durable.database` GUC names a database that doesn't exist. Network-level issues on loopback (rare for local connections). |
| **Impact** | Worker enters infinite retry loop. Logs fill with `"failed to create polling pool (will retry in 5s): {}"` or `"failed to create PostgreSQL store (will retry): {}"`. No durable functions execute. |
| **Detection — existing** | PostgreSQL log messages every 1–5 seconds. `df._worker_epoch` table stays empty. |
| **Detection — gap** | **No retry counter or backoff telemetry**. An operator reading logs sees repeated errors but has no metric for "worker has been retrying for N minutes". No alerting hook. |
| **Programmatic mitigation** | Retry loops are infinite with fixed intervals (5s for poll pool, 1s for store). The worker checks `is_shutdown_requested()` between retries to allow clean shutdown. |
| **Process mitigation** | PaaS validation at provisioning time: ensure worker role exists, is a superuser, and can authenticate. Alert on repeated `"will retry"` log patterns. |
| **User recommendation** | If no workflows are executing, ask the database administrator to verify that the `pg_durable.worker_role` (`SHOW pg_durable.worker_role`) exists and has superuser privileges. |

---

### FM-3: Worker Role Is Not a Superuser

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-1 |
| **Component** | `src/lib.rs` — extension SQL validation, `src/worker.rs` — runtime operation |
| **Trigger** | The role named by `pg_durable.worker_role` exists but is not a superuser. |
| **Impact** | Worker connects successfully and starts the duroxide runtime, but RLS policies filter out all rows in `df.instances` and `df.nodes` for the worker's activities. `load_function_graph` finds no instance. `update_instance_status` and `update_node_status` update zero rows. All workflows stall at `pending` or `running` with no progress. This is a **silent failure** — no error is raised. |
| **Detection — existing** | Extension SQL emits `RAISE WARNING 'pg_durable: worker role "..." is NOT a superuser...'` at `CREATE EXTENSION` time. Activity traces show `"Instance {id} not found after 5s"` in duroxide logs. `df.metrics()` shows `running_instances` climbing while `completed_instances` stays flat. |
| **Detection — gap** | **The warning at extension creation is easily missed.** There is no recurring health check that validates the worker role's privilege level. The activity failure message doesn't distinguish "RLS filtered" from "genuinely missing instance". |
| **Programmatic mitigation** | The `CREATE EXTENSION` SQL includes a `DO $$` block that checks `rolsuper` for the worker role. However, it only emits a `WARNING`, not an `EXCEPTION`. |
| **Process mitigation** | PaaS should enforce that the worker role is superuser as part of the managed PostgreSQL setup. Consider promoting the warning to an error. |
| **User recommendation** | Users cannot fix this themselves; it's a platform configuration issue. Symptom: all workflows stuck at `pending`/`running`. |

> **Recommendation**: Promote the `RAISE WARNING` at extension creation to `RAISE EXCEPTION` so that `CREATE EXTENSION pg_durable` fails fast if the worker role isn't a superuser.

---

### FM-4: Extension Created in Wrong Database

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-2 |
| **Component** | `src/lib.rs` — database validation SQL |
| **Trigger** | User runs `CREATE EXTENSION pg_durable` in a database other than the one configured in `pg_durable.database`. |
| **Impact** | Extension tables exist in one database; the background worker connects to a different one. Workflows submitted in the wrong database are never picked up. |
| **Detection — existing** | Extension SQL includes a `DO $$` block that checks `current_database()` against `current_setting('pg_durable.database')` and raises `EXCEPTION` in production builds or `NOTICE` in test builds. |
| **Detection — gap** | In test builds (which may leak to staging), only a `NOTICE` is emitted, not an error. |
| **Programmatic mitigation** | The database check in `CREATE EXTENSION` prevents creation in the wrong database (in production builds). |
| **Process mitigation** | PaaS should create the extension as part of managed provisioning, targeting the correct database. |
| **User recommendation** | If you receive a database mismatch error, run `CREATE EXTENSION` in the database shown by `SHOW pg_durable.database`. |

---

### FM-5: Transaction Visibility Race (df.start → Worker Pickup)

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 |
| **Component** | `src/activities/load_function_graph.rs` |
| **Trigger** | `df.start()` inserts into `df.instances` and `df.nodes`, then calls `start_orchestration()` on the duroxide client. The duroxide runtime may schedule the orchestration's `load_function_graph` activity before the user's transaction commits. |
| **Impact** | The activity's SQL query against `df.instances` finds no row (transaction not yet visible). If the user's transaction takes longer than 5 seconds to commit, the activity fails with `"Instance {id} not found after 5s"`. The instance transitions to `failed`. |
| **Detection — existing** | Activity trace: `"Instance {id} not yet visible, waiting for transaction commit..."` followed by `"Instance {id} not found after 5s"`. |
| **Detection — gap** | **No metric** for how often the 5-second retry window is hit, or how close to the limit activities get. |
| **Programmatic mitigation** | `load_function_graph` retries with 100ms polling for up to 5 seconds (`MAX_WAIT_SECS`). This handles the common case where the commit is milliseconds away. |
| **Process mitigation** | Document that `df.start()` should be called near the end of a transaction, not inside a long-running transaction with many preceding statements. |
| **User recommendation** | Call `df.start()` as the last operation before `COMMIT`. If workflows fail immediately with "not found", your transaction may be too long. |

---

### FM-6: User SQL Execution Failure

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 |
| **Component** | `src/activities/execute_sql.rs` |
| **Trigger** | The SQL query in a `df.sql()` node contains a syntax error, references a non-existent table/column, or the `submitted_by` user lacks the required privileges. |
| **Impact** | The activity returns an error. The orchestration marks the node as `failed` and propagates the error. The instance transitions to `failed` with the SQL error message in the output. **This is expected behavior** — user SQL errors are surfaced correctly. |
| **Detection — existing** | Activity trace: `"SQL execution failed: {}"`. Node status in `df.nodes` set to `failed` with the error in the `result` column. Instance status in `df.instances` set to `failed`. `df.status()` returns `'failed'`. `df.result()` accessible for error diagnosis. |
| **Detection — gap** | None significant. Error reporting is good. |
| **Programmatic mitigation** | None needed — this is correct error propagation. |
| **User recommendation** | Check `SELECT * FROM df.instance_nodes('your-instance-id')` to see which node failed and the error message. Fix the SQL and re-submit. |

---

### FM-7: User SQL Connection/Authentication Failure

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-2 (if systemic) or SEV-3 (if isolated) |
| **Component** | `src/activities/execute_sql.rs` — `connect_as_user()` |
| **Trigger** | The `execute_sql` activity connects to PostgreSQL as the `login_role` and then `SET ROLE` to `submitted_by`. Connection may fail if: (a) PostgreSQL is at its `max_connections` limit, (b) the login role's password changed, (c) `pg_hba.conf` rejects the connection, (d) the role was dropped after `df.start()`. |
| **Impact** | Activity fails with `"Failed to connect as ..."`. Instance transitions to `failed`. If `max_connections` is exhausted, this affects all concurrent workflow executions — not just one user. |
| **Detection — existing** | Activity trace: `"Failed to connect..."` or `"SET ROLE ... failed: {}"`. |
| **Detection — gap** | **No connection pool metrics** for the per-user sqlx connections. No visibility into how many concurrent activity connections are open. No correlation between `max_connections` pressure and durable function failures. |
| **Programmatic mitigation** | Each SQL activity opens a fresh connection (no pooling for user connections, which is correct for `SET ROLE` isolation). Duroxide may retry the activity depending on its retry policy. |
| **Process mitigation** | PaaS should monitor `max_connections` utilization and alert when approaching capacity. Reserved connections for the worker role. |
| **User recommendation** | If workflows fail with connection errors, check if your database is at connection capacity. Reduce concurrent workflow count or increase `max_connections`. |

> **Recommendation**: Add connection-count telemetry or at minimum log the active connection count when a connection attempt fails.

---

### FM-8: HTTP Activity Failure (Network / Remote Server)

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 |
| **Component** | `src/activities/execute_http.rs` |
| **Trigger** | Target HTTP server returns 5xx, connection times out, DNS resolution fails, or the remote server is unreachable. |
| **Impact** | Activity fails with a descriptive error (`"HTTP timeout after {timeout}s"`, `"HTTP connection failed"`, `"HTTP request failed: status {code}"`). Instance transitions to `failed`. |
| **Detection — existing** | Activity traces: `"HTTP {method} completed: status={status}, ok={ok}, duration={duration}ms"`. SSRF blocks logged separately. |
| **Detection — gap** | **No automatic retry for transient HTTP errors.** A single 503 fails the entire workflow. **No histogram of HTTP latencies** or error-rate metric. |
| **Programmatic mitigation** | Timeout is user-configurable (`df.http()` `timeout_seconds` parameter, default 30s). Redirect following is disabled to prevent SSRF bypass. |
| **Process mitigation** | Document that users should wrap HTTP calls in retry logic using `df.loop()` with error handling if they need resilience against transient failures. |
| **User recommendation** | Set appropriate `timeout_seconds` for your endpoint. For resilience against transient failures, wrap HTTP nodes in a loop with a condition that checks for success. Consider using `df.http()` with explicit error handling. |

> **Recommendation**: Consider adding a built-in retry option to `df.http()` (e.g., `retries` parameter with exponential backoff) for transient HTTP errors (429, 502, 503, 504).

---

### FM-9: SSRF Attempt / Blocked Request

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 (security event, not a system failure) |
| **Component** | `src/ssrf.rs`, `src/activities/execute_http.rs` |
| **Trigger** | User-submitted URL targets a private IP range (10.x, 172.16.x, 192.168.x, 169.254.x, loopback), uses a non-HTTP(S) scheme, or DNS resolves to a blocked IP. |
| **Impact** | Activity fails with `"BLOCKED: ..."`. Workflow transitions to `failed`. This is correct defensive behavior. |
| **Detection — existing** | Activity traces include audit fields: `"HTTP BLOCKED (scheme\|ip) url={url} submitted_by={user} login_role={role}"`. These are logged at the duroxide activity trace level. |
| **Detection — gap** | **No dedicated security event stream** for SSRF blocks. Traces are mixed with normal activity logs. A PaaS security team would need to grep duroxide traces for `"BLOCKED"` — there's no structured security audit log or counter metric. **The `no-ssrf-protection` feature flag**, if accidentally enabled in a production build, disables all protection silently. |
| **Programmatic mitigation** | Three-layer defense: URL scheme validation, IP literal check, DNS resolution filtering via `SsrfSafeResolver`. Redirect following disabled. IPv4-mapped IPv6 addresses unwrapped and checked. |
| **Process mitigation** | PaaS build pipeline should verify `no-ssrf-protection` feature is not enabled. Security team should have alerts on `"HTTP BLOCKED"` patterns in logs. |
| **User recommendation** | If your HTTP request is blocked and the target is a legitimate external service, verify the URL resolves to a public IP address. Private IP ranges and cloud metadata endpoints are blocked by design. |

> **Recommendation**: Emit a structured security event (e.g., to a separate `df.security_events` table or a dedicated log channel) for all SSRF blocks, including the requesting user, URL, and block reason. Add a build-time assertion that `no-ssrf-protection` is never enabled alongside `pg17` (the production feature).

---

### FM-10: Orchestration Deadlock / Infinite Loop

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-2 |
| **Component** | `src/orchestrations/execute_function_graph.rs` |
| **Trigger** | A `df.loop()` with no condition and a body that never calls `df.break()`. Or a condition that always evaluates to true. The loop uses `continue_as_new` for each iteration, so duroxide creates a new execution per iteration. |
| **Impact** | The instance runs indefinitely, consuming duroxide execution history. Each iteration creates duroxide events/state. The loop doesn't block other instances (duroxide dispatches independently), but it accumulates storage in `duroxide.*` tables unboundedly. |
| **Detection — existing** | `df.metrics()` shows `running_instances` staying elevated. `df.instance_executions()` shows a growing execution count. Orchestration traces log `"Continuing as new for next loop iteration"` repeatedly. |
| **Detection — gap** | **No max-iteration limit.** **No max-execution-duration limit.** **No alerting threshold** for instances that have been running longer than N minutes/hours. No per-instance resource consumption metric. |
| **Programmatic mitigation** | `continue_as_new` prevents orchestration history from growing unboundedly within a single execution (each iteration is a fresh execution). Users can `df.cancel()` a runaway instance. |
| **Process mitigation** | PaaS should implement a TTL or max-duration policy for durable function instances. Alert on instances running longer than a configurable threshold. |
| **User recommendation** | Always include a termination condition in `df.loop()`. Monitor long-running instances with `df.list_instances('running')` and cancel with `df.cancel()` if needed. |

> **Recommendation**: Add a `max_iterations` parameter to `df.loop()` (default: unbounded, but warn in docs). Add a system-wide GUC `pg_durable.max_instance_duration_seconds` that auto-cancels instances exceeding the limit.

---

### FM-11: JOIN Branch Failure (Partial Failure in Parallel Execution)

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 |
| **Component** | `src/orchestrations/execute_function_graph.rs` — JOIN handling |
| **Trigger** | One branch of a `df.join()` (parallel execution) fails while others succeed. |
| **Impact** | The entire JOIN fails. **All branch results are discarded**, including successful ones. The instance transitions to `failed`. This is the correct semantic (all-or-nothing parallel execution), but may surprise users who expect partial results. |
| **Detection — existing** | Node status for the failed branch in `df.instance_nodes()`. Orchestration output contains the error from the failing branch. |
| **Detection — gap** | **No visibility into which branches succeeded before the JOIN was marked failed.** Successful branch results are lost. |
| **Programmatic mitigation** | None — this is the defined JOIN semantic. |
| **User recommendation** | If you need partial-failure tolerance in parallel execution, wrap each branch's SQL in its own error handling (e.g., `BEGIN...EXCEPTION...END` in PL/pgSQL) so it returns an error value instead of raising an exception. |

---

### FM-12: RACE Semantics — Losing Branch Continues Running

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 |
| **Component** | `src/orchestrations/execute_function_graph.rs` — RACE handling |
| **Trigger** | A `df.race()` completes when the first branch finishes. The "losing" branch is **not cancelled** — it continues executing. |
| **Impact** | Side effects from the losing branch (SQL writes, HTTP calls) still occur even though the RACE result has been determined. This can cause unexpected mutations or duplicate HTTP requests. Resource waste from the abandoned branch. |
| **Detection — existing** | The losing branch's node status in `df.instance_nodes()` will eventually show `completed` or `failed` independently. |
| **Detection — gap** | **No clear indication** in the RACE result that the losing branch is still running. No log distinguishing "race winner" from "race loser (still running)". |
| **Programmatic mitigation** | None — duroxide `select2` doesn't cancel the loser. |
| **Process mitigation** | Document this behavior prominently: RACE does not cancel the losing branch. Users must ensure losing branches are idempotent or side-effect-free. |
| **User recommendation** | Use `df.race()` only when both branches are safe to run to completion independently. Do not use RACE if losing branches have destructive side effects (e.g., DELETE statements). |

---

### FM-13: Variable Substitution — Unset Variables

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 |
| **Component** | `src/types.rs` — `substitute_all()` |
| **Trigger** | A SQL query references `$varname` but the variable was never set via `df.setvar()` or captured via `\|=>`. |
| **Impact** | The literal string `$varname` is left in the query unchanged. The query is sent to PostgreSQL as-is, which will likely produce a syntax error or unexpected behavior (e.g., `$varname` could be interpreted as a dollar-quoted string boundary). The activity fails with a SQL error. |
| **Detection — existing** | Activity trace: `"SQL execution failed: ..."` with the raw query visible in `"Executing SQL: {final_query}"`. |
| **Detection — gap** | **No warning at substitution time** that a referenced variable was not found. The substitution silently passes through unknown references. |
| **Programmatic mitigation** | None — `substitute_all()` uses `String::replace()` which is a no-op for missing keys. |
| **Process mitigation** | Document variable substitution behavior and the requirement to set variables before referencing them. |
| **User recommendation** | Set all variables with `df.setvar()` before calling `df.start()`. Use `\|=> 'name'` to capture intermediate results. Check `df.instance_nodes()` output to see the actual executed SQL if a node fails. |

> **Recommendation**: Log a warning in `substitute_all()` when a `$varname` pattern is present in the query but no matching variable is found in the vars map.

---

### FM-14: Extension DROP While Workflows Are Running

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-1 |
| **Component** | `src/worker.rs` — epoch sentinel, extension lifecycle |
| **Trigger** | An administrator runs `DROP EXTENSION pg_durable CASCADE` while durable functions are in-flight. |
| **Impact** | The `df.instances`, `df.nodes`, and `df.vars` tables are dropped. Running orchestrations lose their state tables. The worker detects the extension drop via the epoch sentinel (or extension-existence polling) and returns to the "waiting for extension" state. Duroxide runtime is shut down with a 10-second timeout. **In-flight activities that are mid-SQL-execution may fail with "relation does not exist" errors.** All instance data is permanently lost. |
| **Detection — existing** | Worker log: `"pg_durable: epoch sentinel gone — extension dropped or recreated"`. Worker log: `"pg_durable: initiating duroxide runtime shutdown..."`. |
| **Detection — gap** | **No pre-drop safety check.** PostgreSQL allows `DROP EXTENSION` even with active instances. No advisory lock or "in-use" guard. **Duroxide state in `duroxide.*` tables may or may not be dropped** depending on whether they're owned by the extension. |
| **Programmatic mitigation** | The worker gracefully shuts down the duroxide runtime (10s timeout). After extension re-creation, the worker re-initializes. |
| **Process mitigation** | PaaS should restrict `DROP EXTENSION` to maintenance windows. Document the data-loss implications. Consider an event trigger that warns when durable functions are active. |
| **User recommendation** | Never drop the extension while workflows are running. Check `SELECT count(*) FROM df.instances WHERE status IN ('pending', 'running')` before dropping. |

> **Recommendation**: Add an event trigger or pre-drop check that warns/blocks if active instances exist.

---

### FM-15: Duroxide State Corruption / Schema Drift

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-1 |
| **Component** | duroxide-pg-opt provider, `sql/duroxide_install.sql` |
| **Trigger** | The `duroxide.*` schema tables become corrupted (e.g., manual edits, failed migration, storage corruption), or the pg_durable extension is compiled against a different version of duroxide-pg-opt than what's in the database. |
| **Impact** | `PostgresProvider::new_with_config()` fails schema validation, entering the infinite retry loop. Or, runtime starts but produces incorrect behavior (events lost, wrong execution order, duplicate activity dispatches). |
| **Detection — existing** | Worker log: `"failed to create PostgreSQL store (will retry): {}"` with schema validation errors. The `verify-duroxide-migrations.sh` script ensures compile-time consistency. |
| **Detection — gap** | **No runtime schema version check** after initial startup. If tables are altered while running, behavior is undefined. **No checksum or version stamp** in the duroxide schema for runtime verification. |
| **Programmatic mitigation** | The provider uses `MigrationPolicy::VerifyOnly` (never auto-migrates; only verifies schema matches expectations). CI runs `verify-duroxide-migrations.sh` on every PR. |
| **Process mitigation** | PaaS should never allow direct DDL on `duroxide.*` tables. Schema modifications only through extension upgrades. |
| **User recommendation** | Do not modify tables in the `duroxide` schema directly. If workflows stop processing, contact your database administrator. |

---

### FM-16: Single Background Worker Bottleneck

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-2 |
| **Component** | `src/worker.rs` — single worker architecture |
| **Trigger** | High volume of concurrent durable function submissions. Each SQL activity opens a synchronous database connection. Long-running SQL queries block the activity thread. |
| **Impact** | Duroxide dispatches activities to a thread pool within the single background worker process. Under high load, the thread pool saturates. New orchestrations and activities queue up. Latency increases for all users. With many long-running SQL queries, the worker's connection count approaches PostgreSQL's `max_connections`. |
| **Detection — existing** | `df.metrics()` shows `running_instances` count. `df.list_instances('pending')` shows queued work. Increasing gap between `df.start()` time and first activity execution visible in `df.instance_nodes()` timestamps. |
| **Detection — gap** | **No queue depth metric.** **No activity throughput metric** (activities/second). **No worker thread pool utilization metric.** **No p50/p95/p99 latency metric** for activity execution or end-to-end instance completion. These are critical for capacity planning. |
| **Programmatic mitigation** | Duroxide's internal dispatcher handles concurrency. `continue_as_new` for loops limits per-execution history growth. |
| **Process mitigation** | PaaS should establish capacity guidelines (max concurrent instances per database size/tier). Monitor queue depth trends. |
| **User recommendation** | If workflows are slow to start, check the pending instance count with `SELECT count(*) FROM df.instances WHERE status = 'pending'`. Avoid submitting many long-running SQL workflows simultaneously. |

> **Recommendation**: Expose worker thread pool metrics via `df.metrics()` — add fields for `pending_activities`, `active_activities`, `activity_throughput_per_min`. Consider adding a GUC for max concurrent activities.

---

### FM-17: PostgreSQL Restart / Failover

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-2 |
| **Component** | Worker lifecycle, duroxide runtime |
| **Trigger** | PostgreSQL server restarts (planned maintenance, crash recovery, HA failover). |
| **Impact** | Background worker process terminates. All in-flight activities are interrupted. On restart, the worker re-initializes: creates new Tokio runtime, reconnects, re-creates the duroxide runtime. Duroxide replays incomplete orchestrations from their last checkpoint. **Activities that were mid-execution are re-dispatched** (duroxide's at-least-once guarantee). SQL queries that were partially executed may be re-executed. |
| **Detection — existing** | Worker log: `"pg_durable: duroxide background worker starting..."` (after restart). The `df._worker_epoch` table gets a new epoch UUID. |
| **Detection — gap** | **No metric for "time since last worker restart"** or "worker uptime". **No explicit log** distinguishing a fresh start from a restart-after-crash. **No replay counter** showing how many orchestrations were replayed after restart. |
| **Programmatic mitigation** | Duroxide's durable execution model handles this: orchestrations replay deterministically, activities that completed are not re-executed (their results are in the event log), activities that were in-flight are re-dispatched. |
| **Process mitigation** | PaaS should monitor worker restarts. Frequent restarts indicate an underlying issue. |
| **User recommendation** | Durable functions survive PostgreSQL restarts by design. If a workflow was `running` before a restart, it will resume automatically. Ensure your SQL operations are idempotent where possible, as in-flight activity SQL may be re-executed. |

> **Critical user guidance**: SQL activities have **at-least-once** execution semantics. A SQL statement that was executing when PostgreSQL restarted will be re-executed after recovery. **Users must design their SQL to be idempotent** (e.g., use `INSERT ... ON CONFLICT`, `UPDATE ... WHERE` with guards, not bare `INSERT`).

---

### FM-18: Column Type Extraction Loss in SQL Results

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 |
| **Component** | `src/activities/execute_sql.rs` — result row mapping |
| **Trigger** | A SQL query returns a column of a PostgreSQL type not handled by the type-extraction cascade (which tries: String, i64, i32, bool, f64 in order). Custom types, arrays, composite types, `bytea`, `uuid`, `inet`, etc. |
| **Impact** | The column value is silently replaced with `null` in the JSON result. The workflow continues with partial data. Downstream nodes that depend on this value see `null` instead of the actual value. |
| **Detection — existing** | None — the fallback to `null` is silent. The activity trace logs `"SQL returned N rows"` without indicating data loss. |
| **Detection — gap** | **No warning when a column value falls through all type extractors to null.** This is a silent data loss bug. |
| **Programmatic mitigation** | The type cascade covers the most common types. Users can `CAST` to supported types in their SQL. |
| **User recommendation** | Cast complex column types to `text` in your SQL queries (e.g., `SELECT my_uuid::text, my_array::text FROM ...`) to ensure values are captured in the result. |

> **Recommendation**: Log a warning (via `ctx.trace_info`) when a column value falls through all type extractors to null, including the column name and PostgreSQL type OID.

---

### FM-19: `continue_as_new` Serialization Failure in Loops

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-2 |
| **Component** | `src/orchestrations/execute_function_graph.rs` — loop iteration |
| **Trigger** | The orchestration input (including accumulated variable state and graph) fails to serialize for the `continue_as_new` call. This could happen if the state has grown very large (many variables with large values) or contains non-serializable data. |
| **Impact** | The `unwrap_or(...)` fallback provides a minimal input (just the instance ID), potentially losing accumulated loop state including variables, iteration results, and context. The next iteration starts with degraded state, which may cause incorrect behavior or errors. |
| **Detection — existing** | No explicit log for serialization failure — the `unwrap_or` silently degrades. |
| **Detection — gap** | **Complete blind spot.** No logging, no metric, no indication that state was lost during `continue_as_new`. |
| **Programmatic mitigation** | The `unwrap_or` prevents a panic but trades correctness for availability. |
| **Process mitigation** | None currently. |
| **User recommendation** | Keep workflow variable counts and sizes reasonable. Avoid storing large result sets in named variables (`\|=> 'name'`). |

> **Recommendation**: Replace the `unwrap_or` with explicit error handling that logs a warning and/or fails the orchestration cleanly rather than silently degrading.

---

### FM-20: Stale Client Connection in Backend Processes

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-2 |
| **Component** | `src/client.rs` — `OnceLock<Client>` |
| **Trigger** | A backend process (user session) creates a duroxide `Client` via `get_duroxide_client()` on the first call. The client holds a connection pool to the duroxide store. If the underlying connection becomes stale (e.g., after a network partition heals, pgbouncer timeout, or connection idle timeout), subsequent calls fail. |
| **Impact** | `df.start()`, `df.cancel()`, `df.signal()` fail for that backend session with connection errors. Since `OnceLock` initializes only once, the stale client persists for the lifetime of the backend process. The user must disconnect and reconnect to get a fresh client. |
| **Detection — existing** | `pgrx::error!` with `"Failed to start durable function: ..."` or similar. |
| **Detection — gap** | **No health-check or reconnection logic** for the cached client. No metric for client connection age or staleness. |
| **Programmatic mitigation** | sqlx's built-in pool management handles some connection recycling, but the pool configuration isn't tuned for long-lived backend processes. |
| **Process mitigation** | PaaS connection management (e.g., pgbouncer) should be configured with timeouts compatible with pg_durable's connection caching. |
| **User recommendation** | If `df.start()` fails with a connection error, disconnect your session and reconnect. The new session will create a fresh client. |

> **Recommendation**: Add connection validation (e.g., test query before use) or TTL-based client recycling to `get_duroxide_client()`.

---

### FM-21: Duroxide Runtime Shutdown Timeout

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-2 |
| **Component** | `src/worker.rs` — `duroxide_runtime.shutdown(Some(10_000))` |
| **Trigger** | During PostgreSQL shutdown or extension drop, the duroxide runtime is given 10 seconds to complete shutdown. If activities are mid-execution (e.g., a long-running SQL query or HTTP request), they may not complete within this window. |
| **Impact** | Activities are forcibly terminated. In-flight SQL statements are rolled back by PostgreSQL. Orchestrations are interrupted mid-execution. On next startup, duroxide replays from the last checkpoint, re-dispatching interrupted activities. **During the shutdown window, the PostgreSQL shutdown is delayed by up to 10 seconds**, which may cause PaaS health checks to flag the instance. |
| **Detection — existing** | Worker log: `"pg_durable: initiating duroxide runtime shutdown..."` followed by `"pg_durable: duroxide runtime shutdown complete"`. |
| **Detection — gap** | **No log indicating whether shutdown completed within the timeout or was forcibly terminated.** The 10s timeout is a fire-and-forget; we don't know if activities were cleanly stopped. |
| **Programmatic mitigation** | The 10s timeout is hardcoded. Tokio runtime has a separate 5s `shutdown_timeout`. Duroxide replays handle interrupted work. |
| **Process mitigation** | PaaS should configure PostgreSQL shutdown timeouts to accommodate the 10s duroxide shutdown + 5s Tokio shutdown. |
| **User recommendation** | Long-running workflows will resume after a server restart. No action needed. |

---

### FM-22: Node ID Collision

| Attribute | Detail |
|-----------|--------|
| **Severity** | SEV-3 (extremely unlikely) |
| **Component** | `src/dsl.rs` — node ID generation |
| **Trigger** | Node IDs are generated as 8-character hex strings (4 bytes of randomness = ~4 billion possibilities). Under very high volume, a collision is theoretically possible within a single instance's graph. |
| **Impact** | An INSERT into `df.nodes` fails with a primary key violation. `df.start()` fails and returns an error to the user. No data corruption — the transaction is rolled back. |
| **Detection — existing** | `pgrx::error!("Failed to insert node {}: {:?}")` |
| **Detection — gap** | None — the error is clear and the failure is safe. |
| **Programmatic mitigation** | The probability is vanishingly small for typical graph sizes (< 1000 nodes). |
| **User recommendation** | Retry `df.start()` if you encounter a node insertion error. |

---

## 4. Telemetry & Observability Assessment

### 4.1 What Exists Today

| Mechanism | Location | Content | Consumers |
|-----------|----------|---------|-----------|
| **PostgreSQL server logs** (`pgrx::log!`) | `src/worker.rs`, `src/dsl.rs`, `src/client.rs` | ~25 lifecycle messages with `"pg_durable:"` prefix | Log aggregation (CloudWatch, Azure Monitor, etc.) |
| **Duroxide activity traces** (`ctx.trace_info`) | `src/activities/*.rs` | SQL audit trail, HTTP audit trail, SSRF blocks, status updates | Stored in duroxide event history; queryable via `df.instance_nodes()` |
| **Duroxide orchestration traces** (`ctx.trace_info`) | `src/orchestrations/*.rs` | Node execution flow, variable substitution, loop iterations, condition evaluation | Stored in duroxide event history |
| **`df.metrics()`** | `src/monitoring.rs` | 6 aggregate counters: total/running/completed/failed instances, total executions, total events | User SQL queries, dashboards |
| **`df.status()`** | `src/dsl.rs` | Per-instance status: pending/running/completed/failed/cancelled | User SQL queries, polling loops |
| **`df.list_instances()`** | `src/monitoring.rs` | RLS-filtered instance listing with status, label, output | User SQL queries |
| **`df.instance_info()`** | `src/monitoring.rs` | Single-instance detail with execution count | User SQL queries |
| **`df.instance_executions()`** | `src/monitoring.rs` | Execution history for looping instances | User SQL queries |
| **`df.instance_nodes()`** | `src/monitoring.rs` | Per-node execution status and results | User SQL queries |
| **Epoch sentinel** (`df._worker_epoch`) | `src/worker.rs`, `src/lib.rs` | Worker liveness: UUID + `last_seen_at` timestamp | Operator queries |
| **Tracing subscriber** | `src/worker.rs` | Configurable via `RUST_LOG` env var; defaults to `warn` with `info` for duroxide modules | stderr → PostgreSQL log file |

### 4.2 Telemetry Gaps

The following gaps are prioritized by operational impact:

#### Critical Gaps (needed for production readiness)

| Gap | Relevant Failure Modes | Recommendation |
|-----|----------------------|----------------|
| **No worker health-check function** | FM-1, FM-2, FM-3 | Add `df.worker_status()` returning `(alive bool, last_heartbeat timestamptz, uptime_seconds int, current_epoch uuid)` by querying `df._worker_epoch`. |
| **No queue depth / throughput metrics** | FM-16 | Extend `df.metrics()` with `pending_instances`, `avg_completion_time_ms`, and if feasible `active_activities`, `pending_activities`. |
| **No per-instance duration metric** | FM-10, FM-16 | Add `duration_ms` to `df.list_instances()` output (computed from `created_at` to `completed_at`). |
| **No connection count visibility** | FM-7, FM-16 | Log active activity connection count in `execute_sql`; consider a `df.worker_connections()` metric. |

#### Important Gaps (needed for operational maturity)

| Gap | Relevant Failure Modes | Recommendation |
|-----|----------------------|----------------|
| **Silent monitoring failures** | FM-16 | `df.list_instances()`, `df.instance_info()`, etc. return empty results on internal errors (store connection failure). Add `RAISE WARNING` when the duroxide client fails. |
| **No structured security audit log** | FM-9 | Emit SSRF blocks to a dedicated channel or table, not just activity traces. |
| **No `continue_as_new` failure logging** | FM-19 | Replace `unwrap_or` with explicit error logging. |
| **No column type fallback warning** | FM-18 | Log when a SQL result column value falls through to `null`. |
| **No activity retry telemetry** | FM-5, FM-8 | Log/count transaction-visibility retries in `load_function_graph` and any future HTTP retries. |

#### Nice-to-Have Gaps (for mature observability)

| Gap | Relevant Failure Modes | Recommendation |
|-----|----------------------|----------------|
| **No histogram metrics** (p50/p95/p99 latency) | FM-16 | Requires integration with a metrics library (e.g., `metrics` crate exported via `pg_stat` or Prometheus endpoint). |
| **No worker restart counter** | FM-17 | Track epoch changes in `df._worker_epoch` (each new row = a restart). |
| **No `RACE` winner/loser logging** | FM-12 | Log which branch won a RACE and that the other continues running. |
| **No variable substitution miss warning** | FM-13 | Warn when `$varname` patterns remain after substitution. |

### 4.3 Log Searchability

All PostgreSQL-level logs use the `"pg_durable: "` prefix, making them grep-friendly. Recommended log-based alert patterns for operators:

| Pattern | Meaning | Action |
|---------|---------|--------|
| `"pg_durable: failed to create tokio runtime"` | Worker startup failure | Page on-call — FM-1 |
| `"will retry"` repeated > 10 times | Worker connection loop stuck | Investigate auth/connectivity — FM-2 |
| `"worker role.*NOT a superuser"` | Misconfigured worker role | Fix role privileges — FM-3 |
| `"epoch sentinel gone"` | Extension dropped/recreated | Verify intentional — FM-14 |
| `"HTTP BLOCKED"` | SSRF attempt | Security review — FM-9 |
| `"Instance.*not found after 5s"` | Transaction visibility timeout | Check for long transactions — FM-5 |
| `"failed to create PostgreSQL store"` repeated | Duroxide schema issue | Check migrations — FM-15 |

---

## 5. User-Facing Recommendations Summary

### Before Going to Production

1. **Verify worker health**: Query `SELECT * FROM df._worker_epoch` — confirm `last_seen_at` is recent.
2. **Test idempotency**: All SQL in durable functions may be re-executed after a server restart. Use `INSERT ... ON CONFLICT`, conditional `UPDATE`s, etc.
3. **Set appropriate timeouts**: `df.http()` timeout defaults to 30s. Set it based on your endpoint's expected latency.
4. **Cast complex types**: Use `::text` casts for UUID, array, composite, and other non-primitive columns in `df.sql()` queries.
5. **Scope variables**: Set all `df.setvar()` values before `df.start()`. Use `\|=> 'name'` for intermediate results.

### Monitoring Your Workflows

| What to Check | How |
|---------------|-----|
| Workflow status | `SELECT * FROM df.status('instance-id')` |
| All your workflows | `SELECT * FROM df.list_instances()` |
| Stuck workflows | `SELECT * FROM df.list_instances('running')` — check for old entries |
| Failed workflow details | `SELECT * FROM df.instance_nodes('instance-id')` — find the failed node |
| System health | `SELECT * FROM df.metrics()` — watch for growing `running_instances` with flat `completed_instances` |

### When Things Go Wrong

| Symptom | Likely Cause | Action |
|---------|-------------|--------|
| Workflow stuck at `pending` | Worker not running or not a superuser | Check `df._worker_epoch`, contact DBA |
| Workflow `failed` immediately | SQL error, missing table/role, validation failure | Check `df.instance_nodes()` for error details |
| HTTP node failed | Timeout, SSRF block, remote server error | Check node result for error message; verify URL is public |
| All workflows slow | Worker overloaded or PostgreSQL under pressure | Check `df.metrics()`, reduce concurrent submissions |
| `df.start()` errors with connection failure | Stale client in backend session | Reconnect your session |

---

## 6. Service-Owner (PaaS) Operational Runbook

### Alerts to Configure

| Alert | Condition | Severity | Failure Mode |
|-------|-----------|----------|-------------|
| Worker absent | No `pg_durable_worker` in `pg_stat_activity` for > 30s | P1 | FM-1 |
| Worker retry storm | `"will retry"` in logs > 10 occurrences/minute | P1 | FM-2 |
| Worker role warning | `"NOT a superuser"` in logs at extension creation | P1 | FM-3 |
| Epoch sentinel stale | `df._worker_epoch.last_seen_at` > 60s old | P2 | FM-1, FM-14 |
| Pending queue growth | `df.metrics().running_instances` increasing without `completed_instances` growth | P2 | FM-3, FM-16 |
| SSRF blocks | `"HTTP BLOCKED"` in logs | P3 (security) | FM-9 |
| Extension dropped | `"epoch sentinel gone"` in logs | P2 | FM-14 |

### Capacity Planning Considerations

- Each SQL activity opens one PostgreSQL connection. Plan `max_connections` with headroom for concurrent activity execution.
- Duroxide state tables (`duroxide.*`) grow with instance count and execution history. Plan storage for long-running or eternal (looping) instances.
- The single background worker is the throughput bottleneck. Monitor pending-to-running transition latency as a proxy for capacity.

### Upgrade / Migration Safety

- `pg_durable.worker_role` and `pg_durable.database` are `PGC_POSTMASTER` GUCs — changes require a PostgreSQL restart.
- Extension upgrades (`ALTER EXTENSION pg_durable UPDATE`) must be tested against the existing duroxide schema. The `MigrationPolicy::VerifyOnly` setting means the extension will not auto-migrate — schema must already match.
- Always run `verify-duroxide-migrations.sh` before deploying a new version.
