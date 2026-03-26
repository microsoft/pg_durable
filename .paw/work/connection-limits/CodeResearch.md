---
date: 2025-07-22T12:00:00Z
git_commit: 1dbf3110437a89de65bfb5d28f99f3fb1c089b40
branch: pinodeca/connection-limits
repository: microsoft/pg_durable
topic: "Connection limits: GUC registration, pool creation, provider sizing, user-execution control"
tags: [research, codebase, gucs, connection-pools, worker, activities, provider]
status: complete
last_updated: 2025-07-22
---

# Research: Connection Limits Implementation Surface

## Research Question

Where and how does pg_durable create, configure, and consume PostgreSQL connections — in the background worker (polling pool, activity pool, duroxide provider pool, per-execution user connections) and in PG backend sessions (client provider pool)? What are the exact insertion points for GUC-controlled pool sizing, pool consolidation, and semaphore-based backpressure?

## Summary

pg_durable has five distinct connection sources: (1) a 1-connection polling pool in the BGW, (2) a 5-connection activity pool in the BGW, (3) a duroxide provider pool (default 10) in the BGW, (4) unbounded per-execution user connections via `connect_as_user()`, and (5) a per-backend duroxide provider pool (default 10). Two GUCs exist today (`pg_durable.worker_role`, `pg_durable.database`), both `Postmaster`-context strings registered in `_PG_init`. The GUC registration pattern, pool creation sites, provider construction, activity registry, and error handling paths are all documented below with exact file:line references.

## Documentation System

- **Framework**: Plain Markdown (no static site generator)
- **Docs Directory**: `docs/` (28 markdown files — architecture, specs, proposals, testing guides)
- **Navigation Config**: N/A
- **Style Conventions**: Long-form technical specs with inline code blocks; heading levels H2-H4; code fences with language tags
- **Build Command**: N/A
- **Standard Files**: `README.md` (root), `USER_GUIDE.md` (root), `CHANGELOG.md` (root), `SECURITY.md` (root), `TODO.md` (root)

## Verification Commands

- **Build**: `cargo build --features pg17` or `make build`
- **Unit Tests**: `./scripts/test-unit.sh` (invokes `cargo pgrx test pg17`)
- **E2E Tests**: `./scripts/test-e2e-local.sh` (all); `./scripts/test-e2e-local.sh 04_parallel` (filtered)
- **Upgrade Tests**: `./scripts/test-upgrade.sh`
- **Lint**: `cargo clippy --features pg17`
- **Format**: `cargo fmt` / `cargo fmt --check`
- **All Tests**: `./scripts/test-all-local.sh`

## Detailed Findings

### 1. Existing GUC Infrastructure

#### GUC Declarations

Two GUCs exist, both declared as statics in `src/lib.rs`:

| GUC | Type | Default | Declaration |
|-----|------|---------|-------------|
| `pg_durable.worker_role` | `GucSetting<Option<CString>>` | `Some(c"azuresu")` | `src/lib.rs:14-15` |
| `pg_durable.database` | `GucSetting<Option<CString>>` | `Some(c"postgres")` | `src/lib.rs:17-18` |

#### GUC Registration

Both are registered in `_PG_init()` at `src/lib.rs:47-74` using `GucRegistry::define_string_guc()`:

- `pg_durable.worker_role` registered at `src/lib.rs:55-62`
- `pg_durable.database` registered at `src/lib.rs:64-71`

Registration pattern for each:
```rust
GucRegistry::define_string_guc(
    c"pg_durable.<name>",           // GUC name (C string literal)
    c"<description>",               // short description
    c"",                            // long description
    &<STATIC>,                      // reference to GucSetting static
    GucContext::Postmaster,          // context
    GucFlags::default(),            // flags
);
```

Both use `GucContext::Postmaster` — the only context variant used in the codebase.

#### GUC Reading Pattern

GUC values are read via `.get()` on the static, wrapped in helper functions:

