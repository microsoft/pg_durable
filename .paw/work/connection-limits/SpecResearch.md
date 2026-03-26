# Spec Research: Connection Limits

## Q1: PG Backend sqlx Usage

**Finding: PG backends do NOT use sqlx directly for DSL operations.** The DSL (`src/dsl.rs`) uses PostgreSQL SPI (Server Programming Interface) for all catalog operations — inserting rows into `df.nodes`, `df.instances`, etc. There are zero `sqlx::` imports or usages in `src/dsl.rs` or `src/lib.rs` for user-facing SQL functions.

However, **PG backends DO create a duroxide `PostgresProvider` (which owns a sqlx pool) for client operations**:

- **Cached client infrastructure**: `src/client.rs:15-19` — Two `OnceLock` statics cache a Tokio runtime and a Duroxide `Client` per backend process (one per postmaster fork).
- **Runtime**: `src/client.rs:54-61` — `get_client_runtime()` creates a single-threaded Tokio runtime (`new_current_thread()`), cached in `OnceLock`.
- **Client creation**: `src/client.rs:64-90` — `get_duroxide_client()` lazily creates a `PostgresProvider` via:
  ```rust
  PostgresProvider::new_with_config(&pg_conn_str, backend_provider_config())
  ```
  This provider owns its own sqlx `PgPool` (default max 10 connections via `DUROXIDE_PG_POOL_MAX`).
- **Backend config**: `src/types.rs:136-142` — `backend_provider_config()` sets:
  - `migration_policy = VerifyOnly` (never creates/alters schema)
  - `long_poll.enabled = false` (no dedicated LISTEN connection)
- **Lifetime**: The `OnceLock` means the `Client` (and its pool) lives for the entire backend process lifetime (until the session disconnects or the process is recycled).
- **Usage**: `src/client.rs:93-141` — Used by `start_durable_function()`, `cancel_durable_function()`, and `raise_external_event()` — all called via `block_on()` on the cached runtime.

**Key implication**: Each PG backend session that calls `df.start()`, `df.cancel()`, or `df.signal()` creates its own duroxide `PostgresProvider` with its own pool of up to 10 sqlx connections. These pools are **not shared** between backend sessions. If 50 user sessions call `df.start()`, up to 50 × 10 = 500 sqlx connections could theoretically exist (though in practice each backend likely uses far fewer than 10 simultaneously).

## Q2: Background Worker Connection Management

The background worker (`src/worker.rs`) manages **three distinct connection constructs**:

### 2a. Polling Pool (1 connection)

- **Created at**: `src/worker.rs:99-118`
- **Pool size**: `max_connections(1)` — `src/worker.rs:105`
- **Purpose**: Extension-existence polling, epoch sentinel checks, worker readiness writes
- **Lifecycle**: Created at worker startup, retries indefinitely until success, closed at `src/worker.rs:167` on shutdown
- **Used by**:
  - `wait_for_extension_creation()` — `src/worker.rs:126`
  - `check_extension_exists()` — `src/worker.rs:170-195`
  - `check_duroxide_schema_owned()` — `src/worker.rs:202-221`
  - `release_extension_owned_duroxide_objects()` — `src/worker.rs:231-334`
  - `write_epoch_sentinel()` — `src/worker.rs:146`
  - `write_worker_ready()` — `src/worker.rs:140`
  - `run_until_extension_dropped_or_shutdown()` — `src/worker.rs:157-164`

### 2b. Activity Pool (5 connections)

- **Created at**: `src/worker.rs:428-450`
- **Pool size**: `max_connections(5)` — `src/worker.rs:429`
- **`after_connect` hook**: `src/worker.rs:430-437` — Every new connection runs `SET df.in_workflow = 'true'`
- **Purpose**: Shared by all activities (except `execute_sql` which creates its own connections) via `Arc<PgPool>`
- **Injection**: `src/worker.rs:452` → `create_activity_registry(pg_pool)` → `src/registry.rs:12-39`
- **Used by**:
  - `load_function_graph` — `src/activities/load_function_graph.rs:20-24` — reads `df.instances` and `df.nodes`
  - `update_instance_status` — `src/activities/update_instance_status.rs:11-15` — updates `df.instances`
  - `update_node_status` — `src/activities/update_node_status.rs:11-15` — updates `df.nodes`
  - `execute_sql` — `src/activities/execute_sql.rs:30` — receives pool but **does not use it** (`_pool: Arc<PgPool>`)

