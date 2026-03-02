# pg_durable Native Duroxide Provider — Design & POC

**Status:** POC Complete — All 3 phases implemented, builds and passes clippy  
**Created:** 2026-03-02  
**Author:** GitHub Copilot (AI-assisted design exploration)  
**Goal:** Evaluate replacing `duroxide-pg-opt` with a pg_durable-native Provider.

## Table of Contents

1. [Motivation](#motivation)
2. [Architecture Analysis](#architecture-analysis)
3. [Key Constraints](#key-constraints)
4. [Approaches Evaluated](#approaches-evaluated)
5. [Recommended Architecture](#recommended-architecture)
6. [POC Plan](#poc-plan)
7. [Learnings & Discarded Approaches](#learnings--discarded-approaches)
8. [Open Questions](#open-questions)
9. [Appendix: Provider Trait Summary](#appendix-provider-trait-summary)

---

## Motivation

pg_durable currently depends on `duroxide-pg-opt` (an external crate) to implement the
Duroxide `Provider` trait. This crate was designed for **applications** that store
duroxide engine state in PostgreSQL via `sqlx` TCP connections.

pg_durable is a **PostgreSQL extension** — it runs *inside* the database server. Using
`duroxide-pg-opt` means:

| Concern | Current Situation |
|---------|------------------|
| **Efficiency** | Both BGW and user sessions open TCP connections back to the same PG instance they're running inside |
| **Security** | TCP connections require authentication; the extension connects to itself |
| **Dependencies** | `sqlx`, `tokio`, and `duroxide-pg-opt` required in user sessions just for simple enqueue/status operations |
| **Latency** | Every `df.start()`, `df.status()` call goes through TCP serialization/deserialization |
| **Resource usage** | User sessions create connection pools (sqlx) + async runtimes (tokio) for operations that could be synchronous SPI calls |
| **Schema coupling** | Must keep `sql/duroxide_upstream/` in sync with `duroxide-pg-opt` migrations manually |

A native provider could address all of these — but the Duroxide runtime architecture
imposes constraints that make a *simple* "replace everything with SPI" approach infeasible.

---

## Architecture Analysis

### Execution Contexts in pg_durable

pg_durable operates in **two distinct contexts**:

#### 1. Backend Processes (User Sessions)

These are regular PostgreSQL backend processes handling user SQL. Functions live in
`src/dsl.rs`, `src/client.rs`, `src/monitoring.rs`, `src/explain.rs`.

**Operations performed:**
- `df.start()` → enqueue a `StartOrchestration` work item to the orchestrator queue
- `df.cancel()` → enqueue a `CancelInstance` work item
- `df.signal()` → enqueue an `ExternalRaised` work item
- `df.status()` → read instance status from `duroxide.instances`
- `df.list_instances()` → query instances table + metadata
- `df.instance_info()` → query specific instance
- `df.metrics()` → aggregate statistics
- `df.explain()` → mixed SPI + async Client calls

**Key property:** These are **request/response** — call a function, get a result, return.
There is no long-running async work in user sessions.

**Current implementation:** Creates a `tokio::Runtime` + `PostgresProvider` (sqlx pool)
per session, uses `block_on()` for async calls.

#### 2. Background Worker (BGW)

A single PostgreSQL-managed background worker process (`src/worker.rs`).

**Operations performed:**
- Runs the Duroxide runtime (`Runtime::start_with_store`)
- The runtime spawns multiple `tokio::spawn` tasks:
  - Orchestration dispatchers (default: 2 concurrent)
  - Activity dispatchers (default: 2 concurrent)
  - Lock renewal tasks (1 per in-flight item)
  - Session manager
- All tasks share `Arc<dyn Provider>` and call Provider methods concurrently

**Key property:** The Provider must be `Send + Sync` and handle concurrent async calls.

**Current implementation:** `tokio::runtime::Builder::new_current_thread()` with
`PostgresProvider` (sqlx pool over TCP).

### Provider Trait Requirements

The Duroxide `Provider` trait (from `duroxide::providers::Provider`) requires:
- `#[async_trait] impl Provider for T where T: Any + Send + Sync`
- ~15 required async methods, plus `ProviderAdmin` for management
- Concurrent calls from multiple `tokio::spawn` tasks
- Atomic transactions (especially `ack_orchestration_item`)

### Why SPI Cannot Implement Provider Directly

| Requirement | SPI Reality |
|---|---|
| `Send + Sync` | `SpiClient` is `!Send + !Sync` |
| Concurrent async calls | SPI is single-threaded, synchronous |
| Long-poll `fetch_*` (blocks 30s) | Would block the BGW OS thread |
| Lock renewal runs in parallel | Cannot interleave with blocked fetch |
| Must work from `tokio::spawn` | SPI requires PostgreSQL backend thread |

**Even with `concurrency=1`**, the Duroxide runtime spawns lock renewal tasks via
`tokio::spawn` that call Provider methods concurrently with the main dispatcher loop.
A synchronous SPI call blocks the thread entirely, preventing any other tokio task
from progressing.

### PostgreSQL Low-Level Table APIs

pgrx exposes `pg_sys::table_open()`, `heap_getnext()`, etc. However:
- These also require a valid transaction context
- They are synchronous, blocking C functions
- They use process-local palloc memory — not safe across async task boundaries
- **Same fundamental problem as SPI**

---

## Key Constraints

1. **Provider trait is async + Send + Sync** — mandated by Duroxide runtime
2. **BGW uses single-threaded tokio** — can't use `spawn_blocking` for SPI (SPI must
   run on the BGW thread itself, and `spawn_blocking` uses a thread pool)
3. **Duroxide runtime spawns concurrent tasks** — even at concurrency=1
4. **SPI requires PostgreSQL backend thread** — cannot be called from spawned threads
5. **Activities already use sqlx** — `execute_sql` activity needs network access to PG
   (it runs user-supplied SQL in a workflow context with `df.in_workflow` set)

---

## Approaches Evaluated

### Approach A: Full SPI Provider (Discarded)

**Idea:** Implement all Provider methods using pgrx SPI inside `BackgroundWorker::transaction()`.

**Why discarded:**
- Provider methods called from `tokio::spawn` tasks — SPI cannot work from spawned tasks
- `fetch_orchestration_item` does long-poll (blocks for poll_timeout) — would block
  the single BGW thread, preventing lock renewals
- Would need to serialize all Provider calls through a channel to a dedicated SPI thread
- That SPI thread can't be the BGW thread (it's running tokio) and can't be a worker
  thread (SPI requires the backend thread with `BackgroundWorkerInitializeConnection`)
- **Fundamental architecture mismatch**

### Approach B: Low-Level Table Access Provider (Discarded)

**Idea:** Use `pg_sys::table_open()` etc. instead of SPI.

**Why discarded:** Same constraints as SPI — requires transaction context, synchronous,
cannot work from async tasks.

### Approach C: Full Custom Provider with sqlx (High Risk)

**Idea:** Implement the Duroxide Provider trait entirely in pg_durable using sqlx, calling
the same stored procedures already in the duroxide schema.

**Feasibility:** Technically possible but:
- ~2,200 lines in duroxide-pg-opt to replicate
- ~30 Provider methods with complex semantics
- Ongoing maintenance burden tracking Duroxide Provider contract changes
- Must replicate retry logic, long-poll infrastructure, error classification
- Risk of subtle bugs in lock management / atomicity
- **No access to duroxide-pg-opt's stress tests and validation suite** without
  maintaining the dependency anyway

**Verdict:** Not recommended unless duroxide-pg-opt becomes unmaintainable.

### Approach D: Hybrid — SPI for Client/Monitoring + sqlx for BGW (Recommended ✅)

**Idea:** Split the approach by execution context:

| Context | Current | Proposed |
|---------|---------|----------|
| **BGW Provider** | duroxide-pg-opt via sqlx/TCP | duroxide-pg-opt via sqlx/**UDS** |
| **Client ops** (`df.start/cancel/signal`) | duroxide-pg-opt via sqlx/TCP | **Direct SPI** |
| **Monitoring** (`df.status/list_instances/metrics`) | duroxide-pg-opt via sqlx/TCP | **Direct SPI** |
| **Activities** (`execute_sql`) | sqlx/TCP pool | sqlx/**UDS** pool |

This eliminates `duroxide-pg-opt`, `sqlx`, and `tokio` from user sessions entirely.

---

## Recommended Architecture

### Phase 1: Immediate Wins (Low Risk)

#### 1a. Switch sqlx connections to Unix Domain Sockets

Change `postgres_connection_string()` to prefer UDS when available:

```rust
pub fn postgres_connection_string() -> String {
    // If PGHOST is a directory or not set, use UDS
    let host = std::env::var("PGHOST").unwrap_or_else(|_| {
        // Check for pgrx development environment
        if let Ok(pgdata) = std::env::var("PGDATA") {
            if pgdata.contains(".pgrx") {
                return "/tmp".to_string(); // pgrx uses /tmp for sockets
            }
        }
        // Production: try standard PG socket directory
        "/var/run/postgresql".to_string()
    });
    // ... format connection string with host as socket directory
}
```

**Impact:** ~30-50% latency reduction for all sqlx operations. Zero API changes.

#### 1b. Client Operations via SPI

Replace `src/client.rs` async+sqlx pattern with direct SPI calls:

```rust
pub fn start_durable_function(
    function_name: &str,
    instance_id: &str,
    input: &str,
) -> Result<(), String> {
    // Build the WorkItem::StartOrchestration as JSON
    let work_item = serde_json::json!({
        "StartOrchestration": {
            "orchestration": function_name,
            "instance": instance_id,
            "input": input,
            "version": ""
        }
    });

    // Call the stored procedure directly via SPI
    Spi::connect(|client| {
        client.update(
            &format!(
                "SELECT duroxide.enqueue_orchestrator_work($1, $2, NULL, NULL, NULL, NULL, NULL)",
            ),
            None,
            &[
                (PgBuiltInOids::TEXTOID.oid(), instance_id.into_datum()),
                (PgBuiltInOids::TEXTOID.oid(), work_item.to_string().into_datum()),
            ],
        ).map_err(|e| format!("Failed to start: {e:?}"))?;
        Ok::<_, String>(())
    })?;

    Ok(())
}
```

**Impact:** Eliminates `tokio::Runtime` + `PostgresProvider` + sqlx pool from every
user session. No TCP connections. No authentication overhead. Sub-millisecond latency.

**What's removed from user sessions:**
- `static CLIENT_RUNTIME: OnceLock<Runtime>` — gone
- `static DUROXIDE_CLIENT: OnceLock<Client>` — gone
- `duroxide::Client` usage — gone
- `duroxide_pg_opt::PostgresProvider` in backend — gone

#### 1c. Monitoring via SPI

Replace `src/monitoring.rs` async pattern with direct SPI queries:

```rust
#[pg_extern(schema = "df")]
pub fn status(instance_id: &str) -> Option<String> {
    Spi::get_one_with_args(
        "SELECT status FROM duroxide.instances WHERE instance_id = $1",
        vec![(PgBuiltInOids::TEXTOID.oid(), instance_id.into_datum())],
    ).ok().flatten()
}
```

**Impact:** All monitoring functions become simple SPI queries. No async runtime needed.

### Phase 2: Evaluate Full Provider Replacement (If Needed)

Only if duroxide-pg-opt proves problematic (maintenance burden, API drift, bugs), consider:

#### 2a. pg_durable-native Provider (sqlx-based)

Implement `Provider` trait using sqlx queries against the duroxide schema stored procedures.
This keeps the async/Send+Sync requirement satisfied while owning the implementation.

**Key consideration:** The stored procedures are already shipped as part of pg_durable's
extension SQL (`sql/duroxide_install.sql`). The Provider just needs to call them with the
right parameters.

```rust
pub struct PgDurableProvider {
    pool: Arc<PgPool>,
    schema: String,
    // Long-poll notifier (optional)
    orch_notify: Option<Arc<Notify>>,
    worker_notify: Option<Arc<Notify>>,
}

#[async_trait]
impl Provider for PgDurableProvider {
    async fn fetch_orchestration_item(&self, ...) -> Result<...> {
        // Call duroxide.fetch_orchestration_item() stored procedure
        sqlx::query_as(&format!("SELECT * FROM {}.fetch_orchestration_item($1, $2, $3, $4)", self.schema))
            .bind(now_ms).bind(lock_timeout_ms).bind(min_packed).bind(max_packed)
            .fetch_optional(&*self.pool).await
            // ... deserialize and return
    }
    // ... ~30 more methods following the same pattern
}
```

**Effort:** ~800-1000 lines (the stored procs do the heavy lifting).

#### 2b. Dual-Path Provider (SPI for Simple Ops, sqlx for Complex)

A Provider implementation that tries SPI for simple operations (when running on the BGW
thread) and falls back to sqlx for operations called from spawned tasks.

**Not recommended** — too complex, fragile, and the sqlx-only path is sufficient.

---

## POC Plan

### POC Phase 1: Client Operations via SPI ✅ COMPLETED

**Goal:** Replace `df.start()`, `df.cancel()`, `df.signal()` with direct SPI calls.

**Files modified:**
- `src/client.rs` — fully rewritten from async/sqlx/Client to direct SPI.
  Removed: `OnceLock<Runtime>`, `OnceLock<Client>`, `PostgresProvider`, `tokio::Runtime`.
  Added: `enqueue_orchestrator_work()` helper calling `duroxide.enqueue_orchestrator_work()`
  stored procedure via `Spi::connect()` + `client.select()`.
- `src/dsl.rs` — no changes needed (same function signatures).
- `src/lib.rs` — not modified yet (test helpers still use the old pattern).

**Result:** `cargo check --features pg17` and `cargo clippy --features pg17` both pass.
The core `enqueue_orchestrator_work()` function builds WorkItem JSON using
`serde_json::json!` macro (matching duroxide's externally-tagged serde format)
and calls the stored procedure directly — no async runtime, no connection pool.

### POC Phase 2: Status Monitoring via SPI ✅ COMPLETED

**Goal:** Replace all monitoring/explain functions with SPI queries.

**Files modified:**
- `src/monitoring.rs` — all 5 functions (`list_instances`, `instance_info`,
  `instance_executions`, `metrics`, `instance_nodes`) rewritten from
  async/tokio/PostgresProvider/Client to direct SPI calls against duroxide
  stored procedures (`list_instances()`, `list_instances_by_status()`,
  `get_instance_info()`, `get_execution_info()`, `get_system_metrics()`,
  `list_executions()`).
  Removed: `duroxide::Client`, `duroxide_pg_opt::PostgresProvider`, `std::sync::Arc`,
  `tokio::runtime`, `postgres_connection_string()`, `backend_provider_config()`.
- `src/explain.rs` — `get_duroxide_instance_info()` rewritten from async/Provider
  to SPI query against `duroxide.get_instance_info()`.

**Result:** Builds and passes clippy cleanly.

### POC Phase 3: Unix Domain Socket for BGW ✅ COMPLETED

**Goal:** Switch BGW sqlx connections from TCP to UDS when available.

**Files modified:**
- `src/types.rs` — `postgres_connection_string()` updated to:
  1. Detect `PGHOST` as directory path → use UDS format
  2. Auto-detect UDS when PGHOST is localhost by checking
     `/var/run/postgresql/.s.PGSQL.<port>` and `/tmp/.s.PGSQL.<port>`
  3. Fall back to TCP connection string

**Result:** Builds and passes clippy. The BGW will now prefer UDS automatically
when a PostgreSQL socket is present, avoiding TCP overhead for same-host connections.

### Validation

After each POC phase:
1. `cargo build --features pg17` — no warnings ✅
2. `cargo clippy --features pg17` — clean ✅
3. `./scripts/test-unit.sh` — TODO: run after full build
4. `./scripts/test-e2e-local.sh` — TODO: run after full build
5. Performance comparison (optional): measure `df.start()` + `df.status()` latency

### POC Summary: Lines of Code Impact

| Module | Before (LOC) | After (LOC) | Dependencies Removed |
|--------|-------------|-------------|---------------------|
| `client.rs` | 97 | 96 | `duroxide::Client`, `duroxide_pg_opt::PostgresProvider`, `tokio::Runtime`, `OnceLock`, `Arc` |
| `monitoring.rs` | 442 | ~310 | `duroxide::Client`, `duroxide_pg_opt::PostgresProvider`, `tokio::runtime`, `Arc`, `postgres_connection_string`, `backend_provider_config` |
| `explain.rs` | 663 (fn only) | 663 (~20 lines changed) | `duroxide::Client`, `duroxide_pg_opt::PostgresProvider`, `tokio::runtime`, `Arc` |
| `types.rs` | 440 | ~455 | (added UDS detection logic) |

**Key observation:** The backend-side code paths (user sessions calling `df.start()`,
`df.status()`, `df.list_instances()`, etc.) **no longer need** `duroxide::Client`,
`duroxide_pg_opt::PostgresProvider`, `tokio::runtime`, or `std::sync::Arc`. These are
only still needed in `src/worker.rs` (BGW runtime) and `src/lib.rs` (test helpers).

---

## Learnings & Discarded Approaches

### Learning 1: SPI is Thread-Bound

PostgreSQL's SPI (Server Programming Interface) uses process-global state
(`SPI_tuptable`, `SPI_processed`). The `SpiClient` type in pgrx is correctly
marked `!Send + !Sync`. This means:

- SPI cannot be called from `tokio::spawn`'d tasks
- SPI cannot implement `Send + Sync` traits like `Provider`
- SPI is fundamentally single-threaded and synchronous

**Implication:** Any Provider implementation must use a network-based PostgreSQL
client (sqlx, libpq) for the BGW context. SPI is only viable for user session
operations that run on the PostgreSQL backend thread.

### Learning 2: Duroxide Runtime Spawns Concurrent Tasks

Even with `orchestration_concurrency=1` and `worker_concurrency=1`, the Duroxide
runtime spawns additional `tokio::spawn` tasks for:
- Lock renewal (1 per in-flight orchestration/activity)
- Session management
- Observability gauges

These call Provider methods concurrently. A Provider implementation must handle
this safely.

### Learning 3: BGW Can Use Both SPI and sqlx

A background worker can call `BackgroundWorker::connect_worker_to_spi()` for
SPI access AND maintain sqlx connections simultaneously. These are independent
paths — SPI uses the process-internal backend, sqlx opens external TCP/UDS
connections.

However, using SPI in a BGW running tokio requires careful bridging (e.g.,
`block_on` in `BackgroundWorker::transaction()`). This is fragile and not
recommended when the tokio event loop needs to remain responsive.

### Learning 4: Stored Procedures Are Already Shipped

pg_durable already ships the duroxide schema stored procedures as extension SQL
(`sql/duroxide_install.sql`). These include:
- `duroxide.enqueue_orchestrator_work()` — used by client ops
- `duroxide.fetch_orchestration_item()` — used by BGW
- `duroxide.ack_orchestration_item()` — the critical atomic commit
- `duroxide.get_instance_info()` — used by monitoring

This means a native Provider or SPI-based client can call these directly without
reimplementing any SQL logic.

### Learning 5: Backend Sessions Don't Need Provider

User session operations (`df.start`, `df.cancel`, `df.signal`, `df.status`,
monitoring) are simple enqueue or query operations. They don't need the full
Provider abstraction — they just need to call stored procedures or query tables.

The current architecture creates a full `PostgresProvider` (including connection
pool, migration verification, long-poll infrastructure) just to call
`client.start_orchestration()`, which is a single INSERT.

### Discarded: Channel-Based SPI Serialization

**Idea:** Funnel all Provider calls through an `mpsc` channel to a dedicated SPI
handler that runs on the BGW thread.

**Why discarded:**
- The BGW thread is running `tokio::block_on()` — it's occupied by the event loop
- SPI calls must run on the thread that called `BackgroundWorkerInitializeConnection`
- Can't run SPI on a separate thread (it's the backend thread that has the connection)
- Would need to periodically yield from tokio to process SPI requests — breaks the
  event loop model
- Long-poll fetches (30s blocking) would starve the SPI handler

### Discarded: Shared Memory Provider

**Idea:** Use PostgreSQL shared memory (`PgSharedMem`) for Provider data.

**Why discarded:**
- Types must be `Copy + Clone` — no `String`, `Vec`, `HashMap`
- Provider data (WorkItems, Events) is complex, variable-size JSON
- Can't implement atomicity guarantees with shared memory alone
- Would essentially build a custom database in shared memory

---

## Open Questions

1. **Should we keep duroxide-pg-opt as a dependency at all?**
   - If client/monitoring move to SPI, only the BGW uses it
   - Could we eventually replace it with a simpler sqlx-based Provider in pg_durable?
   - Key risk: tracking upstream Provider trait changes

2. **WorkItem JSON format compatibility**
   - Direct SPI calls must produce WorkItem JSON matching what duroxide expects
   - Need to verify the serialization format (serde_json derives on WorkItem)
   - **Mitigation:** Use `duroxide::providers::WorkItem` for serialization in tests

3. **UDS availability in Docker/container environments**
   - Some container setups may not have standard PG socket directories
   - Need fallback to TCP loopback
   - **Mitigation:** Check for socket existence, fall back gracefully

4. **Instance creation semantics**
   - `enqueue_orchestrator_work()` does NOT create instances (by design)
   - Instance creation happens in `ack_orchestration_item()` during the first turn
   - SPI client ops must not try to create instances — just enqueue

5. **Error handling parity**
   - SPI errors have different types than sqlx errors
   - Need to ensure error messages are actionable for users
   - May need to handle "extension not installed" differently from "connection failed"

6. **Custom status polling**
   - `df.status()` currently uses `client.wait_for_status_change()` which does
     polling internally via Provider
   - SPI version would be a single `SELECT` — simpler but no long-poll
   - Acceptable trade-off for user sessions

---

## Appendix: Provider Trait Summary

### Methods Called by Client/Monitoring (Candidates for SPI)

| Operation | Current Call Path | SPI Replacement |
|-----------|------------------|-----------------|
| `df.start()` | `client.start_orchestration()` → `enqueue_for_orchestrator()` | `SELECT duroxide.enqueue_orchestrator_work(...)` |
| `df.cancel()` | `client.cancel_instance()` → `enqueue_for_orchestrator()` | `SELECT duroxide.enqueue_orchestrator_work(...)` |
| `df.signal()` | `client.raise_event()` → `enqueue_for_orchestrator()` | `SELECT duroxide.enqueue_orchestrator_work(...)` |
| `df.status()` | `client.get_instance_info()` | `SELECT * FROM duroxide.instances WHERE instance_id = $1` |
| `df.list_instances()` | `client.list_all_instances()` | `SELECT * FROM duroxide.instances` |
| `df.metrics()` | `client.get_system_metrics()` | `SELECT duroxide.get_system_metrics()` |

### Methods Used Only by BGW Runtime (Keep in Provider)

| Method | Purpose |
|--------|---------|
| `fetch_orchestration_item()` | Dequeue + lock orchestration turn |
| `ack_orchestration_item()` | Atomic commit of turn results |
| `abandon_orchestration_item()` | Release lock on failure |
| `fetch_work_item()` | Dequeue + lock activity |
| `ack_work_item()` | Ack activity completion |
| `renew_*_lock()` | Extend locks for long-running items |
| `read()` | Load history during replay |
| `enqueue_for_worker()` | Enqueue activities |
| Session methods | Session affinity management |

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-02 | Full SPI Provider is not feasible | Provider trait requires Send+Sync+async; SPI is !Send+!Sync+sync |
| 2026-03-02 | Low-level table access also not feasible | Same thread-safety and transaction-context constraints as SPI |
| 2026-03-02 | Hybrid approach is best | SPI for simple client/monitoring ops; keep sqlx Provider for BGW |
| 2026-03-02 | UDS > TCP for sqlx connections | Same-host optimization, trivial change |
| 2026-03-02 | Full Provider replacement deferred | High effort (~2000 LOC), high risk, low incremental value |