- `get_worker_role()` at `src/types.rs:19-24` — calls `crate::WORKER_ROLE.get()`, fallback `"azuresu"`
- `get_database()` at `src/types.rs:28-33` — calls `crate::DATABASE.get()`, fallback `"postgres"`

Call sites of these helpers:
- `postgres_connection_string()` at `src/types.rs:52-53` — calls both
- `target_database()` at `src/types.rs:71-72` — calls `get_database()`
- `connect_as_user()` at `src/types.rs:85` — calls `target_database()`
- SQL-level fallback at `src/lib.rs:213-215` — uses `current_setting('pg_durable.worker_role', true)`

#### Integer GUC Pattern (for new GUCs)

pgrx 0.16.1 provides `GucRegistry::define_int_guc()` for `i32` GUCs. A reference pattern appears in `docs/spec-security-model.md:779-795` (spec-only, not shipped code):
```rust
GucRegistry::define_int_guc(
    "df.http_timeout_seconds",
    "Timeout for HTTP requests in seconds",
    30,     // default
    1,      // min
    300,    // max
    GucContext::Suset,
);
```

The corresponding static type is `GucSetting<i32>`.

#### `_PG_init` Function

Defined at `src/lib.rs:47-74`. Sequence:
1. Validates `shared_preload_libraries` loading (`src/lib.rs:49-53`)
2. Registers string GUCs (`src/lib.rs:55-71`)
3. Calls `worker::register_background_worker()` (`src/lib.rs:73`)

New integer GUCs would be added between steps 2 and 3, after the existing string GUC registrations.

#### pgrx Version

`pgrx = "=0.16.1"` at `Cargo.toml:29`.

### 2. Background Worker Pool Creation

#### Tokio Runtime

Created at `src/worker.rs:62-71`:
```rust
tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
```
Single-threaded cooperative runtime. The runtime's `block_on` drives `run_duroxide_runtime()` at `src/worker.rs:73-75`. Shutdown timeout of 5 seconds at `src/worker.rs:77`.

#### Polling Pool

- **Created at**: `src/worker.rs:99-118` inside `run_duroxide_runtime()`
- **Size**: `max_connections(1)` at `src/worker.rs:104-105`
- **No `after_connect` hook**
- **Not wrapped in `Arc`** — owned as a local `PgPool`
- **Retry loop**: On failure, logs and sleeps 5 seconds (`src/worker.rs:110-117`). Checks `is_shutdown_requested()` before each attempt (`src/worker.rs:100-103`).
- **Closed at**: `src/worker.rs:167` (`poll_pool.close().await`)

#### Polling Pool Callers (all receive `&sqlx::PgPool`)

| Function | Location | Purpose |
|----------|----------|---------|
| `wait_for_extension_creation()` | `src/worker.rs:170-186` | Polls for `CREATE EXTENSION` |
| `check_extension_exists()` | `src/worker.rs:188-195` | Checks `pg_extension` catalog |
| `check_duroxide_schema_owned()` | `src/worker.rs:202-220` | Verifies schema ownership via `pg_depend` |
| `release_extension_owned_duroxide_objects()` | `src/worker.rs:231-334` | De-registers extension-owned duroxide objects |
| `has_extension_owned_duroxide_objects()` | `src/worker.rs:340-369` | Checks for remaining extension-owned objects |
| `initialize_duroxide_runtime()` | `src/worker.rs:371-460` | Full init sequence (receives poll_pool for checks) |
| `write_epoch_sentinel()` | `src/worker.rs:465-475` | Writes epoch sentinel to `df._worker_epoch` |
| `write_worker_ready()` | `src/worker.rs:485-519` | Writes readiness record to `duroxide._worker_ready` |
| `check_epoch_sentinel()` | `src/worker.rs:526-537` | Checks epoch sentinel still exists |
| `run_until_extension_dropped_or_shutdown()` | `src/worker.rs:539-576` | Main monitoring loop |

#### Activity Pool

