# Backend SPI: Eliminate sqlx from PostgreSQL Backend Processes

**Status:** In progress — SPI code done, permissions/RLS design needed
**Branch:** `pinodeca/backend-spi`

## Motivation

pg_durable runs inside the PostgreSQL server as an extension. When a user calls
`df.start()`, `df.status()`, or any other `df.*` function, that code executes in
the user's PostgreSQL backend process.

Previously, these backend functions created **TCP connections back to the same
PostgreSQL instance** via sqlx connection pools, plus a tokio async runtime, just
to perform simple enqueue or query operations. This was because the code shared
the same `duroxide::Client` / `duroxide_pg_opt::PostgresProvider` abstraction
used by the background worker. Those sqlx connections authenticated as the
superuser worker role, bypassing any permission checks on the duroxide schema.

| Problem | Impact |
|---------|--------|
| Each backend creates a tokio runtime | Unnecessary memory and thread overhead per session |
| Each backend opens sqlx TCP connections | Loopback TCP to the same server, authentication overhead |
| `OnceLock<Runtime>` + `OnceLock<Client>` cached per process | Process-lifetime resource leak |
| Simple INSERT/SELECT wrapped in async | Conceptual complexity for synchronous operations |
| sqlx connections run as superuser | All users implicitly get superuser access to duroxide tables |

**Solution:** Use PostgreSQL's native SPI (Server Programming Interface) for all
backend operations. SPI calls run in-process with the caller's identity — no
network connections, no authentication, and no async runtime. The duroxide stored
procedures (`duroxide.enqueue_orchestrator_work()`, `duroxide.get_instance_info()`,
etc.) are already installed as part of `CREATE EXTENSION pg_durable`.

Because SPI runs as the calling user (not the superuser), this change requires
explicit GRANT and RLS policies on both the `df` and `duroxide` schemas to
ensure users can only access their own data.

The background worker continues to use sqlx/TCP as the superuser role, since
the Duroxide runtime requires an async `Provider` trait implementation
(`Send + Sync`) which SPI cannot satisfy, and the superuser bypasses RLS.

---

## Code Changes

### client.rs — Client Operations via SPI

**Before:** `df.start()`, `df.cancel()`, `df.signal()` created a cached
`tokio::Runtime` + `duroxide::Client` (backed by sqlx pool) and called
`client.start_orchestration()` / `client.cancel_instance()` /
`client.raise_event()` via `block_on()`.

**After:** A single `enqueue_orchestrator_work()` helper builds the WorkItem JSON
using `serde_json::json!` and calls `duroxide.enqueue_orchestrator_work()` via
`Spi::connect()`. No async runtime, no connection pool, no TCP.

**Removed dependencies (from backend path):**
- `duroxide::Client`
- `duroxide_pg_opt::PostgresProvider`
- `tokio::Runtime` / `OnceLock<Runtime>`
- `std::sync::Arc`

### monitoring.rs — Monitoring via SPI

**Before:** Each monitoring function (`list_instances`, `instance_info`,
`instance_executions`, `metrics`, `instance_nodes`) created a tokio runtime +
PostgresProvider and called `duroxide::Client` methods via `block_on()`.

**After:** Direct SPI queries against duroxide stored procedures
(`list_instances()`, `get_instance_info()`, `get_execution_info()`,
`get_system_metrics()`, `list_executions()`).

### explain.rs — Instance Info Lookup via SPI

**Before:** `get_duroxide_instance_info()` created a tokio runtime +
PostgresProvider to call `client.get_instance_info()`.

**After:** Direct SPI query against `duroxide.get_instance_info()`.

### Why SPI Cannot Replace the BGW Provider

The background worker runs the Duroxide runtime, which requires a `Provider`
implementation that is `Send + Sync` and supports concurrent async calls from
multiple `tokio::spawn` tasks (orchestration dispatchers, lock renewal, session
management). PostgreSQL's SPI is `!Send + !Sync`, synchronous, and bound to
the PostgreSQL backend thread — fundamentally incompatible with the `Provider`
trait. The BGW correctly continues to use `duroxide-pg-opt` via sqlx.

---

## Permission & RLS Design

### The Problem

With sqlx, backend calls ran as the superuser (worker role), so no permissions
were needed on duroxide objects. With SPI, calls run as the calling user.
The duroxide schema functions are all `SECURITY INVOKER` (the plpgsql default)
and do direct DML on duroxide tables, so the calling user needs:

1. `USAGE` on the `duroxide` schema
2. `EXECUTE` on the duroxide functions called by SPI
3. Table-level privileges matching what those functions do internally
4. Row-level security so users only see/modify their own data

### Schema Inventory

