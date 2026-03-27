# Connection Limits Implementation Plan

## Overview

Introduce GUC-controlled connection limits for pg_durable's background worker and PG backend sessions. The worker's polling and activity pools are consolidated into a single management pool, the duroxide provider pool and backend provider pool sizes become configurable, and a semaphore gates user-execution connections with backpressure.

## Current State Analysis

The background worker creates four separate connection sources (CodeResearch §2-4):
- **Polling pool** (1 conn, `worker.rs:99-118`): Extension lifecycle checks, epoch sentinels, worker-ready writes
- **Activity pool** (5 conn, `worker.rs:428-450`): Graph loading, status updates via activity registry
- **Duroxide provider pool** (10 conn, `provider.rs:145-156`): Orchestration state, LISTEN/NOTIFY
- **User-execution connections** (unbounded, `types.rs:97-104`): Per-SQL-node `connect_as_user()`

Each PG backend creates a 10-connection provider pool cached in `OnceLock` (`client.rs:79-80`).

Two GUCs exist (`worker_role`, `database`), both `Postmaster`-context strings registered in `_PG_init` (`lib.rs:55-71`). The `tokio::sync` feature is already enabled (`Cargo.toml:37`).

Key constraints:
- `DUROXIDE_PG_POOL_MAX` env var is the only mechanism to control provider pool size without modifying duroxide-pg-opt (`provider.rs:146-149`)
- The `df.in_workflow` hook on the activity pool is redundant — `connect_as_user()` sets it independently (`types.rs:121-124`)
- The activity registry captures `Arc<PgPool>` in closures (`registry.rs:12-39`) — same pattern works for `Arc<Semaphore>`

## Desired End State

- Four new `Postmaster`-context GUCs: `max_management_connections` (default 6), `max_duroxide_connections` (default 10), `max_user_connections` (default 10), `execution_acquire_timeout` (default 30)
- Worker creates 2 pools: a consolidated management pool (polling + activity) sized by GUC, and a duroxide provider pool sized by GUC via env var
- User-execution connections gated by async semaphore with configurable timeout
- Backend provider pool reduced to 1 connection
- Startup validation rejects invalid GUC combinations
- All existing E2E tests pass unchanged

## What We're NOT Doing

- Pool consolidation beyond polling + activity (duroxide provider pool stays separate — owned by `PostgresProvider`)
- Changes to duroxide-pg-opt submodule
- Per-user or per-workflow connection quotas
- Dynamic GUC reloading (all are Postmaster-context)
- Connection pooling for user-execution connections

## Phase Status
- [x] **Phase 1: GUC Infrastructure** - Declare, register, and validate four new connection limit GUCs
- [x] **Phase 2: Pool Consolidation & Sizing** - Merge polling+activity pools; control duroxide and backend pool sizes via GUCs
- [x] **Phase 3: User-Execution Backpressure** - Add semaphore-based connection limiting with timeout to execute_sql activity
- [ ] **Phase 4: E2E Tests** - Verify connection limits, backpressure, and startup validation
- [ ] **Phase 5: Documentation** - User Guide updates, Docs.md

## Phase Candidates
<!-- None — all phases are required for the feature -->

---

## Phase 1: GUC Infrastructure

### Changes Required:

- **`src/lib.rs`**: Declare four new `GucSetting<i32>` statics after the existing string GUC statics (after line 18). Register them in `_PG_init()` using `GucRegistry::define_int_guc()` between the existing string registrations and `register_background_worker()` (after line 71). Pattern: follow existing `define_string_guc` calls but with `i32` type, `GucContext::Postmaster`, and appropriate min/max ranges.

  | GUC | Default | Min | Max |
  |-----|---------|-----|-----|
  | `pg_durable.max_management_connections` | 6 | 1 | 1000 |
  | `pg_durable.max_duroxide_connections` | 10 | 2 | 1000 |
  | `pg_durable.max_user_connections` | 10 | 1 | 1000 |
  | `pg_durable.execution_acquire_timeout` | 30 | 1 | 3600 |

- **`src/types.rs`**: Add four getter helper functions following the `get_worker_role()` / `get_database()` pattern (after line 33). Each calls `.get()` on the corresponding static and provides the default fallback.

