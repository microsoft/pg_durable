# pg_durable Extension Lifecycle and Background Worker

**Status:** Implemented  
**Last Updated:** 2026-03-01  
**Dependencies:** duroxide-pg-opt (git submodule)

> **Note:** This document describes the extension lifecycle management, background worker behavior, and duroxide-pg-opt schema integration in pg_durable.

## Problem Statement

Historically (before the implementation described below), pg_durable was intrusive when it was included in `shared_preload_libraries` and `CREATE EXTENSION pg_durable` had not been executed:

1. **Background worker creates duroxide schema immediately** on startup via `PostgresProvider::new_with_schema()`, even if `CREATE EXTENSION pg_durable` has never been run
2. **Two SQL connection pools are created immediately** on startup (one internal to `PostgresProvider`, and one explicit `sqlx::PgPool` for activities), regardless of extension existence
3. **df functions can trigger duroxide schema creation** if called before the background worker initializes (race condition)
4. **No mechanism to detect extension drop** - background worker continues running even if `DROP EXTENSION pg_durable` is executed
5. **Schema lifecycle not managed by extension system** - duroxide schema is created imperatively rather than declaratively via CREATE EXTENSION/ALTER EXTENSION UPDATE

This creates confusion for users who include pg_durable in `shared_preload_libraries` for future use but haven't created the extension yet, and violates PostgreSQL best practices for extension schema management.

## Goals

1. **Minimize footprint when extension not created**: Background worker should do minimal work until `CREATE EXTENSION pg_durable` is executed
2. **Proper extension lifecycle management**: Schema creation/deletion should be managed by PostgreSQL's extension system
3. **Handle extension drop gracefully**: Background worker should detect when extension is dropped and return to waiting state
4. **Prevent race conditions**: df functions should not trigger duroxide schema creation
5. **Follow PostgreSQL best practices**: Per PostgreSQL expert guidance:
   - Schemas should be managed by CREATE EXTENSION/ALTER EXTENSION UPDATE
   - Background worker should use SPI to check extension existence (deferred)
   - Use processUtility hooks to catch extension create/drop events (deferred)

## Previous Architecture (pre-fix)

### Background Worker Initialization (src/worker.rs)

```rust
#[pg_guard]
#[no_mangle]
pub extern "C-unwind" fn duroxide_worker_main(_arg: pg_sys::Datum) {
    // ...
    rt.block_on(async {
        // Immediately tries to create PostgresProvider (and duroxide schema).
        // NOTE: PostgresProvider initialization also creates its own internal sqlx pool.
        let store = loop {
            match PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA)).await {
                Ok(s) => break Arc::new(s),
                Err(e) => {
                    // Retries every 5 seconds forever
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }

        
        // Creates a *second* connection pool immediately (used by activities)
        let pg_pool = loop {
            match PgPoolOptions::new().max_connections(5).connect(&pg_conn_str).await {
                Ok(pool) => break Arc::new(pool),
                // ...
            }
        };
        
        // Starts duroxide runtime
        let duroxide_runtime = runtime::Runtime::start_with_store(store, activities, orchestrations).await;
        // ...
    });
}
```

**Issues:**
- No check for extension existence before initialization
- Two connection pools created eagerly (provider pool + activities pool)
- No mechanism to detect extension drop

### df Functions Using PostgresProvider (src/client.rs, src/monitoring.rs, src/explain.rs)

```rust
// src/client.rs - get_duroxide_client()
fn get_duroxide_client() -> Result<&'static Client, String> {
    rt.block_on(async {
        let store = Arc::new(
            PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA))
                .await
                .map_err(|e| format!("Failed to connect to duroxide store: {e}"))?,
        );
        // ...
    })
}
```

**Issues:**
- Can be called before background worker initializes
- May create duroxide schema before background worker does
- No coordination with background worker lifecycle

## Architecture

### 1. Extension-Managed Schema *and* DDL (implemented)

**Change:** pg_durable ships the Duroxide provider schema DDL as extension SQL, executed directly by PostgreSQL during `CREATE EXTENSION pg_durable`.

This is the PostgreSQL best-practice approach for extension-owned objects:

- Objects created by the extension SQL scripts are registered as **extension members** (dependency type `e`).
- `DROP EXTENSION pg_durable` reliably removes the schema + objects (subject to Postgres semantics; `CASCADE` may be required because the schema is non-empty).
- `pg_dump`/`pg_restore` behavior is more predictable because the DDL is part of the extension lifecycle rather than “out-of-band”.