### 2c. Duroxide Provider Pool (default 10 connections)

- **Created at**: `src/worker.rs:415-426`
- **Pool creation**: Inside `PostgresProvider::new_with_config()` — `duroxide-pg-opt/src/provider.rs:145-156`
- **Pool size**: `DUROXIDE_PG_POOL_MAX` env var, default `10` — `duroxide-pg-opt/src/provider.rs:146-149`
- **Config**: `src/types.rs:151-156` — `worker_provider_config()` sets:
  - `schema_name = "duroxide"`
  - `migration_policy = ApplyAll`
  - `long_poll.enabled = true` (default)
- **Purpose**: Used by the duroxide runtime for orchestration state management (reading/writing orchestration history, activity results, timers, etc.)
- **Lifecycle**: Lives as long as the duroxide runtime (dropped when extension is dropped/recreated or shutdown)

### 2d. Per-execution User Connections (unbounded)

- **Created by**: `connect_as_user()` — `src/types.rs:77-127`
- **Called from**: `execute_sql` activity — `src/activities/execute_sql.rs:49-54`
- **Pool**: **None** — creates a raw `PgConnection` each time, not pooled
- **Lifecycle**: Created per activity execution, dropped when activity function returns
- **Concurrency**: **No limit on concurrent user connections** — see Q5

## Q3: Connection String Construction

**Function**: `postgres_connection_string()` at `src/types.rs:48-56`

**Format**: `postgres://{user}@{host}:{port}/{database}`

**Parameters**:

| Component | Source | Default | Reference |
|-----------|--------|---------|-----------|
| `host` | `PGHOST` env var | `"127.0.0.1"` | `src/types.rs:50` |
| `port` | `pgrx::pg_sys::PostPortNumber` (C global) | PostgreSQL's configured port | `src/types.rs:51` |
| `user` | `pg_durable.worker_role` GUC | `"azuresu"` | `src/types.rs:52` → `src/types.rs:19-24` |
| `database` | `pg_durable.database` GUC | `"postgres"` | `src/types.rs:53` → `src/types.rs:28-33` |

**GUC definitions**: `src/lib.rs:14-18`
- `WORKER_ROLE: GucSetting<Option<CString>>` — default `"azuresu"`
- `DATABASE: GucSetting<Option<CString>>` — default `"postgres"`

**GUC registration**: `src/lib.rs:55-71`
- Both are `GucContext::Postmaster` — can only be set in `postgresql.conf` before server start

**Notable**: No password in the connection string. Authentication relies on `trust`, `peer`, or other passwordless methods. The `connect_as_user()` function (`src/types.rs:87-95`) similarly builds `PgConnectOptions` without a password, using only `username`, `database`, `port`, and `host`.

**Helper functions**:
- `get_host()` — `src/types.rs:59-61`
- `get_port()` — `src/types.rs:64-66`
- `target_database()` — `src/types.rs:70-73` (also exposed as SQL function `df.target_database()`)

## Q4: Duroxide Runtime Connections

**Yes, duroxide-pg-opt maintains its own connection pool, separate from pg_durable's activity pool.**

### Provider Pool

- **Struct**: `PostgresProvider` at `duroxide-pg-opt/src/provider.rs:117-129` — owns `pool: Arc<PgPool>`
- **Pool creation**: `duroxide-pg-opt/src/provider.rs:145-156`:
  ```rust
  PgPoolOptions::new()
      .max_connections(max_connections)  // DUROXIDE_PG_POOL_MAX or 10
      .min_connections(1)
      .acquire_timeout(Duration::from_secs(30))
      .connect(database_url)
  ```
- **Pool sizing**: `DUROXIDE_PG_POOL_MAX` env var, default `10` — `duroxide-pg-opt/src/provider.rs:146-149`, documented at `duroxide-pg-opt/src/lib.rs:41-44`

### Internal Pool Sharing