- **`src/worker.rs`**: Add startup validation at the beginning of `run_duroxide_runtime()` (after poll pool creation, before the main loop at ~line 120). Validate:
  - `max_duroxide_connections >= 2` (listener needs at least 1 slot) — if violated, log error and return early (worker refuses to start, FR-010)
  - `max_management_connections == 1` — log warning (functional but leaves no headroom)
  - Log the effective connection budget: `management + duroxide + user`

- **Tests**: Unit test (pgrx test) verifying GUC defaults are readable via the getter helpers. Verify startup validation logs appropriate warnings for edge-case values.

### Success Criteria:

#### Automated Verification:
- [x] `cargo build --features pg17` compiles without warnings
- [x] `cargo clippy --features pg17` passes
- [x] `./scripts/test-unit.sh` passes
- [x] `./scripts/test-e2e-local.sh` passes (regression — GUC defaults preserve behavior)

#### Manual Verification:
- [x] `SHOW pg_durable.max_management_connections` returns 6 in psql
- [x] `SHOW pg_durable.max_user_connections` returns 10 in psql
- [x] Attempting `SET pg_durable.max_management_connections = 3` fails (Postmaster context)

---

## Phase 2: Pool Consolidation & Sizing

### Changes Required:

- **`src/worker.rs`** — `run_duroxide_runtime()`: Replace the polling pool creation (`worker.rs:99-118`) with a management pool creation that uses the `max_management_connections` GUC value. This pool replaces both the polling pool and the activity pool. Remove the `after_connect` hook (not needed — `connect_as_user()` sets `df.in_workflow` independently). Pass this pool both to polling callers (as `&PgPool`) and into `initialize_duroxide_runtime()`.

- **`src/worker.rs`** — `initialize_duroxide_runtime()`: Remove the activity pool creation block (`worker.rs:428-450`). Instead, receive the management pool as a parameter and pass it to `create_activity_registry()`. This means the management pool is created once in the outer loop and reused across init retries.

- **`src/worker.rs`** — `initialize_duroxide_runtime()`: Before creating `PostgresProvider`, set the `DUROXIDE_PG_POOL_MAX` env var to the `max_duroxide_connections` GUC value using `std::env::set_var()`. This is safe in Rust 2021 edition (current); add a code comment noting it becomes `unsafe` in edition 2024. The BGW is single-threaded, so there are no concurrent readers.

- **`src/client.rs`** — `get_duroxide_client()`: Before creating the backend `PostgresProvider` (`client.rs:79-80`), set `DUROXIDE_PG_POOL_MAX` to `"1"`. The backend runtime is also single-threaded (`new_current_thread` at `client.rs:57`); same edition 2024 note applies.

- **`src/registry.rs`** — `create_activity_registry()`: No signature change needed yet — the `Arc<PgPool>` parameter now receives the management pool instead of the activity pool.

### Success Criteria:

#### Automated Verification:
- [x] `cargo build --features pg17` compiles without warnings
- [x] `cargo clippy --features pg17` passes
- [x] `./scripts/test-unit.sh` passes
- [x] `./scripts/test-e2e-local.sh` passes (all existing tests — validates consolidation is correct)
- [x] `./scripts/test-upgrade.sh` passes (backward compat — no schema changes)

#### Manual Verification:
- [x] Worker log shows management pool creation with configured size (not separate polling + activity)
- [x] `pg_stat_activity` shows expected connection counts: management pool connections + duroxide pool connections (no extra polling/activity pools)
- [x] Backend `df.start()` creates only 1 provider connection (not 10)

---

## Phase 3: User-Execution Backpressure

### Changes Required:

- **`src/worker.rs`** — `initialize_duroxide_runtime()`: Create a `Arc<tokio::sync::Semaphore>` sized by `max_user_connections` GUC. Pass it to `create_activity_registry()` alongside the management pool.

- **`src/registry.rs`** — `create_activity_registry()`: Add `semaphore: Arc<Semaphore>` parameter. Clone it into the `execute_sql` closure alongside the pool. Other activity closures are unchanged.

- **`src/activities/execute_sql.rs`** — `execute()`: Change the `_pool: Arc<PgPool>` parameter to `semaphore: Arc<Semaphore>` (or add it as a new parameter). Before calling `connect_as_user()`, acquire a permit with `tokio::time::timeout(duration, semaphore.acquire())`. On timeout, return an `Err` with a descriptive message including the configured limit and timeout. The permit is held for the duration of the SQL execution and automatically released when dropped (when the function returns).