#### How we do it (the “migration SQL hand-over”)

We keep an audited, ordered copy of the upstream migration SQL inside this repo:

- `sql/duroxide_upstream/0001_*.sql` … `0005_*.sql` (verbatim copies)
- `scripts/gen-duroxide-install-sql.sh` generates a combined `sql/duroxide_install.sql`
- `scripts/verify-duroxide-migrations.sh` checks that:
  - our copies match `duroxide-pg-opt/migrations/`
  - the generated combined install SQL matches what’s checked in

The generated install SQL sets `search_path` to `duroxide` for the migration DDL, then resets it to `@extschema@` at the end so that subsequent extension SQL blocks (operators, etc.) resolve to the correct schema.

We include `sql/duroxide_install.sql` as part of the extension install SQL via `extension_sql_file!`.

#### Why we avoid “out-of-band” DDL

We previously considered (and prototyped) applying the schema DDL via Rust code.
Two variants are tempting but both lose the extension ownership model:

1. **Separate-session migrations** (opening a new SQL connection and running DDL) create objects that are not extension members.
2. **SPI from a UDF during `CREATE EXTENSION`** can create the objects, but they still are not reliably registered as extension members.

Given those trade-offs, running the DDL as extension SQL is the clearest, most PostgreSQL-native approach.

### 2. Background Worker: `MigrationPolicy::ApplyAll`

duroxide-pg-opt provides `MigrationPolicy::ApplyAll` which:
- Applies pending migrations from the embedded migration files
- Creates the schema tables if they don't yet exist
- Records applied migrations in `_duroxide_migrations`
- Unconditionally rejects unknown migrations via `check_no_unknown_migrations()` (schema ahead of code — indicates a downgrade scenario)

The BGW verifies that the `duroxide` schema is owned by the `pg_durable` extension (via `pg_depend`) before calling `PostgresProvider::new_with_config`. This prevents the BGW from migrating a schema that was not created by `CREATE EXTENSION`.

All backend sessions (`df.*` functions) continue to use `MigrationPolicy::VerifyOnly` — they never execute DDL.

### 3. Background Worker Lifecycle State Machine (implemented, MVP polling)

**Change:** Background worker should wait for extension creation before initializing the duroxide runtime.

#### State Machine

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         BACKGROUND WORKER STATES                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  [STARTING] ──────────────────────────────────────────┐                │
│      │                                                 │                │
│      │ Check extension exists                          │                │
│      │                                                 │                │
│      ├──── No ────> [WAITING_FOR_EXTENSION]           │                │
│      │                     │                           │                │
│      │                     │ Poll every 5s             │                │
│      │                     │ Check: SELECT oid         │                │
│      │                     │        FROM pg_extension  │                │
│      │                     │        WHERE extname =    │                │
│      │                     │        'pg_durable'       │                │
│      │                     │                           │                │
│      │                     └──── Yes ───────────┐      │                │
│      │                                          │      │                │
│      └──── Yes ─────────────────> [CHECKING_SCHEMA_OWNERSHIP]         │
│                                                  │                      │
│                                     Check pg_depend: is duroxide        │
│                                     schema owned by pg_durable ext?     │
│                                                  │                      │
│                  Not owned ──────────────────────┤                      │
│                  (retry after poll interval)      │                      │
│                                                  │ Owned                │
│                                                  ▼                      │
│                                            [INITIALIZING]               │
│                                                  │                      │
│                                     Apply pending migrations (ApplyAll) │
│                                     Create connection pool              │
│                                     Start duroxide runtime              │
│                                                  │                      │
│                                                  ▼                      │
│                                            [RUNNING]                    │
│                                                  │                      │
│                                    Poll for extension drop every 5s     │
│                                    Check: SELECT oid FROM pg_extension  │
│                                           WHERE extname = 'pg_durable'  │
│                                                  │                      │
│                          Extension exists ───────┤                      │
│                                                  │                      │
│                          Extension dropped ──────┴────> [SHUTTING_DOWN]│
│                                                              │          │
│                                              Shutdown duroxide runtime │
│                                              Close connections         │
│                                                              │          │
│                                                              ▼          │
│                                                    [WAITING_FOR_        │
│                                                     EXTENSION]          │
│                                                              │          │
│                                                  (cycle repeats)        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Implementation

See `src/worker.rs` for the full implementation. The main loop in `run_duroxide_runtime()` drives the state machine:

1. `wait_for_extension_creation()` polls `pg_extension` via a reusable `sqlx::PgPool` (max 1 connection) every 5 seconds.
2. `initialize_duroxide_runtime()` first checks that the `duroxide` schema is owned by the `pg_durable` extension (via `pg_depend`). If not, it logs a warning and retries after the poll interval. It then releases extension ownership of any duroxide objects (no-op on fresh installs; needed for upgrades from ≤0.1.1). Then it creates a `PostgresProvider` using `worker_provider_config()` (from `src/types.rs`) which sets `ApplyAll`, with long-polling intentionally left enabled for work dispatch. Unknown-migration rejection is always enforced unconditionally by the provider.
3. After the runtime starts, the BGW writes a **readiness record** (`duroxide._worker_ready`) with the current `WORKER_SCHEMA_VERSION`, then writes an **epoch sentinel** (`df._worker_epoch`) with a fresh UUID. The readiness record signals backend sessions that the duroxide schema is fully initialized; the epoch sentinel detects drop+recreate scenarios (see below).
4. `run_until_extension_dropped_or_shutdown()` uses `tokio::select!` to interleave shutdown checks (every 1 second, via direct volatile read) with epoch-sentinel checks (every 5 seconds via the shared polling pool).

#### Epoch sentinel: detecting drop+recreate

Pure `pg_extension` polling can miss a DROP → CREATE cycle if both happen between two poll ticks (every 5 seconds). In that window the extension is always "present", so the BGW would continue running with a stale `PostgresProvider` whose cached plans reference dropped schema objects.

The **epoch sentinel** solves this:

- Extension SQL declares `df._worker_epoch (epoch_id UUID PRIMARY KEY, started_at TIMESTAMPTZ, last_seen_at TIMESTAMPTZ)`.
- After init, the BGW inserts a row with a fresh UUID.
- The running-state poll checks: "does my UUID still exist?" instead of "does the extension exist?"
- Three outcomes:
  - **Row exists** → keep running.
  - **Row missing / different UUID** → extension was drop+recreated → break → reinit.
  - **Query error** (table/schema gone) → extension was dropped → break → reinit.

Because `DROP EXTENSION CASCADE` removes the entire `df` schema (including `_worker_epoch`), the sentinel row is always destroyed by a drop — even if the extension is immediately recreated. The BGW is guaranteed to reinitialise with a fresh runtime.

Key design choices vs. the original sketch:
- **Epoch sentinel**: Eliminates the drop+recreate blind spot; no need for explicit sleeps in tests between DROP and CREATE EXTENSION.
- **Reusable polling pool**: A single `PgPool(max_connections=1)` is created once and shared across all polling calls, avoiding the overhead of opening/closing a TCP connection on every poll.
- **Direct shutdown check**: `is_shutdown_requested()` reads a volatile atomic and does not need `spawn_blocking`; the check runs every 1 second rather than every 100ms.
- **Config helpers**: `worker_provider_config()` and `backend_provider_config()` in `src/types.rs` centralize `ProviderConfig` construction, eliminating duplication across ~10 call sites.

### 4. Prevent df Functions from Triggering Schema Creation

**Change:** df functions should fail gracefully if called before the extension has been created, and must never create schema/tables implicitly.

**Implemented:** all call sites use `MigrationPolicy::VerifyOnly`, so they will not execute DDL.

**Implemented:** request/response-style backend calls disable Duroxide long-polling to avoid a dedicated listener connection per backend.

#### Client Functions (src/client.rs)

All backend call sites (client, monitoring, explain) use `backend_provider_config()` from `src/types.rs`, which sets:
- `VerifyOnly`: never create schema/tables
- `long_poll.enabled = false`: avoid dedicated listener connection per backend session

Unknown-migration rejection is enforced unconditionally by the provider (not a config flag).

Additionally, backend sessions check `duroxide._worker_ready` before instantiating the duroxide client. If the BGW has not yet initialized the schema for the current binary's expected version, the function raises a clear error: `"pg_durable background worker not yet initialized — try again in a moment"`.

See `src/client.rs::get_duroxide_client()` for the cached-client implementation.

**Rationale:**
- (Future) Check extension existence before attempting duroxide connection
- Use `VerifyOnly` policy to ensure no schema creation from client code
- Disable long-polling for backend request/response operations to save a dedicated listener connection per backend
- Fail with clear, actionable error messages for different failure scenarios
- Note on caching: after `DROP EXTENSION`, the `df.*` entrypoints disappear, so cached clients are not reachable through SQL. However, if the extension is later re-created while a backend session remains alive, a previously cached client may be stale; this can be handled later by recreating the client on specific errors.

