# Feature Specification: Connection Limits

**Branch**: pinodeca/connection-limits  
**Created**: 2026-03-26  
**Status**: Draft  
**Input Brief**: Limit and configure concurrent sqlx connections: independent GUCs for management, duroxide, and user-execution connections in the background worker; 1 connection per PG backend.

## Overview

pg_durable currently places no upper bound on the number of PostgreSQL connections it creates. Each PG backend session that calls `df.start()` lazily creates a duroxide provider with a pool of up to 10 connections — and these pools are not shared across sessions. On the background worker side, four separate connection sources exist: a polling pool (1 connection), an activity pool (5 connections), a duroxide provider pool (10 connections, which internally includes a dedicated listener connection), and unbounded per-execution user connections created by `connect_as_user()`. Under high concurrency, these unbounded connections can exhaust PostgreSQL's `max_connections` limit, starving other workloads and potentially crashing the server.

This specification introduces three independent GUCs that give a DBA full control over the background worker's connection footprint. The worker's polling pool and activity pool are consolidated into a single **management pool** — both authenticate as the worker role, use the same connection string, and the `df.in_workflow` hook on the activity pool is unnecessary (since `connect_as_user()` already sets it independently on user-execution connections). The duroxide provider pool already includes its own listener connection internally, so it remains as a single **duroxide pool**. User-execution connections are controlled by an async semaphore sized by a third GUC.

Each PG backend is limited to a single sqlx connection (sufficient for the lightweight queue-insert operations it performs). A DBA computes the worst-case pg_durable connection usage as: `max_management_connections + max_duroxide_connections + max_user_connections + (number of backends × 1)`.

The goal is predictability: a DBA should be able to look at the pg_durable GUCs and know exactly how many connections the extension will consume, then size `max_connections` accordingly. No surprises under load.

## Objectives

- **Predictable connection footprint**: A DBA can compute the maximum number of connections pg_durable will use from three independent GUC values, enabling safe `max_connections` sizing.
- **Protect the database from connection exhaustion**: Prevent pg_durable from consuming all available connections under high-concurrency workloads.
- **Simplify the worker's pool architecture**: Consolidate the polling pool and activity pool into a single management pool, reducing the number of separate pools the worker manages.
- **Preserve user isolation**: User SQL continues to execute under the submitting user's identity with proper `SET ROLE` — connection limits do not compromise the security model.
- **Graceful degradation under load**: When user-execution limits are reached, new work queues with backpressure rather than failing immediately, with a configurable timeout as a safety valve.
- **Minimize backend connection waste**: PG backends that call `df.start()` should not hold idle pool connections — one connection is sufficient for queue-insert operations.

## User Scenarios & Testing

### User Story P1 – DBA Controls Connection Budget

Narrative: A DBA configuring pg_durable sets three GUCs to independently control management, duroxide, and user-execution connection pools. They can compute the worst-case connection count as the sum of these three values plus one per backend session, and size `max_connections` with confidence.

Independent Test: Set the three GUCs, run concurrent workflows, observe that each pool's connections never exceed its configured limit.

Acceptance Scenarios:
1. Given `pg_durable.max_management_connections = 3`, `pg_durable.max_duroxide_connections = 5`, `pg_durable.max_user_connections = 10`, When the background worker is running at full load, Then at most 3 management connections, 5 duroxide connections, and 10 user-execution connections exist simultaneously.
2. Given the three GUC defaults, When a DBA reads the documentation, Then they can compute `max pg_durable connections = max_management_connections + max_duroxide_connections + max_user_connections + (number of backends × 1)`.
3. Given any combination of the three GUCs, When the background worker starts, Then it creates pools of exactly the configured sizes (no hidden extra connections).

### User Story P2 – Graceful Backpressure Under Load

Narrative: A system running many concurrent durable functions hits the user-execution connection limit. New SQL node executions wait in a queue rather than failing. If wait time exceeds the timeout, the execution fails with a clear error rather than hanging indefinitely.

Independent Test: Set a low user-execution limit, saturate it, then start one more workflow and observe it completes after an existing one finishes.