- **Created at**: `src/worker.rs:428-450` inside `initialize_duroxide_runtime()`
- **Size**: `max_connections(5)` at `src/worker.rs:428-429`
- **`after_connect` hook**: `src/worker.rs:430-437` — sets `SET df.in_workflow = 'true'`
- **Wrapped in `Arc<PgPool>`** at `src/worker.rs:441`
- **Retry behavior**: On failure, logs and sleeps `retry_interval` (1 second), then `continue`s the init loop (`src/worker.rs:442-449`)
- **Passed to registry**: `create_activity_registry(pg_pool)` at `src/worker.rs:452`

#### Activity Pool Callers (all receive `Arc<PgPool>`)

| Activity | Location | Uses Pool? |
|----------|----------|------------|
| `execute_sql` | `src/activities/execute_sql.rs:28-32` | No (`_pool: Arc<PgPool>` — ignored) |
| `load_function_graph` | `src/activities/load_function_graph.rs:20-24` | Yes — `pool.as_ref()` for queries |
| `update_instance_status` | `src/activities/update_instance_status.rs:11-15` | Yes — `pool.as_ref()` for queries |
| `update_node_status` | `src/activities/update_node_status.rs:11-15` | Yes — `pool.as_ref()` for queries |
| `execute_http` | `src/activities/execute_http.rs:38` | No pool parameter at all |

#### Consolidation Opportunity: Polling + Activity Pools

**Same**: Both pools connect to the same host/database/role via `postgres_connection_string()` (`src/types.rs:48-56`). Both use `sqlx::postgres::PgPoolOptions::new()`.

**Different**:
- Polling: `max_connections(1)`, no `after_connect`, not `Arc`-wrapped, created with 5s retry
- Activity: `max_connections(5)`, has `after_connect` that sets `df.in_workflow`, `Arc`-wrapped, created with 1s retry

The `df.in_workflow` hook on the activity pool is redundant for the consolidation — `connect_as_user()` at `src/types.rs:121-124` independently sets this flag on every user-execution connection, and the management pool connections (used by `load_function_graph`, `update_instance_status`, `update_node_status`) execute internal queries that never invoke DSL functions.

### 3. Duroxide Provider Pool Sizing

#### `DUROXIDE_PG_POOL_MAX` Environment Variable

Read at `duroxide-pg-opt/src/provider.rs:146-149`:
```rust
let max_connections = std::env::var("DUROXIDE_PG_POOL_MAX")
    .ok()
    .and_then(|s| s.parse::<u32>().ok())
    .unwrap_or(10);
```
Default is 10. Used immediately in pool options at `duroxide-pg-opt/src/provider.rs:151-156`:
```rust
PgPoolOptions::new()
    .max_connections(max_connections)
    .min_connections(1)
    .acquire_timeout(Duration::from_secs(30))
    .connect(database_url)
```

#### ProviderConfig Struct

Defined at `duroxide-pg-opt/src/provider.rs:43-52`:
```rust
pub struct ProviderConfig {
    pub schema_name: Option<String>,
    pub long_poll: LongPollConfig,
    pub migration_policy: MigrationPolicy,
}
```
Marked `#[non_exhaustive]` at `duroxide-pg-opt/src/provider.rs:41`.

**No field for max_connections.** Pool size is only controllable via the `DUROXIDE_PG_POOL_MAX` env var. To set this from pg_durable, `std::env::set_var("DUROXIDE_PG_POOL_MAX", value)` must be called before `PostgresProvider::new_with_config()`.

#### Provider Construction (Worker)

At `src/worker.rs:415-416`:
```rust
PostgresProvider::new_with_config(pg_conn_str, worker_provider_config()).await
```
Wrapped in `Arc` at `src/worker.rs:417`. On failure, retries in the init loop (`src/worker.rs:418-425`).

The `worker_provider_config()` at `src/types.rs:151-156` sets:
- `schema_name = Some("duroxide")`
- `migration_policy = ApplyAll`
- `long_poll` left at default (enabled)

#### Provider Construction (Backend)