**`df` schema** (pg_durable's own tables):

| Table | User-facing columns | User-identity column |
|-------|-------------------|---------------------|
| `df.instances` | id, label, root_node, status, ... | `submitted_by REGROLE` |
| `df.nodes` | id, instance_id, node_type, query, status, result, ... | `submitted_by REGROLE` |
| `df.vars` | name, value | _(none — session-scoped)_ |
| `df._worker_epoch` | epoch_id, started_at | _(internal — BGW only)_ |

**`duroxide` schema** (runtime engine tables):

| Table | User access needed | User-identity column |
|-------|-------------------|---------------------|
| `instances` | SELECT (monitoring) | _(none)_ |
| `executions` | SELECT (monitoring) | _(none)_ |
| `history` | SELECT (execution info counts events) | _(none)_ |
| `orchestrator_queue` | INSERT (start/cancel/signal) | _(none)_ |
| `worker_queue` | _(BGW only)_ | _(none)_ |
| `instance_locks` | _(BGW only)_ | _(none)_ |
| `sessions` | _(BGW only)_ | _(none)_ |

**Key challenge:** Duroxide tables have no user-identity column. RLS policies
must JOIN to `df.instances.submitted_by` to determine ownership.

### What Each SPI Call Needs

**Client operations** (client.rs):

| df function | Duroxide function called | Table access needed |
|-------------|------------------------|-------------------|
| `df.start()` | `duroxide.enqueue_orchestrator_work()` | INSERT on `orchestrator_queue` |
| `df.cancel()` | `duroxide.enqueue_orchestrator_work()` | INSERT on `orchestrator_queue` |
| `df.signal()` | `duroxide.enqueue_orchestrator_work()` | INSERT on `orchestrator_queue` |

**Monitoring operations** (monitoring.rs):

| df function | Duroxide functions called | Table access needed |
|-------------|-------------------------|-------------------|
| `df.list_instances()` | `list_instances()`, `list_instances_by_status()`, `get_instance_info()` | SELECT on `instances`, `executions` |
| `df.instance_info()` | `get_instance_info()` | SELECT on `instances`, `executions` |
| `df.instance_executions()` | `list_executions()`, `get_execution_info()` | SELECT on `executions`, `history` |
| `df.metrics()` | `get_system_metrics()` | SELECT on `instances`, `executions`, `history` |
| `df.instance_nodes()` | `list_executions()` | SELECT on `executions` |

**Explain** (explain.rs):

| df function | Duroxide function called | Table access needed |
|-------------|------------------------|-------------------|
| `df.explain()` | `get_instance_info()` | SELECT on `instances`, `executions` |

### GRANTs Required

Added to the extension SQL (runs at `CREATE EXTENSION` time):

```sql
-- Schema access
GRANT USAGE ON SCHEMA duroxide TO PUBLIC;

-- Function access (only the functions called by user-facing SPI)
GRANT EXECUTE ON FUNCTION duroxide.enqueue_orchestrator_work TO PUBLIC;
GRANT EXECUTE ON FUNCTION duroxide.list_instances TO PUBLIC;
GRANT EXECUTE ON FUNCTION duroxide.list_instances_by_status TO PUBLIC;
GRANT EXECUTE ON FUNCTION duroxide.get_instance_info TO PUBLIC;
GRANT EXECUTE ON FUNCTION duroxide.list_executions TO PUBLIC;
GRANT EXECUTE ON FUNCTION duroxide.get_execution_info TO PUBLIC;
GRANT EXECUTE ON FUNCTION duroxide.get_system_metrics TO PUBLIC;

-- Table access (minimum privileges for the functions above)
GRANT INSERT ON duroxide.orchestrator_queue TO PUBLIC;
GRANT SELECT ON duroxide.instances TO PUBLIC;
GRANT SELECT ON duroxide.executions TO PUBLIC;
GRANT SELECT ON duroxide.history TO PUBLIC;

-- df schema tables (already needed for DSL operations)
GRANT USAGE ON SCHEMA df TO PUBLIC;
GRANT SELECT, INSERT, UPDATE ON df.instances TO PUBLIC;
GRANT SELECT, INSERT, UPDATE ON df.nodes TO PUBLIC;
GRANT SELECT, INSERT, DELETE ON df.vars TO PUBLIC;
```

> **Note:** Granting to `PUBLIC` is the simplest starting point. In
> production, a dedicated `df_user` role could be used instead. RLS
> (below) ensures that broad GRANTs don't leak data across users.

### RLS Policies

#### Design Principles

1. **The BGW (superuser) bypasses RLS** — PostgreSQL does not enforce RLS on
   superusers unless `ALTER TABLE ... FORCE ROW LEVEL SECURITY` is used. Since
   the BGW connects as the superuser worker role, it is unaffected.

2. **Ownership is determined by `df.instances.submitted_by`** — this column
   stores the `REGROLE` of the user who called `df.start()`. All duroxide
   tables are keyed by `instance_id`, allowing a JOIN to `df.instances`.

3. **Unlinked nodes** (created by DSL operators before `df.start()`) have
   `submitted_by IS NULL` and `instance_id IS NULL`. These are transient,
   session-local rows. The RLS policy permits access to NULL-submitted nodes
   so the DSL can build graphs before linking.

#### `df.instances`

```sql
ALTER TABLE df.instances ENABLE ROW LEVEL SECURITY;

-- Users see only instances they submitted
CREATE POLICY df_instances_user ON df.instances
    USING (submitted_by = current_user::regrole);

-- Users can insert instances (submitted_by is set by df.start())
CREATE POLICY df_instances_insert ON df.instances
    FOR INSERT WITH CHECK (submitted_by = current_user::regrole);

-- Users can update only their own instances
CREATE POLICY df_instances_update ON df.instances
    FOR UPDATE USING (submitted_by = current_user::regrole);
```

#### `df.nodes`

```sql
ALTER TABLE df.nodes ENABLE ROW LEVEL SECURITY;

-- Users see their own nodes AND unlinked nodes (submitted_by IS NULL)
CREATE POLICY df_nodes_user ON df.nodes
    USING (submitted_by IS NULL OR submitted_by = current_user::regrole);

-- Anyone can insert nodes (submitted_by is NULL at creation, set by df.start())
CREATE POLICY df_nodes_insert ON df.nodes
    FOR INSERT WITH CHECK (TRUE);

-- Users can update their own nodes or unlinked nodes
CREATE POLICY df_nodes_update ON df.nodes
    FOR UPDATE USING (submitted_by IS NULL OR submitted_by = current_user::regrole);
```

#### `df.vars`

`df.vars` is a session-scoped key-value store with no user column. Variables
are set before `df.start()` and captured into the instance at start time.
Since vars have no ownership tracking, no RLS is applied. This is acceptable
because vars are ephemeral (set and read within a single session) and do not
contain results or execution state.

#### `duroxide.instances`

```sql
ALTER TABLE duroxide.instances ENABLE ROW LEVEL SECURITY;

-- Users can only see duroxide instances that correspond to their df.instances
CREATE POLICY duroxide_instances_user ON duroxide.instances
    USING (instance_id IN (
        SELECT id FROM df.instances WHERE submitted_by = current_user::regrole
    ));
```

#### `duroxide.executions`

```sql
ALTER TABLE duroxide.executions ENABLE ROW LEVEL SECURITY;

CREATE POLICY duroxide_executions_user ON duroxide.executions
    USING (instance_id IN (
        SELECT id FROM df.instances WHERE submitted_by = current_user::regrole
    ));
```

#### `duroxide.history`

```sql
ALTER TABLE duroxide.history ENABLE ROW LEVEL SECURITY;

CREATE POLICY duroxide_history_user ON duroxide.history
    USING (instance_id IN (
        SELECT id FROM df.instances WHERE submitted_by = current_user::regrole
    ));
```

#### `duroxide.orchestrator_queue`

```sql
ALTER TABLE duroxide.orchestrator_queue ENABLE ROW LEVEL SECURITY;

-- Users can insert work items only for their own instances
CREATE POLICY duroxide_orch_queue_insert ON duroxide.orchestrator_queue
    FOR INSERT WITH CHECK (instance_id IN (
        SELECT id FROM df.instances WHERE submitted_by = current_user::regrole
    ));
```

> Users do not need SELECT on `orchestrator_queue` — they never read from it.
> The BGW (superuser) reads, locks, and deletes queue items.

#### Tables with no user RLS needed

| Table | Reason |
|-------|--------|
| `duroxide.worker_queue` | No GRANT to users — BGW only |
| `duroxide.instance_locks` | No GRANT to users — BGW only |
| `duroxide.sessions` | No GRANT to users — BGW only |
| `df._worker_epoch` | No GRANT to users — BGW only |

### Effect on `df.metrics()`

`duroxide.get_system_metrics()` aggregates across ALL instances/executions/
history. With RLS enabled, a non-superuser calling this function will only
see counts for their own instances — the RLS policies filter the underlying
table scans. This is **desirable behavior**: users should see metrics for
their own workloads only.

If a superuser calls `df.metrics()`, they see system-wide totals (RLS is
bypassed for superusers).

### Performance Considerations

The RLS policies on duroxide tables use a subquery against `df.instances`:

```sql
instance_id IN (SELECT id FROM df.instances WHERE submitted_by = current_user::regrole)
```

This pattern is well-optimized by PostgreSQL's planner (semi-join). The
existing `df.instances(id)` PRIMARY KEY index makes the lookup efficient.
For workloads with many instances per user, an additional index may help:

```sql
CREATE INDEX idx_instances_submitted_by ON df.instances(submitted_by);
```

This index should be added with the RLS policies.

### Implementation Order

1. **Add GRANTs and RLS policies** to extension SQL (`src/lib.rs`)
2. **Add `idx_instances_submitted_by` index** for RLS query performance
3. **Update E2E setup** (`00_setup_playground.sql`) — remove manual GRANTs
   that are now handled by extension SQL
4. **Run full test suite** to verify

---

## Testing

The existing E2E test suite validates all affected code paths:
- `01_simple_sql.sql` through `08_loop_cancel.sql` — exercise `df.start()` (client.rs)
- `09_monitoring.sql` — exercises `list_instances`, `instance_info`, `status`, `result`
- `10_explain.sql` — exercises `df.explain()` with live instance lookup
- `21_signals.sql` — exercises `df.signal()` (client.rs)
- `22_cross_connection.sql` — exercises status/cancel across connections
- `27_user_isolation.sql` — exercises multi-user isolation (will validate RLS)