#### Monitoring Functions (src/monitoring.rs, src/explain.rs)

Apply the same pattern: use `backend_provider_config()` from `src/types.rs`. See `src/monitoring.rs` and `src/explain.rs` for the full implementations.

**Rationale:**
- Same benefits as client functions: no schema creation
- Monitoring functions are also request/response operations
- Graceful degradation: return empty results if schema not initialized yet

### 5. Extension Lifecycle Detection: sqlx polling (now) vs utility hooks (later)

**Per PostgreSQL expert guidance:** A reactive approach would use utility hooks to catch `CREATE/DROP EXTENSION`.

#### Current Approach (MVP): sqlx polling

This design uses `sqlx` polling (checking `pg_extension` table every 5 seconds):

**Advantages:**
- Simple to implement with pgrx
- Works with current pgrx API
- Low overhead (one query per 5-10 seconds)
- Avoids introducing hooks in the MVP

**Disadvantages:**
- Not reactive - up to 5 second delay detecting extension create/drop
- Requires periodic wake-ups even when idle
- Not the PostgreSQL "best practice" approach

#### Considered for later: utility hooks

**processUtility hooks** would allow reactive detection of CREATE/DROP EXTENSION:

**Advantages:**
- Immediate response to extension lifecycle events
- No polling overhead
- Follows PostgreSQL expert guidance
- More architecturally correct

**Challenges:**
- Need to investigate if pgrx exposes processUtility hooks
- If not exposed, may need to use unsafe FFI to register hooks
- More complex implementation
- Hook registration must happen in `_PG_init()` before extension is created

**Research needed (later):**
- Whether pgrx exposes utility hooks safely (or we need unsafe FFI)
- How to coordinate hook callbacks with the async BGW loop
- Whether hooks materially improve UX vs polling for this extension

## What we'll implement now (MVP)

### Behavior

1. **Background worker does minimal work until the extension exists**
    - Implementation: poll `pg_extension` (via `sqlx`) until `pg_durable` exists.
    - Only after extension creation does the BGW verify duroxide schema ownership, then apply pending migrations via `ApplyAll`, initialize pools, and start the duroxide runtime.

2. **Migrations are applied by the BGW**
    - `CREATE EXTENSION pg_durable;` creates the `duroxide` schema as an extension-owned object.
    - The BGW applies the Duroxide provider table DDL at startup via `MigrationPolicy::ApplyAll`.
    - Poll `duroxide._worker_ready` to check that the BGW has fully initialized.

3. **Strict runtime behavior (simple and conservative)**
    - Background worker uses `MigrationPolicy::ApplyAll` to apply pending migrations; all `df.*` backend functions use `MigrationPolicy::VerifyOnly`.
    - If migrations are missing/behind/incompatible for backend functions, everything fails closed:
      - no orchestration execution
      - no new orchestration submission
      - monitoring returns errors or empty results (depending on API)
        - Upgrade behavior will be driven by PostgreSQL extension update scripts (future work).

4. **Background worker detects extension drop (polling-based)**
        - Implementation: while running, poll `pg_extension`; if `pg_durable` disappears, shutdown the duroxide runtime and return to the wait loop.

5. **Extension creation validation (implemented)**
    - `CREATE EXTENSION pg_durable` validates prerequisites before allowing installation:
      - **Validates shared_preload_libraries**: Extension creation fails if `pg_durable` is not in `shared_preload_libraries` (checked in `_PG_init`)
      - **Validates target database**: Extension creation fails if run in the wrong database
        - Background worker connects to ONE database (determined by `POSTGRES_DB` or `PGDATABASE` environment variable, defaults to `postgres`)
        - Extension must be created in that exact database
        - Validation runs during `CREATE EXTENSION` via SQL block that calls `df.target_database()` function
        - Error message clearly indicates which database should be used
    - These validations ensure users get immediate feedback rather than discovering at runtime that workflows won't execute

### Repair story

Because the Duroxide schema DDL runs inside `CREATE EXTENSION` as extension SQL, installs are transactional:

- If `CREATE EXTENSION pg_durable` fails, the install is rolled back.
- If you need to reset state: `DROP EXTENSION pg_durable CASCADE;` then `CREATE EXTENSION pg_durable;`.

## Considered and left for later