At `src/client.rs:79-80`:
```rust
PostgresProvider::new_with_config(&pg_conn_str, backend_provider_config())
```
The `backend_provider_config()` at `src/types.rs:136-142` sets:
- `schema_name = Some("duroxide")`
- `migration_policy = VerifyOnly`
- `long_poll.enabled = false`

**Both worker and backend providers use the same `DUROXIDE_PG_POOL_MAX` env var.** To set different pool sizes for worker vs backend, the env var must be set/reset between the two construction calls.

#### PostgresProvider Internal Pool Sharing

The provider stores its pool as `Arc<PgPool>` at `duroxide-pg-opt/src/provider.rs:118`:
```rust
pool: Arc<PgPool>,
```
Shared with:
- `MigrationRunner` at `duroxide-pg-opt/src/provider.rs:165`
- `Notifier` at `duroxide-pg-opt/src/provider.rs:181` (receives `pool.clone()`)
- `PgListener` at `duroxide-pg-opt/src/notifier.rs:134`: `PgListener::connect_with(&pool)` — creates a dedicated listener connection from the pool

### 4. User-Execution Connection Control

#### `connect_as_user()` Function

Defined at `src/types.rs:77-127`.

Signature:
```rust
pub async fn connect_as_user(
    login_role: &str,
    effective_role: &str,
    database: Option<&str>,
) -> Result<sqlx::postgres::PgConnection, String>
```

Steps:
1. Build `PgConnectOptions` with `username`, `database`, `port`, optionally `host` (`src/types.rs:87-95`)
2. `PgConnection::connect_with(&options)` — creates a raw TCP connection, **not pooled** (`src/types.rs:97-104`)
3. `SET ROLE` if `login_role != effective_role` (`src/types.rs:107-114`)
4. `SET df.in_workflow = 'true'` (`src/types.rs:121-124`)

#### Callers of `connect_as_user()`

Only one caller: `execute_sql` activity at `src/activities/execute_sql.rs:49-54`:
```rust
let mut conn = connect_as_user(
    &input.login_role,
    &input.submitted_by,
    input.database.as_deref(),
).await?;
```
The `conn` is used for `fetch_all` at `src/activities/execute_sql.rs:56`, then dropped when the function returns (connection closed).

#### Where to Place the Semaphore

The activity registry at `src/registry.rs:12-39` already captures `Arc<PgPool>` in closures. An `Arc<tokio::sync::Semaphore>` can be captured the same way — cloned into the `execute_sql` closure alongside (or instead of) the pool.

Current closure pattern at `src/registry.rs:19-22`:
```rust
.register(activities::execute_sql::NAME, move |ctx: ActivityContext, input_json: String| {
    let pool = sql_pool.clone();
    async move { activities::execute_sql::execute(ctx, pool, input_json).await }
})
```

The semaphore would be created in `create_activity_registry()` (or passed in as a parameter), cloned into the closure, and acquired inside `execute_sql::execute()` before calling `connect_as_user()`.

The `execute()` function signature at `src/activities/execute_sql.rs:28-32` currently receives `_pool: Arc<PgPool>` which it ignores. This parameter could be replaced with or augmented by `Arc<Semaphore>`.

#### Activity Registry Structure

Defined at `src/registry.rs:12-39`:
```rust
pub fn create_activity_registry(pool: Arc<PgPool>) -> ActivityRegistry
```

Creates per-activity pool clones at `src/registry.rs:13-16`:
```rust
let sql_pool = pool.clone();
let graph_pool = pool.clone();
let status_pool = pool.clone();
let node_status_pool = pool.clone();
```

Then builds the registry with chained `.register()` calls. Each closure captures its clone and re-clones per invocation.

The `ActivityRegistry::builder()` and `.register()` API is from `duroxide::runtime::registry::ActivityRegistry` (`src/registry.rs:5`).

#### Closure Signature for Activities

```rust
move |ctx: ActivityContext, input: String| -> impl Future<Output = Result<String, String>>
```

(`ActivityContext` from `duroxide::ActivityContext` at `src/registry.rs:5`)

