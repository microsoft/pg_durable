# Multi-Database Support

**Status:** Completed
**Updated:** 2026-09-10

## Summary

Durable functions can execute SQL in any database on the same PostgreSQL cluster.
A single invocation selects one SQL execution database. Since 0.2.8, multiple
databases can also have native local installations sharing one control runtime;
see [Multi-Database Extension Installation](multi-database-installation.md).

## Motivation

Explicit SQL targeting lets users with separate tenant, `analytics`, or `app`
databases execute work without moving data into the control database. Satellite
installation is a separate capability: it keeps each caller's metadata, grants,
variables, and transaction semantics local.

The original target-selection API follows pg_cron's optional remote-execution
model; it does not require an extension installation in the SQL target.

## Design Principles

1. **One engine, multiple local installations.** Install explicitly in the control database (`pg_durable.database`) first and wait for worker readiness, then install satellites. Each origin owns local `df` metadata, RLS, variables, and APIs. Only control has the provider namespace (`_duroxide`, or legacy `duroxide`); there is one runtime/provider.

2. **One database per function invocation.** A single `df.start()` call targets exactly one database. All SQL nodes in that invocation execute against that database. We explicitly do not support functions that span multiple databases in this iteration—it would complicate the DSL and orchestration for limited benefit. Users needing cross-database work can use `dblink` or `postgres_fdw` inside their SQL queries, or start separate durable functions per database.

3. **DSL is database-agnostic.** The DSL (`df.sql()`, `~>`, `&`, etc.) has no concept of "database." Database is purely a property of the *instance*, set at `df.start()` time. This keeps the DSL simple and avoids a combinatorial explosion of database-aware operators.

4. **Origin-local default.** Omitting `database` or passing NULL uses the database where `df.start()` was called. Runtime activity routing supplies this default without changing recorded payloads. Existing control-database starts retain their behavior.

## API Design

### Option Considered: New Function `df.start_in_database()`

pg_cron uses a separate function (`cron.schedule_in_database()`). This has the advantage of zero risk of breaking changes, but adds a parallel function that must be maintained in lockstep with `df.start()`.

### Chosen Approach: Optional Parameter on `df.start()`

The optional `database` parameter on `df.start()` selects the SQL target:

```sql
-- Existing signature (unchanged behavior):
SELECT df.start(df.sql('SELECT 1'));
SELECT df.start(df.sql('SELECT 1'), 'my-label');

-- New: specify target database
SELECT df.start(df.sql('SELECT 1'), database => 'analytics');
SELECT df.start(df.sql('SELECT 1'), 'my-label', 'analytics');
```

The current signature is:

```sql
df.start(fut text, label text DEFAULT NULL, database text DEFAULT NULL,
         transaction_mode text DEFAULT 'caller') → text
```

**Why this is not a breaking change:**
- The new parameter has a `DEFAULT NULL` value, so all existing calls continue to work unchanged.
- PostgreSQL supports named parameter syntax (`database => 'analytics'`), so users can skip `label` and specify only `database`.
- pgrx supports `default!()` for optional parameters, which maps to SQL `DEFAULT`.

**Why we prefer this over a separate function:**
- One function to learn and document.
- No risk of the two functions drifting apart.
- Matches PostgreSQL's general convention of optional parameters over function proliferation.
- `database => NULL` means "use the default" — clean and intuitive.

### Querying from Other Databases

Install a satellite after control is ready to call `df.start()`, `df.status()`,
`df.result()`, signal, cancel, await, and other APIs locally. Use public
eight-character IDs in that origin; engine IDs are privately namespaced by database
OID and installation UUID. A database without an installation has no local `df`
API, even if it is a workflow's explicit SQL target.

`transaction_mode => 'caller'` writes metadata in the caller's transaction.
`'new'` uses a loopback session in the caller's database, not the SQL target;
`max_new_transaction_starts` limits these launches per database through advisory
locks. Neither mode makes local metadata, engine state, and remote SQL atomic.

## Schema Changes