- **`src/types.rs`**: Add a helper `get_execution_acquire_timeout() -> Duration` that reads the GUC and returns a `std::time::Duration`.

- **Error message format**: `"pg_durable: connection limit reached (max_user_connections={limit}). Timed out after {timeout}s waiting for an available execution slot."`

### Success Criteria:

#### Automated Verification:
- [x] `cargo build --features pg17` compiles without warnings
- [x] `cargo clippy --features pg17` passes
- [x] `./scripts/test-unit.sh` passes
- [x] `./scripts/test-e2e-local.sh` passes (existing tests work within default limits)

#### Manual Verification:
- [ ] With `max_user_connections = 1`, two concurrent long-running SQL nodes serialize (second waits for first)
- [ ] With `max_user_connections = 1` and `execution_acquire_timeout = 2`, a blocked execution fails after ~2 seconds with the expected error message
- [ ] The error message appears in the workflow instance status

---

## Phase 4: E2E Tests

### Changes Required:

- **Test harness**: Connection-limit E2E tests require non-default Postmaster GUCs, so they need a dedicated test script (`scripts/test-connlimit-e2e.sh`) that:
  1. Writes specific GUC values to `postgresql.conf`
  2. Restarts the PG server
  3. Runs the connection-limit SQL tests
  4. Restores defaults and restarts
  This script is invoked separately from the main `test-e2e-local.sh` suite. The defaults test runs as part of the regular suite (no GUC changes needed).

- **`.github/workflows/ci.yml`**: Add a step to run `./scripts/test-connlimit-e2e.sh` after the existing E2E test step. This ensures connection-limit tests run in CI alongside the standard suite.

- **`tests/e2e/sql/NN_connection_limit_backpressure.sql`**: Test that backpressure works. Runs under `max_user_connections = 2`. Start 3+ concurrent workflows each executing a `pg_sleep(5)` SQL node. Verify all complete successfully (backpressure queues the extras, doesn't fail them).

- **`tests/e2e/sql/NN_connection_limit_timeout.sql`**: Test the timeout path. Runs under `max_user_connections = 1` and `execution_acquire_timeout = 2`. Start two workflows — one with `pg_sleep(10)` and one with a short SQL. Verify the second workflow's SQL node fails with the expected timeout error in its status.

- **`tests/e2e/sql/NN_connection_limit_defaults.sql`**: Verify default GUC values by running several concurrent workflows under defaults and confirming they all succeed. This test runs in the standard `test-e2e-local.sh` suite (no custom GUCs needed).

- **`tests/e2e/sql/NN_connection_limit_startup_validation.sql`**: Runs under `max_duroxide_connections = 1` (below minimum 2). Verify via `df.is_ready()` that the worker never reaches ready state, confirming startup validation rejects invalid GUC values (FR-010).

### Success Criteria:

#### Automated Verification:
- [ ] `./scripts/test-connlimit-e2e.sh` passes (backpressure, timeout, startup validation tests)
- [ ] `./scripts/test-e2e-local.sh NN_connection_limit_defaults` passes
- [ ] `./scripts/test-e2e-local.sh` full suite passes (regression)

#### Manual Verification:
- [ ] Backpressure test shows queued executions completing after earlier ones finish
- [ ] Timeout test shows clear error message in failed workflow status
- [ ] Startup validation test confirms worker rejects invalid GUC values (FR-010)

---

## Phase 5: Documentation

### Changes Required:
- **`.paw/work/connection-limits/Docs.md`**: Technical reference (load `paw-docs-guidance`)
- **`USER_GUIDE.md`**: Add "Connection Limits" section documenting:
  - The four GUCs with descriptions, defaults, and valid ranges
  - The connection budget formula: `management + duroxide + user + (backends × 1)`
  - Interaction with PostgreSQL's per-role `CONNECTION LIMIT`
  - Example configurations for small/medium/large deployments
- **`CHANGELOG.md`**: Add entry for the new feature

### Success Criteria:
- [ ] Content accurate and consistent with implementation
- [ ] Style consistent with existing USER_GUIDE.md sections
- [ ] Connection budget formula matches actual behavior

---

## References
- Spec: `.paw/work/connection-limits/Spec.md`
- Spec Research: `.paw/work/connection-limits/SpecResearch.md`
- Code Research: `.paw/work/connection-limits/CodeResearch.md`