### 5. Backend Provider Pool

#### Backend Client Module

`src/client.rs` provides cached client infrastructure for PG backend sessions.

Statics:
- `CLIENT_RUNTIME: OnceLock<Runtime>` at `src/client.rs:16`
- `DUROXIDE_CLIENT: OnceLock<Client>` at `src/client.rs:19`

Client initialization at `src/client.rs:64-90`:
1. Checks `is_worker_ready()` (`src/client.rs:69-73`) via SPI read of `duroxide._worker_ready`
2. Creates `PostgresProvider::new_with_config(&pg_conn_str, backend_provider_config())` at `src/client.rs:79-80`
3. Stores `Client::new(store)` in `DUROXIDE_CLIENT` at `src/client.rs:85`

**Pool size**: Determined solely by `DUROXIDE_PG_POOL_MAX` env var (default 10). Neither `src/client.rs` nor `backend_provider_config()` set max_connections.

The `OnceLock` means the client (and its pool) lives for the entire backend process lifetime.

#### Backend Operations

All are lightweight queue-insert operations using `block_on()`:
- `start_durable_function()` at `src/client.rs:93-113`
- `cancel_durable_function()` at `src/client.rs:116-127`
- `raise_external_event()` at `src/client.rs:130-141`

### 6. Error Handling Patterns

#### Worker Pool Creation Retry Loops

All pool/provider creations in the BGW use retry loops:

| Creation | Location | Retry Interval | Behavior |
|----------|----------|----------------|----------|
| Polling pool | `src/worker.rs:99-118` | 5 seconds | Logs, sleeps, retries; exits on shutdown |
| Provider | `src/worker.rs:415-425` | `retry_interval` (1s) | Logs, sleeps, `continue`s init loop |
| Activity pool | `src/worker.rs:428-449` | `retry_interval` (1s) | Logs, sleeps, `continue`s init loop |

The init loop at `src/worker.rs:378-460` checks shutdown and extension existence on each iteration before retrying.

#### Activity Error Propagation

Activities return `Result<String, String>`. Error propagation:
- `execute_sql`: JSON parse failure → `Err(String)` at `src/activities/execute_sql.rs:33-34`; connection failure → `Err(String)` from `connect_as_user` at `src/activities/execute_sql.rs:49-54`; SQL failure → `Err(String)` at `src/activities/execute_sql.rs:92-96`
- Other activities: sqlx errors are stringified and returned as `Err(String)`

No retry logic is configured in the activity registry (`src/registry.rs`). Duroxide handles activity failures at the runtime level.

#### Worker Shutdown

- `is_shutdown_requested()` at `src/worker.rs:45-49` reads PostgreSQL's `ShutdownRequestPending`
- Signal handlers attached at `src/worker.rs:55` (`SIGHUP | SIGTERM`)
- Monitoring loop uses `tokio::select!` at `src/worker.rs:552-570` — checks shutdown every 1 second
- Duroxide runtime shutdown with 10s timeout at `src/worker.rs:574`
- Tokio runtime shutdown with 5s timeout at `src/worker.rs:77`

### 7. Tokio Dependency and Features

`Cargo.toml:37`:
```toml
tokio = { version = "1", features = ["rt-multi-thread", "sync", "time"] }
```

The `sync` feature is already enabled, which includes `tokio::sync::Semaphore`. No additional Cargo.toml changes are needed for the backpressure semaphore.

### 8. Worker Main Loop Structure

`src/worker.rs` high-level flow:

1. **`register_background_worker()`** (`src/worker.rs:33-41`) — called from `_PG_init`
2. **`duroxide_worker_main()`** (`src/worker.rs:54-79`) — BGW entry point; attaches signals, inits tracing, creates tokio runtime, calls `run_duroxide_runtime()`
3. **`run_duroxide_runtime()`** (`src/worker.rs:82-168`) — outer loop:
   - Creates polling pool with retry (`src/worker.rs:99-118`)
   - Waits for `CREATE EXTENSION` (`src/worker.rs:126`)
   - Calls `initialize_duroxide_runtime()` (`src/worker.rs:130-131`)
   - Writes worker-ready record (`src/worker.rs:140`)
   - Writes epoch sentinel (`src/worker.rs:146`)
   - Calls `run_until_extension_dropped_or_shutdown()` (`src/worker.rs:157-164`)
   - Closes polling pool on exit (`src/worker.rs:167`)