The provider's pool is shared internally (not with pg_durable's activity pool):
- **MigrationRunner**: `duroxide-pg-opt/src/migrations.rs:19-28` — receives `Arc<PgPool>`, uses `pool.acquire()` for migrations with advisory locks
- **Notifier**: `duroxide-pg-opt/src/notifier.rs:86-124` — receives `PgPool` clone
  - Creates a **dedicated `PgListener` connection** via `PgListener::connect_with(&pool)` — `duroxide-pg-opt/src/notifier.rs:134-135`
  - Uses the pool for refresh queries — `duroxide-pg-opt/src/notifier.rs:352-417`
  - Reconnects listener from pool on failure — `duroxide-pg-opt/src/notifier.rs:468-490`

### Connection Count Summary for BGW

The background worker's duroxide provider pool can hold up to **10 connections** (default) plus **1 dedicated PgListener connection** for LISTEN/NOTIFY. This is separate from:
- The 1-connection polling pool
- The 5-connection activity pool
- Any per-execution `connect_as_user` connections

### Backend Session Provider

Each PG backend that calls `df.start()` also creates a `PostgresProvider` (`src/client.rs:79-83`) with:
- `backend_provider_config()` which disables long-poll (`src/types.rs:140`) — so no PgListener connection
- Default pool size of 10 (via `DUROXIDE_PG_POOL_MAX`)
- This provider is used only for `Client::start_orchestration()`, `cancel_instance()`, `raise_event()` — lightweight queue-insert operations

## Q5: Current Limits and Concurrency Controls

### Connection Pool Limits (the ONLY explicit limits)

| Pool | Max Connections | Location |
|------|----------------|----------|
| BGW polling pool | 1 | `src/worker.rs:105` |
| BGW activity pool | 5 | `src/worker.rs:429` |
| BGW duroxide provider pool | 10 (env `DUROXIDE_PG_POOL_MAX`) | `duroxide-pg-opt/src/provider.rs:146-152` |
| Backend duroxide provider pool | 10 (env `DUROXIDE_PG_POOL_MAX`) | `duroxide-pg-opt/src/provider.rs:146-152` (via `src/client.rs:80`) |
| Per-execution user connections | **UNBOUNDED** | `src/types.rs:97` — raw `PgConnection::connect_with()` |

### Tokio Runtime Configuration

- **BGW runtime**: `src/worker.rs:62-65` — `tokio::runtime::Builder::new_current_thread()` — **single-threaded** event loop. All async tasks run cooperatively on one OS thread.
- **Backend runtime**: `src/client.rs:55-59` — also `new_current_thread()`, cached in `OnceLock`
- **Tokio features**: `Cargo.toml:37` — `["rt-multi-thread", "sync", "time"]` (multi-thread feature is available but not used by either runtime)

### Semaphores / Rate Limiters / Task Limits

**None found.** Exhaustive search for `Semaphore`, `RateLimiter`, `max_tasks`, `task_limit`, `concurrency` yielded no results in production code.

### Duroxide Runtime Concurrency

The duroxide runtime itself (`runtime::Runtime::start_with_store()` at `src/worker.rs:455-456`) likely has its own internal concurrency model for processing orchestrations and activities. From the stress tests:
- `duroxide-pg-opt/tests/stress_tests.rs:630-646` — stress config includes `max_concurrent: 30`, `orch_concurrency: 4`, `worker_concurrency: 4`

These suggest the duroxide runtime has configurable concurrency parameters, but **pg_durable does not currently set them** — it uses whatever defaults duroxide provides.

### SQL-Level Coordination

The SQL schema uses advisory locks and `SKIP LOCKED` for dispatcher coordination:
- `sql/pg_durable--0.1.1.sql:1160-1208` — `pg_advisory_xact_lock(hashtext(v_instance_id))` + `FOR UPDATE OF q SKIP LOCKED`
- This serializes operations on the same instance but allows different instances to process concurrently.

### PostgreSQL-Level Limits

No `max_connections` setting found in `docker-compose.yml:16-21` or any config files in the repo. The system relies on PostgreSQL's default `max_connections` (typically 100).

## Q6: User Isolation Model

### How `connect_as_user` Works

**Definition**: `src/types.rs:77-127`

**Step-by-step**:

1. **Build connection options** (`src/types.rs:87-95`):
   ```rust
   PgConnectOptions::new()
       .username(login_role)    // authenticate as the session's login role
       .database(db)            // target database (or extension's database)
       .port(get_port())        // same port as the PostgreSQL server
       .host(&host)             // PGHOST or 127.0.0.1
   ```