- **Utility hooks** (reactive create/drop detection) instead of polling.
- **Multi-database support**: Currently, the background worker connects to one database only. Multi-database support would require multiple background worker processes or a more complex connection pooling strategy.
- **DROP EXTENSION while workflows are running** (currently undefined; BGW may error while writing to `df.*`).
- **Extension upgrade scripts**: using `pg_durable--X--Y.sql` to apply incremental changes across versions.
  - Note: the install SQL uses `CREATE SCHEMA duroxide;` (no `IF NOT EXISTS`) to prevent schema-squatting. Duroxide DDL inside the schema is applied by the BGW, not by extension SQL.

## Testing Strategy

### Unit Tests

1. **ProviderConfig integration**
   - Test that `MigrationPolicy::VerifyOnly` correctly errors when schema missing
   - Test that `MigrationPolicy::VerifyOnly` succeeds when schema exists and is current
    - Test that disabling long-polling in backend sessions doesn't create PgListener connections

### E2E Tests

1. **Extension creation with declarative schema**
   - Start PostgreSQL with pg_durable in shared_preload_libraries
   - Verify no duroxide schema created (background worker waiting)
   - Run CREATE EXTENSION pg_durable
   - Verify duroxide schema created (owned by extension)
    - Verify duroxide tables/functions created (by BGW via ApplyAll)
    - Verify background worker initializes eventually
   - Verify df functions work

2. **Extension not created**
   - Start PostgreSQL with pg_durable in shared_preload_libraries
   - Verify no duroxide schema created
    - Verify df functions fail (no implicit DDL)
    - Verify background worker does not create schema/tables while retrying

3. **Extension drop**
    - Create extension, start workflow
    - Drop extension
    - Verify schema + objects are removed (extension-owned)
    - (Future) Decide and test what the BGW should do on drop (detect + shut down vs keep retrying)

4. **Extension recreate**
   - Create extension
   - Drop extension  
   - Recreate extension
   - Verify background worker reinitializes

5. **Prerequisite validation tests (implemented)**
    - Test 00_requires_shared_preload.sql: Validates CREATE EXTENSION fails without shared_preload_libraries
    - Test 27_database_validation.sql: Validates CREATE EXTENSION succeeds in the correct database, and actually fails with the expected error message in a wrong database (tested via dblink into a throwaway database)
    - Tests ensure users get clear error messages during extension creation rather than discovering issues at runtime

## PostgreSQL Best Practices Alignment

### Where this aligns

1. **Schemas managed by CREATE EXTENSION**
    - The `duroxide` schema is created by the extension and dropped by `DROP EXTENSION`.

2. **Objects created as extension members**
    - The Duroxide provider tables/functions are created by extension SQL and are extension members.

3. **Background worker avoids implicit DDL**
    - Uses `VerifyOnly` and never creates schema/tables.

### Where this is intentionally non-idiomatic (trade-off)

- Duroxide provider DDL is applied by the BGW at startup (`ApplyAll`) rather than embedded in extension SQL. This decouples the duroxide schema lifecycle from `ALTER EXTENSION UPDATE`, allowing duroxide-pg-opt upgrades without extension upgrade scripts.

### Rationale for Polling in MVP

While processUtility hooks are the "correct" PostgreSQL approach, polling is acceptable for MVP because:
- Extensions are created/dropped rarely (not a hot path)
- 5 second detection latency is tolerable
- Simpler implementation = faster time to value
- Can be upgraded to hooks post-MVP without changing client-facing behavior

### Trade-offs with duroxide-pg-opt

The duroxide schema is extension-owned but its contents are BGW-managed:

- ✅ PostgreSQL-native lifecycle: install/upgrade/drop go through extension scripts (for `df.*` schema) and BGW-applied migrations (for `duroxide.*` schema).
- ✅ Clear ownership: the `duroxide` schema is extension-owned; objects inside it are BGW-managed.
- ✅ Decoupled: duroxide-pg-opt upgrades do not require changes to extension SQL or upgrade scripts.

### Known Limitations (future work)

1. **shared_preload_libraries validation** ✅ **IMPLEMENTED**
    - CREATE EXTENSION now fails if pg_durable is NOT in `shared_preload_libraries`
    - Validation happens in `_PG_init()` during extension load
    - Clear error message directs users to add pg_durable to `shared_preload_libraries` and restart

2. **Single database limitation** ✅ **VALIDATED**
   - Background worker connects to ONE database (POSTGRES_DB/PGDATABASE env var, defaults to `postgres`)
   - CREATE EXTENSION now validates the current database matches the background worker's target database
   - **Mitigation (implemented):** Extension creation fails with clear error if run in wrong database
   - **Future:** Support multi-database (would require multiple background workers or more complex architecture)