4. **`initialize_duroxide_runtime()`** (`src/worker.rs:371-460`) — inner init loop:
   - Verifies extension exists (`src/worker.rs:384-387`)
   - Verifies schema ownership (`src/worker.rs:389-396`)
   - Releases extension-owned objects if needed (`src/worker.rs:404-412`)
   - Creates duroxide provider (`src/worker.rs:415-426`)
   - Creates activity pool (`src/worker.rs:428-450`)
   - Creates activity & orchestration registries (`src/worker.rs:452-453`)
   - Starts duroxide runtime (`src/worker.rs:455-456`)

## Code References

### GUC Infrastructure
- `src/lib.rs:14-15` — `WORKER_ROLE` GUC static declaration
- `src/lib.rs:17-18` — `DATABASE` GUC static declaration
- `src/lib.rs:47-74` — `_PG_init()` function (GUC registration + worker init)
- `src/lib.rs:55-62` — `pg_durable.worker_role` GUC registration
- `src/lib.rs:64-71` — `pg_durable.database` GUC registration
- `src/types.rs:19-24` — `get_worker_role()` helper
- `src/types.rs:28-33` — `get_database()` helper

### Pool Creation
- `src/worker.rs:99-118` — Polling pool creation (retry loop, max_connections=1)
- `src/worker.rs:104-105` — Polling pool `max_connections(1)`
- `src/worker.rs:428-450` — Activity pool creation (retry loop, max_connections=5, after_connect)
- `src/worker.rs:428-429` — Activity pool `max_connections(5)`
- `src/worker.rs:430-437` — Activity pool `after_connect` hook (`SET df.in_workflow`)
- `src/worker.rs:441` — Activity pool `Arc::new(pool)`
- `src/worker.rs:452` — Activity pool passed to `create_activity_registry()`

### Provider
- `src/worker.rs:415-416` — Worker provider creation
- `src/worker.rs:417` — Provider `Arc::new()`
- `src/client.rs:79-80` — Backend provider creation
- `src/types.rs:136-142` — `backend_provider_config()` (VerifyOnly, long_poll disabled)
- `src/types.rs:151-156` — `worker_provider_config()` (ApplyAll, long_poll enabled)
- `duroxide-pg-opt/src/provider.rs:43-52` — `ProviderConfig` struct definition
- `duroxide-pg-opt/src/provider.rs:145-156` — `new_with_config()` pool creation (reads `DUROXIDE_PG_POOL_MAX`)
- `duroxide-pg-opt/src/provider.rs:118` — Provider internal `pool: Arc<PgPool>`
- `duroxide-pg-opt/src/notifier.rs:134` — `PgListener::connect_with(&pool)` (listener from provider pool)

### User-Execution Connections
- `src/types.rs:77-127` — `connect_as_user()` full function
- `src/types.rs:97-104` — Raw `PgConnection::connect_with()` (not pooled)
- `src/types.rs:107-114` — `SET ROLE` logic
- `src/types.rs:121-124` — `SET df.in_workflow = 'true'`
- `src/activities/execute_sql.rs:14` — `NAME` constant
- `src/activities/execute_sql.rs:28-32` — `execute()` signature (`_pool: Arc<PgPool>` ignored)
- `src/activities/execute_sql.rs:49-54` — `connect_as_user()` call site

### Activity Registry
- `src/registry.rs:12-39` — `create_activity_registry()` function
- `src/registry.rs:13-16` — Per-activity pool clones
- `src/registry.rs:19-22` — `execute_sql` closure registration
- `src/registry.rs:42-53` — `create_orchestration_registry()` function