The following columns describe the original, already-shipped SQL-target feature;
they are not new 0.2.8 migration DDL.

### `df.instances` Table

Add a `database` column:

```sql
ALTER TABLE df.instances ADD COLUMN database TEXT;
```

- `NULL` means the origin database where this local `df.instances` row lives. Changing `pg_durable.database` selects a different control store; it does not migrate existing engine state.
- Non-NULL values name a different database on the same cluster.
- Populated by `df.start()` from the `database` parameter.

### `df.nodes` Table

Add a `database` column:

```sql
ALTER TABLE df.nodes ADD COLUMN database TEXT;
```

Like `submitted_by`, this is denormalized from the instance for convenience—the `execute_sql` activity reads from `df.nodes` and should not need to join with `df.instances` to determine the target database. NULL means "the extension database," same as on `df.instances`.

### No Changes to DSL / `Durofut`

The `Durofut` struct (and by extension `df.sql()`, operators, etc.) does not need a database field. The database is an *instance-level* property, set once at `df.start()` and stamped onto all nodes at insertion time—exactly like `submitted_by` today.

## Implementation Changes

This list records the original explicit-target implementation. Satellite support
adds routing in [src/origin.rs](../src/origin.rs) and
[src/registry.rs](../src/registry.rs), not new recorded orchestration payloads.

### 1. `df.start()` — [src/dsl.rs](../src/dsl.rs)

