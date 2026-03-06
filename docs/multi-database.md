# Multi-Database Support

**Status:** Draft  
**Date:** 2026-03-06

## Summary

Allow durable functions to execute SQL in any database on the same PostgreSQL cluster, not just the database where the extension is installed. A single function always runs against one database; cross-database workflows are deferred to a future enhancement.

## Motivation

Today, pg_durable can only execute SQL in the database configured by `pg_durable.database` (the same database the background worker connects to). Users with multiple databases in the same cluster—e.g., multi-tenant setups, or separate `analytics` / `app` databases—cannot use pg_durable to run durable functions against those databases.

pg_cron solved the same problem: it stores all metadata in one database but can schedule jobs against any database via `cron.schedule_in_database()`. We adopt a similar approach.

## Design Principles

1. **Extension lives in one database.** The `df` and `duroxide` schemas, background worker connection, and all metadata tables (`df.instances`, `df.nodes`) remain in the database specified by `pg_durable.database`. The extension is created (`CREATE EXTENSION pg_durable`) in only that one database.

2. **One database per function invocation.** A single `df.start()` call targets exactly one database. All SQL nodes in that invocation execute against that database. We explicitly do not support functions that span multiple databases in this iteration—it would complicate the DSL and orchestration for limited benefit. Users needing cross-database work can use `dblink` or `postgres_fdw` inside their SQL queries, or start separate durable functions per database.

3. **DSL is database-agnostic.** The DSL (`df.sql()`, `~>`, `&`, etc.) has no concept of "database." Database is purely a property of the *instance*, set at `df.start()` time. This keeps the DSL simple and avoids a combinatorial explosion of database-aware operators.