3. **No multi-database support** ⚠️
   - pg_durable can only be used in the database where the background worker is connected
   - This is an architectural limitation of single background worker process
   - Users attempting to create extension in wrong database now get immediate validation error
   - **Future consideration:** Multiple background workers (one per database)?

## Compatibility Considerations

### Breaking Changes

- None (the extension has not shipped yet), but behavior becomes stricter: if migrations are missing/behind, the system fails closed.

### Behavioral Changes

1. **duroxide schema creation timing**
    - **Current behavior:** Schema/tables created implicitly by BGW and backend calls.
    - **New behavior:** `CREATE EXTENSION` creates the empty `duroxide` schema (extension-owned). The BGW populates it via `ApplyAll` at startup.
   
2. **Background worker wait behavior**
    - **New behavior:** BGW waits for extension existence, and also stays in "waiting" when migrations are missing/behind (VerifyOnly fails).

3. **Backend sessions disable long-polling**
    - **Default behavior (upstream):** `duroxide_pg_opt::PostgresProvider` can enable long-polling by default.
    - **pg_durable behavior:** For backend request/response operations (start/cancel/signal, monitoring), we disable long-polling to avoid a dedicated listener connection and notifier task.
    - **Impact:** Resource savings for installations with many backends.
    - **Compatibility:** No user-visible changes expected.

## Open Questions

### Resolved

1. **Should duroxide-pg-opt provide a "don't create schema" mode?**
   - ✅ **RESOLVED:** duroxide-pg-opt 0.1.18 provides `MigrationPolicy::VerifyOnly` which never executes DDL
   - No need for upstream changes or manual schema checks

2. **How should pg_durable avoid implicit schema creation?**
    - ✅ Use `VerifyOnly` for all `df.*` backend functions; BGW uses `ApplyAll` after verifying schema ownership.

3. **Should CREATE EXTENSION validate shared_preload_libraries and target database?**
    - ✅ **RESOLVED:** Validation implemented during extension creation
    - shared_preload_libraries validated in `_PG_init()` 
    - Target database validated via SQL block during CREATE EXTENSION
    - Users get immediate, clear error messages instead of discovering issues at runtime

### Remaining Questions

1. **How do we handle versioned upgrades over time?**
    - We will likely need `pg_durable--X--Y.sql` scripts that apply only the delta (including any new upstream Duroxide migrations).

2. **Should background worker use utility hooks instead of polling?**
    - Expert guidance recommends hooks for reactive detection
    - **For MVP:** Use polling (simpler, proven)
    - **Later:** Implement utility hooks if pgrx supports them
    - **Trade-off:** Simplicity vs 5 second detection latency

3. **What should happen to running workflows when extension is dropped?**
   - **Option A:** Graceful shutdown - cancel all running instances
   - **Option B:** Immediate shutdown - let PostgreSQL handle cleanup
   - **Proposed:** Option B initially (simpler), Option A as enhancement

4. **Should we support pg_durable.enabled GUC to disable background worker?**
   - Allow users to keep in shared_preload_libraries but disable worker
   - **Proposed:** Future enhancement, not in initial implementation

## Success Criteria

1. ✅ BGW does not create the duroxide schema/tables and waits when extension/migrations are missing
2. ✅ Backend `df.*` functions do not create schema/tables and fail closed when migrations are missing/behind
3. ✅ Migrations are applied via extension SQL during `CREATE EXTENSION pg_durable`
4. ✅ CREATE EXTENSION validates shared_preload_libraries requirement
5. ✅ CREATE EXTENSION validates target database matches background worker database
6. ✅ Documentation clearly states prerequisites, limitations, and recovery steps

## References

- PostgreSQL Extension Documentation: https://www.postgresql.org/docs/current/extend-extensions.html
- pgrx Background Worker Documentation: https://github.com/pgcentralfoundation/pgrx/blob/develop/pgrx-examples/bgworker/src/lib.rs
- duroxide-pg-opt: https://github.com/microsoft/duroxide-pg-opt
- pg_durable current architecture: [ARCHITECTURE.md](ARCHITECTURE.md)

## Timeline Estimate

### MVP

- Schema declaration + explicit migration function + BGW waiting behavior + backend VerifyOnly + docs/tests.

### Later investigations

- Utility hooks, multi-db, drop semantics, and more PostgreSQL-native migrations.