Acceptance Scenarios:
1. Given `pg_durable.max_user_connections = 2` and 2 SQL nodes currently executing, When a 3rd SQL node is dispatched, Then it waits until one of the executing nodes completes, then proceeds.
2. Given `pg_durable.max_user_connections = 1` and `pg_durable.execution_acquire_timeout = 5` and 1 SQL node executing for 10 seconds, When a 2nd SQL node is dispatched, Then it fails after 5 seconds with an error message indicating the connection limit was reached.
3. Given backpressure is active, When the queued execution eventually acquires a slot, Then it executes with the correct user identity (`login_role` + `SET ROLE submitted_by`) — the delay does not corrupt the security context.

### User Story P3 – Backend Connection Efficiency

Narrative: A backend session calls `df.start()`, which needs to enqueue work to the duroxide runtime. This operation uses at most 1 connection, not a pool of 10.

Independent Test: Call `df.start()` from a backend, verify via `pg_stat_activity` that the backend created at most 1 additional connection.

Acceptance Scenarios:
1. Given a backend session, When `df.start()` is called for the first time, Then at most 1 sqlx connection is established to PostgreSQL.
2. Given a backend session with an active duroxide client, When `df.start()` is called again, Then no additional connections are created — the existing connection is reused.
3. Given 50 concurrent backend sessions each calling `df.start()`, Then at most 50 sqlx connections exist for backend operations (1 per session).

### Edge Cases

- **Worker shutdown during backpressure**: Queued executions waiting for a connection slot should be cancelled cleanly when the background worker receives a shutdown signal.
- **Connection failure within pool**: If a management or duroxide pool connection fails (network error, server restart), the pool should recover without permanently losing capacity.
- **Zero user-execution connections configured**: If `pg_durable.max_user_connections` is set to 0 (accidentally or intentionally), all SQL node executions should fail immediately with a clear configuration error at worker startup.
- **Management pool too small**: If `pg_durable.max_management_connections` is set below the minimum needed for worker operations, the worker should log a warning. The minimum viable size is 1 (queries will serialize).
- **Duroxide pool too small for listener**: The duroxide provider creates an internal listener connection from its pool. If `pg_durable.max_duroxide_connections` is 1, the listener consumes the only connection, leaving none for orchestration queries. The minimum viable size should account for the listener overhead; the worker should validate this at startup.
- **Management and duroxide pool acquire timeouts**: Both pools use sqlx's default 30-second acquire timeout internally (the duroxide provider sets it explicitly at `provider.rs:154`). These are not exposed as GUCs — if all connections in a management or duroxide pool are busy, sqlx will wait up to 30s before returning `PoolTimedOut`. Only the user-execution acquire timeout is DBA-configurable, since that's where backpressure behavior under load matters most.
- **Interaction with PostgreSQL per-role `CONNECTION LIMIT`**: Workflow connections created by `connect_as_user()` authenticate as the `login_role` (the user who called `df.start()`), then `SET ROLE` to `submitted_by` after connecting. PostgreSQL's `ALTER ROLE ... CONNECTION LIMIT` is enforced at connect time against the authenticating role, so these connections count against the `login_role`'s limit — not the `submitted_by` role's. If both pg_durable's `max_user_connections` and the role's `CONNECTION LIMIT` exist, the more restrictive one effectively applies. Similarly, all management and duroxide pool connections count against `pg_durable.worker_role`'s `CONNECTION LIMIT`.
- **Backend connection with reduced pool**: With a 1-connection provider pool, concurrent `df.start()` + `df.cancel()` calls from the same backend session serialize on the single connection. Since these are short-lived queue inserts, this is acceptable — but the spec should document the serialization behavior.

## Requirements

### Functional Requirements