- Add `database: default!(Option<&str>, "NULL")` parameter.
- When `database` is `Some(db)`, validate it exists (see [Validation](#validation) below).
- Pass `database` value (or NULL) to `insert_nodes()` and include it in the `INSERT INTO df.nodes` statement.
- Include `database` in the `INSERT INTO df.instances` statement.

### 2. `FunctionNode` — [src/types.rs](../src/types.rs)

- Add `pub database: Option<String>` field.
- Serialized/deserialized naturally with serde.

### 3. `load_function_graph` Activity — [src/activities/load_function_graph.rs](../src/activities/load_function_graph.rs)

- Include `database` in the SELECT from `df.nodes`.
- Populate `FunctionNode.database`.

### 4. `execute_sql` Activity — [src/activities/execute_sql.rs](../src/activities/execute_sql.rs)

- Add `database: Option<String>` to `ExecuteSqlInput`.
- Pass it to `connect_as_user()`.

### 5. `connect_as_user()` — [src/types.rs](../src/types.rs)

- Add `database: Option<&str>` parameter.
- Use `database.unwrap_or_else(|| &target_database())` for connection options instead of hard-coding `target_database()`.

For satellite work, the activity registry fills a NULL target with the origin
database before calling the SQL activity; the control fallback remains unchanged.

### 6. Orchestration — [src/orchestrations/execute_function_graph.rs](../src/orchestrations/execute_function_graph.rs)

- When building the `ExecuteSqlInput` JSON, include `node.database`.
- No other changes needed—the orchestration itself doesn't care about the database.

### 7. Schema DDL — [src/lib.rs](../src/lib.rs)

- Add `database TEXT` column to both `CREATE TABLE` statements.

### 8. `execute_http` Activity

- HTTP requests have no SQL target, but HTTP and multipart authorization is checked
    against the origin installation, never against an explicit SQL target.

## Validation

When `df.start()` receives a non-NULL `database` parameter, we should validate that the database exists. This can be done via:

```sql
SELECT 1 FROM pg_database WHERE datname = $1
```

If the database doesn't exist, raise an error immediately rather than letting the background worker fail later with a confusing connection error.

**Role validation:** We do *not* need to validate that `submitted_by` can connect to the target database at `df.start()` time. The existing behavior already defers connection errors to activity execution time, which is appropriate for durable functions (the role/database might be created between `df.start()` and actual execution).

## Security Considerations

- **Role isolation is preserved.** The background worker connects directly as `submitted_by` (the `current_user` captured at `df.start()` time). The user who calls `df.start()` determines the execution role, not the target database.
- **`pg_hba.conf` applies.** The background worker's `submitted_by` connection to a different database is subject to the same `pg_hba.conf` rules as any other connection. If the role can't connect to that database, the activity fails with a clear error.
- **No privilege escalation.** Targeting a different database doesn't grant additional privileges. SQL executes with `submitted_by`'s permissions *in that database*.
- **Local worker access.** `pg_durable.worker_role` defaults to the `postgres` superuser. A custom role needs database-local `CONNECT`, `df` metadata/guard rights, and access for origin-local HTTP privilege lookup. `BYPASSRLS` does not grant those privileges.
- **Administrative metrics are global.** Local `df.grant_usage(..., with_grant => true)` grants delegation and `df.metrics()` access, which exposes shared-engine totals across all origins and users, including from a satellite.

## Observability

- `df.instances` and `df.nodes` gain a `database` column visible in `SELECT * FROM df.instances`.
- Background worker logs already include the SQL being executed; adding the database name to log messages in `execute_sql` would be helpful.
- `df.status()` and `df.result()` use origin-local authorization/metadata and consult the control engine as needed; instance listings remain local and RLS-scoped.

## Upgrade and Migration

- Existing rows in `df.instances` and `df.nodes` will have `database = NULL`, which correctly means "the extension database." No data migration needed.
- The schema change is additive (`ADD COLUMN ... DEFAULT NULL`), safe for rolling upgrades.
- Those target-selection columns predate 0.2.8. The 0.2.8 multi-database upgrade adds
    only local installation identity and validation; no provider DDL is added to
    migration SQL. The control worker runs `ApplyAll` and creates `_origins` before
    publishing readiness schema version `2`, required by satellite installs over SQLx.
- Supported old control schemas still work without `df._installation` or the
    provider-schema helper: control IDs stay unprefixed, the missing helper retains
    legacy `duroxide` resolution, and control replay/child composition is unchanged.
    See [Upgrade Testing](upgrade-testing.md#028).

## Testing

Known passing focused runs are `14_database` (explicit SQL targeting) and
`72_multi_database_lifecycle` (satellite lifecycle). Full unit, E2E, upgrade, and
other release gates are being conducted separately; no broader pass is claimed.

## Scope Exclusions

- **Cross-database functions:** A single function graph spanning multiple databases (e.g., read from `db1`, write to `db2`) is not supported. This would require per-node database targeting, which adds significant DSL and orchestration complexity. Users can achieve this via `dblink`/`postgres_fdw` within SQL queries, or by starting separate durable functions per database.
- **Distributed transactions and instant drop cancellation:** Satellite installs are supported, but there is no cross-database atomicity or DDL hook. Active activities guard local installation/metadata with `ACCESS SHARE` locks; a UUID fence blocks stale work after recreation. Drop cleanup is eventual and limited to confirmed removed origins, not unreachable databases. Control drop destroys all satellites' shared engine history.
- **Connection pooling per database:** Each SQL activity creates a fresh connection (existing behavior). Per-database connection pooling could improve performance but is orthogonal to this feature.

Origin metadata routes likewise retain no idle pool per database. Activities and
maintenance share `pg_durable.max_origin_connections` (default `12`, range
`2` to `1000`, restart required), reserving two slots per active route. The control
management pool limit is unchanged; there is no database-name count ceiling.

## Summary of Changes

| File | Change |
|------|--------|
| `src/lib.rs` | Add `database TEXT` column to `df.instances` and `df.nodes` DDL |
| `src/dsl.rs` | Add `database` param to `df.start()`, validate, pass to `insert_nodes()` |
| `src/types.rs` | Add `database` to `FunctionNode`; add `database` param to `connect_as_user()` |
| `src/activities/execute_sql.rs` | Add `database` to `ExecuteSqlInput`, pass to `connect_as_user()` |
| `src/activities/load_function_graph.rs` | Include `database` in node SELECT |
| `src/orchestrations/execute_function_graph.rs` | Include `node.database` in `ExecuteSqlInput` JSON |
| `tests/e2e/sql/` | Add multi-database E2E test |