4. **Backwards compatible.** Omitting the database parameter defaults to `pg_durable.database` (today's behavior). No existing queries break.

## API Design

### Option Considered: New Function `df.start_in_database()`

pg_cron uses a separate function (`cron.schedule_in_database()`). This has the advantage of zero risk of breaking changes, but adds a parallel function that must be maintained in lockstep with `df.start()`.

### Chosen Approach: Optional Parameter on `df.start()`

Add an optional `database` parameter to `df.start()`:

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
df.start(fut text, label text DEFAULT NULL) → text
```

The new signature becomes:

```sql
df.start(fut text, label text DEFAULT NULL, database text DEFAULT NULL) → text
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

Users calling `df.start()` from a *different* database than where the extension is installed need to use `dblink` or `postgres_fdw` to call into the extension database. The extension functions (`df.start`, `df.status`, `df.result`, etc.) only exist in the extension database.

**Alternative considered:** Installing stub functions in other databases that proxy via `dblink`. Rejected as over-engineering for now; advanced users can set this up themselves.

## Schema Changes

### `df.instances` Table

Add a `database` column:

```sql
ALTER TABLE df.instances ADD COLUMN database TEXT;
```

- `NULL` means "the extension database" (i.e., the database where `df.instances` itself lives). This is always unambiguous: the table only exists in the extension database, so NULL can only refer to that database. Even if `pg_durable.database` were later changed, the old tables would be gone (extension dropped) or still in the original database.
- Non-NULL values name a different database on the same cluster.
- Populated by `df.start()` from the `database` parameter.

### `df.nodes` Table

Add a `database` column:

```sql
ALTER TABLE df.nodes ADD COLUMN database TEXT;
```

Like `submitted_by` and `login_role`, this is denormalized from the instance for convenience—the `execute_sql` activity reads from `df.nodes` and should not need to join with `df.instances` to determine the target database. NULL means "the extension database," same as on `df.instances`.

### No Changes to DSL / `Durofut`

The `Durofut` struct (and by extension `df.sql()`, operators, etc.) does not need a database field. The database is an *instance-level* property, set once at `df.start()` and stamped onto all nodes at insertion time—exactly like `submitted_by` and `login_role` today.

## Implementation Changes

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

### 6. Orchestration — [src/orchestrations/execute_function_graph.rs](../src/orchestrations/execute_function_graph.rs)

- When building the `ExecuteSqlInput` JSON, include `node.database`.
- No other changes needed—the orchestration itself doesn't care about the database.

### 7. Schema DDL — [src/lib.rs](../src/lib.rs)

- Add `database TEXT` column to both `CREATE TABLE` statements.

### 8. `execute_http` Activity

- No changes needed. HTTP requests don't target a database.

## Validation

When `df.start()` receives a non-NULL `database` parameter, we should validate that the database exists. This can be done via:

```sql
SELECT 1 FROM pg_database WHERE datname = $1
```

If the database doesn't exist, raise an error immediately rather than letting the background worker fail later with a confusing connection error.

**Role validation:** We do *not* need to validate that `login_role` can connect to the target database at `df.start()` time. The existing behavior already defers connection errors to activity execution time, which is appropriate for durable functions (the role/database might be created between `df.start()` and actual execution).

## Security Considerations

- **Role isolation is preserved.** The existing `login_role` / `submitted_by` / `SET ROLE` mechanism works identically regardless of target database. The user who calls `df.start()` determines the execution role, not the target database.
- **`pg_hba.conf` applies.** The background worker's `login_role` connection to a different database is subject to the same `pg_hba.conf` rules as any other connection. If the role can't connect to that database, the activity fails with a clear error.
- **No privilege escalation.** Targeting a different database doesn't grant additional privileges. The `SET ROLE` still constrains execution to the `submitted_by` role's permissions *in that database*.

## Observability

- `df.instances` and `df.nodes` gain a `database` column visible in `SELECT * FROM df.instances`.
- Background worker logs already include the SQL being executed; adding the database name to log messages in `execute_sql` would be helpful.
- `df.status()` and `df.result()` work unchanged—they query `df.instances`/`df.nodes` which are always in the extension database.

## Migration

- Existing rows in `df.instances` and `df.nodes` will have `database = NULL`, which correctly means "the extension database." No data migration needed.
- The schema change is additive (`ADD COLUMN ... DEFAULT NULL`), safe for rolling upgrades.

## Testing

### Unit Tests

- Verify `df.start()` accepts the new parameter.
- Verify NULL database defaults to `pg_durable.database`.

### E2E Tests

- **Same-database (regression):** Existing tests continue to pass without changes.

- **Cross-database test** (`NN_multi_database.sql`):

  Must run as **superuser** (add to the superuser list in `test-e2e-local.sh`) because it creates/drops a database. However, the durable function itself should be submitted by `df_e2e_user` (non-privileged) to validate that role isolation works across databases.

  ```sql
  -- 1. Setup: create test database and grant access to df_e2e_user
  CREATE DATABASE test_multi_db;
  GRANT CONNECT ON DATABASE test_multi_db TO df_e2e_user;

  -- 2. Create a table in the target database for df_e2e_user
  --    (use dblink since we can't switch databases mid-session)
  SELECT dblink_exec(
      'dbname=test_multi_db',
      'CREATE TABLE test_tbl (id INT, value TEXT)'
  );
  SELECT dblink_exec(
      'dbname=test_multi_db',
      'GRANT ALL ON test_tbl TO df_e2e_user'
  );

  -- 3. Submit durable function as df_e2e_user targeting test_multi_db
  SET SESSION AUTHORIZATION df_e2e_user;
  CREATE TEMP TABLE _test_state (instance_id TEXT);
  INSERT INTO _test_state SELECT df.start(
      df.sql('INSERT INTO test_tbl VALUES (1, ''hello'')'),
      database => 'test_multi_db'
  );
  RESET SESSION AUTHORIZATION;

  -- 4. Poll until complete (standard pattern)
  -- ...

  -- 5. Verify the row exists in test_multi_db
  SELECT * FROM dblink(
      'dbname=test_multi_db',
      'SELECT value FROM test_tbl WHERE id = 1'
  ) AS t(value TEXT);
  -- Assert value = 'hello'

  -- 6. Cleanup
  DROP TABLE _test_state;
  DROP DATABASE test_multi_db;
  ```

  Key aspects this test validates:
  - `df.start()` with `database =>` parameter works
  - SQL executes in the target database, not the extension database
  - Role isolation: function runs as `df_e2e_user`, not the background worker's superuser
  - `login_role` can connect to the target database (requires `GRANT CONNECT`)

- **Invalid database:** Verify `df.start(..., database => 'nonexistent')` raises an immediate error (not a deferred background worker failure).

## Scope Exclusions

- **Cross-database functions:** A single function graph spanning multiple databases (e.g., read from `db1`, write to `db2`) is not supported. This would require per-node database targeting, which adds significant DSL and orchestration complexity. Users can achieve this via `dblink`/`postgres_fdw` within SQL queries, or by starting separate durable functions per database.
- **Extension installation in multiple databases:** The extension continues to be installed in exactly one database. Supporting multiple installations would require distributed coordination between background workers.
- **Connection pooling per database:** Each SQL activity creates a fresh connection (existing behavior). Per-database connection pooling could improve performance but is orthogonal to this feature.

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