- FR-001: A GUC `pg_durable.max_management_connections` controls the size of the consolidated management pool (merged polling + activity pools). Default preserves current combined capacity (6). (Stories: P1)
- FR-002: A GUC `pg_durable.max_duroxide_connections` controls the size of the duroxide provider pool (which internally includes the listener connection). Default preserves current capacity (10). (Stories: P1)
- FR-003: A GUC `pg_durable.max_user_connections` controls the maximum number of concurrent user-execution connections (connections created by `connect_as_user` for SQL node execution). Default: 10. (Stories: P1, P2)
- FR-004: A GUC `pg_durable.execution_acquire_timeout` controls how long (in seconds) a SQL node execution will wait for an available user-execution connection slot before failing. Default: 30 (consistent with sqlx's internal pool acquire timeout). (Stories: P2)
- FR-005: The background worker consolidates the existing polling pool (1 connection) and activity pool (5 connections) into a single management pool sized by `pg_durable.max_management_connections`. The `df.in_workflow` `after_connect` hook is dropped (unnecessary — `connect_as_user()` sets it independently). (Stories: P1)
- FR-006: The duroxide provider pool size is set to `pg_durable.max_duroxide_connections` via the `DUROXIDE_PG_POOL_MAX` mechanism or provider config. (Stories: P1)
- FR-007: When the user-execution connection limit is reached, new SQL node executions queue (backpressure) until a slot frees up or the acquire timeout expires. (Stories: P2)
- FR-008: When the acquire timeout expires, the SQL node execution fails with a descriptive error indicating the connection limit was reached and the timeout elapsed. (Stories: P2)
- FR-009: Each PG backend session creates a duroxide provider with a pool of at most 1 connection, reducing per-backend connection footprint from up to 10 to exactly 1. (Stories: P3)
- FR-010: The background worker validates at startup that GUC values meet minimum viable thresholds (e.g., `max_user_connections ≥ 1`, `max_duroxide_connections` ≥ minimum for listener + at least 1 orchestration query). If invalid, the worker logs an error and refuses to start. (Stories: P1)
- FR-011: All GUCs introduced by this feature are `Postmaster`-context (set in `postgresql.conf`, require server restart). (Stories: P1)

### Key Entities

- **Management Pool**: A single consolidated pool (merging the former polling and activity pools) used by the background worker for internal operations — extension lifecycle checks, epoch sentinels, graph loading, status updates. Authenticates as the worker role. Sized by `pg_durable.max_management_connections`.
- **Duroxide Pool**: The pool owned internally by `PostgresProvider`, used for orchestration state management and LISTEN/NOTIFY (listener connection is sourced from this pool). Authenticates as the worker role. Sized by `pg_durable.max_duroxide_connections`.
- **User-Execution Permit**: A permit from an async semaphore sized by `pg_durable.max_user_connections`, controlling how many concurrent `connect_as_user` connections may exist simultaneously. Each permit allows one transient TCP connection authenticating as the submitting user.

### Cross-Cutting / Non-Functional

- The backpressure mechanism must not deadlock the single-threaded tokio runtime — the semaphore acquisition must be async-aware.
- Connection limits must not compromise user isolation: each user-execution connection must still authenticate as `login_role` and `SET ROLE` to `submitted_by`.
- The duroxide pool size must be controllable from pg_durable's side without modifying the duroxide-pg-opt submodule (e.g., via the `DUROXIDE_PG_POOL_MAX` env var or provider config).

## Success Criteria

- SC-001: Under a workload of 100 concurrent durable functions each executing SQL nodes, the number of user-execution connections never exceeds `pg_durable.max_user_connections`. (FR-003, FR-007)
- SC-002: The management pool never exceeds `pg_durable.max_management_connections` connections, verified via `pg_stat_activity`. (FR-001, FR-005)
- SC-003: When user-execution connections are saturated, additional SQL node executions complete successfully (not error) after existing ones finish, provided the wait is within the timeout. (FR-007)
- SC-004: When the acquire timeout is exceeded, the failing SQL node reports a clear, actionable error message. (FR-008)
- SC-005: A PG backend session calling `df.start()` creates at most 1 sqlx connection to PostgreSQL, verified via `pg_stat_activity`. (FR-009)
- SC-006: A misconfigured GUC (e.g., `max_user_connections = 0`) produces a clear startup error, and the worker does not proceed. (FR-010)
- SC-007: All existing E2E tests pass without modification to GUC defaults. (FR-001 through FR-011)
- SC-008: A DBA can compute `max_management_connections + max_duroxide_connections + max_user_connections + (backends × 1)` from the documented GUC values to determine total pg_durable connection usage. (FR-001, FR-002, FR-003, FR-011)

## Assumptions

- **Duroxide provider pool size is controllable**: The `DUROXIDE_PG_POOL_MAX` env var or provider config allows pg_durable to set the duroxide pool size. If not, the duroxide submodule may need a minor config change (documented as a risk).
- **Listener connection is internal to the duroxide pool**: `PgListener::connect_with(&pool)` sources the listener from the provider's pool (verified at `duroxide-pg-opt/src/notifier.rs:134`). No separate listener connection exists outside the duroxide pool.
- **Polling and activity pool consolidation is safe**: Both use the same connection string and authenticate as the same role. The `df.in_workflow` `after_connect` hook on the activity pool is unnecessary — `connect_as_user()` independently sets this flag on every user-execution connection, which is the actual enforcement point. Management queries never invoke DSL functions.
- **Backend operations are lightweight**: `df.start()`, `df.cancel()`, and `df.signal()` are short-lived queue inserts taking <1ms each. A single-connection pool is sufficient because concurrent calls from the same backend session will serialize, and the serialization latency is negligible.
- **Single background worker**: There is exactly one background worker process. The connection limits apply to that single worker. Multiple-worker scenarios are out of scope.
- **Passwordless auth continues**: The `connect_as_user` function will continue to use passwordless (trust/peer) authentication. Connection pooling for user-execution connections is out of scope because each connection has a unique user identity.
- **GUC defaults preserve current behavior**: Default values for the new GUCs match current pool sizes (management=6, duroxide=10) or provide reasonable initial limits (user=10, acquire_timeout=30s) so existing deployments are not broken by upgrade.

## Scope

In Scope:
- Consolidating the background worker's polling pool and activity pool into a single management pool
- Three independent GUCs for pool sizing (`max_management_connections`, `max_duroxide_connections`, `max_user_connections`)
- A GUC for backpressure timeout (`execution_acquire_timeout`)
- Semaphore-based backpressure for user-execution connections in the background worker
- Reducing the PG backend duroxide provider pool to 1 connection
- Startup validation of GUC minimum thresholds
- Documentation of connection model in the User Guide

Out of Scope:
- Connection pooling for user-execution connections (each has unique user identity, making pooling complex)
- Changes to the duroxide-pg-opt submodule (pool sizes controlled via existing config mechanisms)
- Per-user or per-workflow connection quotas (all user-execution connections share a single budget)
- Dynamic resizing of connection pools without server restart (GUCs are Postmaster-context)
- Multi-worker scenarios

## Dependencies

- Duroxide-pg-opt provider config must support setting pool size at construction time (currently does via `DUROXIDE_PG_POOL_MAX` and `PgPoolOptions`)
- Tokio async semaphore (`tokio::sync::Semaphore`) for backpressure implementation
- PostgreSQL GUC infrastructure via pgrx

## Risks & Mitigations

- **Deadlock from semaphore in single-threaded runtime**: The background worker uses `new_current_thread()` tokio runtime. A blocking semaphore acquisition would deadlock. Mitigation: Use `tokio::sync::Semaphore` with async `.acquire()` which yields to the runtime while waiting.
- **Duroxide submodule changes needed**: If the duroxide provider pool size cannot be controlled purely from pg_durable (e.g., `DUROXIDE_PG_POOL_MAX` doesn't work as expected), the submodule may need modification. Mitigation: Research confirms the env var exists at `provider.rs:146-149`. Verify during implementation.
- **Duroxide pool too small for listener**: The listener consumes one connection from the duroxide pool. If `max_duroxide_connections` is set to 1, the listener takes it and orchestration queries may stall. Mitigation: Validate at startup that `max_duroxide_connections ≥ 2` (1 listener + 1 orchestration minimum).
- **Backend performance with 1-connection pool**: Reducing from 10 to 1 could theoretically slow concurrent operations from the same backend. Mitigation: Backend operations are fire-and-forget queue inserts taking <1ms each. Serialization on 1 connection is negligible. Verify with benchmarks during implementation.
- **Default user-connection limit**: The current behavior is unbounded user-execution connections. The default of 10 for `max_user_connections` is generous enough for typical workloads but may need tuning for high-concurrency deployments. Mitigation: Document clearly in the User Guide and recommend DBAs review after upgrading.

## Upgrade & Migration

- **Backward compatibility (B1)**: The new `.so` must work against all previous schemas. The new GUCs will have defaults that preserve current behavior (no connection limits that would break existing workloads). No schema changes are required — this is purely runtime behavior.
- **Upgrade script DDL**: None required. No new tables, columns, or functions.
- **Runtime detection**: The background worker reads new GUCs at startup. If GUCs are absent (old `postgresql.conf`), defaults apply. No runtime schema detection needed.

## References

- Research: .paw/work/connection-limits/SpecResearch.md
- Background: src/types.rs (connect_as_user, postgres_connection_string), src/worker.rs (pool creation), src/client.rs (backend provider)