### Backend Client
- `src/client.rs:16` — `CLIENT_RUNTIME: OnceLock<Runtime>`
- `src/client.rs:19` — `DUROXIDE_CLIENT: OnceLock<Client>`
- `src/client.rs:54-61` — `get_client_runtime()` (single-threaded tokio)
- `src/client.rs:64-90` — `get_duroxide_client()` (lazy provider + client creation)

### Error Handling
- `src/worker.rs:99-118` — Polling pool retry loop
- `src/worker.rs:415-425` — Provider creation retry
- `src/worker.rs:428-449` — Activity pool creation retry
- `src/activities/execute_sql.rs:92-96` — SQL error stringification

### Shutdown
- `src/worker.rs:45-49` — `is_shutdown_requested()`
- `src/worker.rs:55` — Signal handlers (SIGHUP | SIGTERM)
- `src/worker.rs:539-576` — `run_until_extension_dropped_or_shutdown()`
- `src/worker.rs:574` — Duroxide runtime shutdown (10s timeout)

## Architecture Documentation

### Connection String Pattern
All pools and connections use `postgres_connection_string()` (`src/types.rs:48-56`) which builds `postgres://{worker_role}@{host}:{port}/{database}` from GUC values and environment. No password is included — authentication relies on trust/peer methods.

### Activity Registration Pattern
Activities are registered in `src/registry.rs` using `ActivityRegistry::builder().register(NAME, closure).build()`. Each closure captures an `Arc<PgPool>` clone and re-clones it per invocation. The closure signature is `move |ctx: ActivityContext, input: String| -> impl Future<Output = Result<String, String>>`. Shared state (such as a semaphore) can be captured in the same pattern.

### Pool Lifecycle in BGW Init
The init loop at `src/worker.rs:378-460` creates three resources sequentially: provider → activity pool → registries → runtime. If any creation fails, the loop sleeps 1 second and retries from the top (rechecking extension existence and shutdown). This means all three resources are recreated together on failure.

### Connection Architecture (Current State)

```
Background Worker (single-threaded tokio)
├── Polling Pool: 1 connection (extension lifecycle checks)
│   └── Created at worker.rs:99-118, passed as &PgPool
├── Activity Pool: 5 connections (graph loading, status updates)
│   └── Created at worker.rs:428-450, passed as Arc<PgPool> via registry
├── Duroxide Provider Pool: 10 connections (orchestration state + LISTEN/NOTIFY)
│   └── Created inside PostgresProvider at provider.rs:145-156
│   └── PgListener uses 1 connection from this pool (notifier.rs:134)
└── Per-execution User Connections: UNBOUNDED
    └── Created per-invocation by connect_as_user() at types.rs:97-104

PG Backend (per-session, OnceLock cached)
└── Duroxide Provider Pool: 10 connections (queue inserts)
    └── Created at client.rs:79-80, no listener (long_poll disabled)
```

## Open Questions

1. **pgrx `define_int_guc` exact signature for 0.16.1**: The `docs/spec-security-model.md` shows a 7-parameter form `(name, desc, default, min, max, context)`, but the actual pgrx 0.16.1 API may differ slightly (e.g., `GucFlags` parameter). The codebase's `define_string_guc` calls include the flags parameter. Verify during implementation by checking compiler errors or pgrx docs.

2. **`std::env::set_var` safety in pgrx context**: Setting `DUROXIDE_PG_POOL_MAX` via `std::env::set_var()` before provider construction is the only mechanism to control provider pool size without modifying the submodule. In Rust 2024 edition, `set_var` is unsafe. Verify the current edition and whether this is acceptable (the BGW is single-threaded, so race conditions are not a concern).

3. **Duroxide runtime concurrency configuration**: The spec mentions duroxide has `max_concurrent`, `orch_concurrency`, and `worker_concurrency` parameters (visible in stress tests at `duroxide-pg-opt/tests/stress_tests.rs:630-646`). pg_durable does not currently set these. The planner may want to note this as a future consideration, though it is out of scope for this feature.