2. **Create a fresh TCP connection** (`src/types.rs:97-104`):
   ```rust
   PgConnection::connect_with(&options).await
   ```
   This is a raw `PgConnection`, **not from any pool**. A new TCP connection is established for every invocation.

3. **SET ROLE if needed** (`src/types.rs:107-115`):
   ```rust
   if login_role != effective_role {
       SET ROLE "effective_role"
   }
   ```
   The connection authenticates as `login_role` (the PostgreSQL session user who has login privilege), then switches to `effective_role` (the user who called `df.start()`, which may be a non-login role obtained via `SET ROLE`).

4. **Set workflow flag** (`src/types.rs:121-124`):
   ```rust
   SET df.in_workflow = 'true'
   ```
   Prevents variable mutations during execution.

5. **Return connection** — caller uses it, then drops it when done.

### Connection Lifecycle

- **Called from**: `src/activities/execute_sql.rs:49-54`
- **One connection per SQL node execution**: Each `execute_sql` activity invocation creates exactly one connection.
- **Dropped after use**: The `conn` variable is local to `execute()` (`src/activities/execute_sql.rs:49`), so it's dropped (and the TCP connection closed) when the function returns at line 98.
- **No reuse**: The connection is not returned to any pool. The next `execute_sql` invocation creates a brand new connection.

### Where user/role info comes from

- `FunctionNode` struct: `src/types.rs:647-661`
  - `submitted_by: String` — the effective role (outer user) — `src/types.rs:655`
  - `login_role: String` — the authenticated role (session user) — `src/types.rs:657`
  - `database: Option<String>` — target database — `src/types.rs:660`
- These are captured at `df.start()` time (via DSL in `src/dsl.rs`) and stored in `df.nodes`, then loaded by `load_function_graph` activity and passed to `execute_sql`.

### Security Implications

- The worker role (`pg_durable.worker_role`, default `azuresu`) is **not** used for SQL execution. User SQL runs as the user's own `login_role` with `SET ROLE` to their `submitted_by` role.
- Authentication is passwordless (peer/trust) since no password is included in `PgConnectOptions`.
- Each user's SQL runs in an isolated connection with proper role context — no connection sharing between different users' queries.

## Summary

### Connection Architecture (BGW steady-state)

```
Background Worker Process (single-threaded tokio)
├── Polling Pool: 1 connection (extension lifecycle checks)
├── Activity Pool: 5 connections (graph loading, status updates)
├── Duroxide Provider Pool: 10 connections (orchestration state)
│   └── PgListener: 1 dedicated connection (LISTEN/NOTIFY)
└── Per-execution connections: UNBOUNDED (one per SQL node execution)
```

**Total steady-state BGW connections**: 1 + 5 + 10 + 1 = **17 pooled connections** + N unpooled per-execution connections

### Per-Backend Session (when df.start/cancel/signal is called)

```
Backend Process (single-threaded tokio, OnceLock cached)
└── Duroxide Provider Pool: 10 connections (queue inserts)
    └── No PgListener (long-poll disabled)
```

### Key Findings for Connection Limits Design

1. **No concurrency controls exist for `connect_as_user`**: Every `execute_sql` activity creates a fresh TCP connection with no pooling, no semaphore, no limit. Under high concurrency, this could exhaust PostgreSQL's `max_connections`.

2. **The activity pool is small (5)**: This limits internal operations (graph loading, status updates) but does NOT limit user SQL execution connections.

3. **The duroxide pool is configurable but not pg_durable-controlled**: `DUROXIDE_PG_POOL_MAX` is an env var owned by duroxide-pg-opt, not a pg_durable GUC.

4. **Backend session pools are per-process and uncapped**: Each PG backend that touches duroxide client ops gets its own 10-connection pool. With many concurrent sessions, this compounds.

5. **Single-threaded tokio runtime**: The BGW uses `new_current_thread()`, meaning all async operations are cooperative on one thread. This provides some natural backpressure but doesn't prevent connection accumulation from concurrent activity executions.

6. **No explicit duroxide runtime concurrency configuration**: pg_durable doesn't set `max_concurrent`, `orch_concurrency`, or `worker_concurrency` on the duroxide runtime — it uses defaults, which are unknown without checking duroxide source.
