# User Isolation: Design & Implementation Guide

## Scope & Assumptions (for this proposal)

This proposal intentionally focuses on **privilege isolation for SQL execution** in the background worker.

**Assumptions:**

- **Local TCP trust auth** is configured for the test/development environment (pg_durable currently uses TCP, not Unix domain sockets). This allows the worker to open connections as specific database roles without managing passwords.
- This repository has not had a first release yet; **upgrade/migration** concerns are out of scope for this proposal.

**Explicitly out of scope (acknowledged future work):**

- Hardening `df.instances` / `df.nodes` against direct manipulation by untrusted roles.
- Capturing/restoring the submitter's execution environment (e.g. `search_path`, GUCs like `statement_timeout`, etc.).
- Performance optimizations such as per-instance connection reuse / caching.

## Problem

pg_durable's background worker executes SQL on behalf of users. Without isolation, all SQL runs with the background worker's privileges (typically a superuser or the OS user running PostgreSQL). This means any user who can call `df.start()` can execute arbitrary SQL with elevated privileges.

**Goal:** SQL executed inside durable functions must run with the privileges of the user who submitted them — not the background worker's privileges.

## Design Overview

The solution has two parts:

1. **Track who submitted each durable function** — record both the session user and the outer user at `df.start()` time.
2. **Execute SQL as that user** — connect as the session user (who has LOGIN), then `SET ROLE` to the outer user to get the correct effective privileges.

These two parts are deliberately separable: tracking can land first (data model change, no behavior change), and per-user execution can follow.

### Why Track Two Users?

PostgreSQL maintains a stack of user identities. The relevant ones for our purposes:

| Function | SQL equivalent | Meaning | Has LOGIN? |
|----------|---------------|---------|------------|
| `GetSessionUserId()` | `session_user` | The role that authenticated the connection | Always yes |
| `GetOuterUserId()` | `current_user` (outside SECURITY DEFINER) | The effective role outside any SECURITY DEFINER boundary | Not necessarily |
| `GetUserId()` | `current_user` | The current effective role (changes inside SECURITY DEFINER) | Not necessarily |

**`GetOuterUserId()` is what we want for `submitted_by`.** It returns:
- The same as `current_user` during normal operation (including after `SET ROLE`)
- The **caller's** identity when inside a `SECURITY DEFINER` function — not the definer's identity

This is exactly right: if a user calls a `SECURITY DEFINER` wrapper around `df.start()`, we want to execute as the *calling* user, not the function owner.

**`GetSessionUserId()` is what we want for `login_role`.** It is the authenticated identity — always has `LOGIN`, guaranteed stable for the entire session.

**Execution strategy:**
1. **Connect** as `login_role` / `session_user` (guaranteed to have `LOGIN`)
2. **`SET ROLE`** to `submitted_by` / outer user (gets the correct effective privileges)
3. **Execute** the SQL

This correctly handles all scenarios:

| Scenario | `session_user` | `GetOuterUserId` | Connect as | SET ROLE to |
|----------|----------------|-------------------|------------|-------------|
| Normal user | alice | alice | alice | alice (no-op) |
| After `SET ROLE` | alice | analysts (group) | alice | analysts |
| Inside `SECURITY DEFINER` fn | alice | alice | alice | alice |
| `SET ROLE` then `SECURITY DEFINER` fn | alice | analysts | alice | analysts |

### No SPI Helpers Needed

The user IDs are captured via direct `pgrx::pg_sys` calls — no SPI round-trip required:

```rust
// These are all available in pgrx::pg_sys and return Oid:
pgrx::pg_sys::GetSessionUserId()   // -> Oid (login_role)
pgrx::pg_sys::GetOuterUserId()     // -> Oid (submitted_by)
pgrx::pg_sys::GetUserId()          // -> Oid (current effective user)
pgrx::pg_sys::GetAuthenticatedUserId() // -> Oid (original authenticated user)

// To resolve Oid to a role name string:
pgrx::pg_sys::GetUserNameFromId(oid, false) // -> *mut c_char (false = error if not found)
```

These are guaranteed to always return a valid OID in any PostgreSQL session — no NULL checks or fallbacks needed.

## Part 1: Tracking User Identity

### Schema Changes

Add `submitted_by` and `login_role` columns to both tables:

```sql
-- df.nodes
ALTER TABLE df.nodes
    ADD COLUMN submitted_by REGROLE,    -- outer user (effective privileges)
    ADD COLUMN login_role   REGROLE;    -- session user (login identity)

COMMENT ON COLUMN df.nodes.submitted_by IS
    'Effective role (outer user) for privilege isolation. Set by df.start() when node is linked to an instance.';
COMMENT ON COLUMN df.nodes.login_role IS
    'Authenticated role (session user) for connection authentication. Set by df.start() when node is linked to an instance.';

-- df.instances
ALTER TABLE df.instances
    ADD COLUMN submitted_by REGROLE NOT NULL,
    ADD COLUMN login_role   REGROLE NOT NULL;

COMMENT ON COLUMN df.instances.submitted_by IS
    'Effective role (outer user) when df.start() was called - used for SET ROLE during execution';
COMMENT ON COLUMN df.instances.login_role IS
    'Authenticated role (session user) when df.start() was called - used for connection authentication';
```

The `REGROLE` type is a PostgreSQL OID alias that stores the role OID but displays as the role name. It resolves correctly even if the role is renamed, and raises an error at INSERT time if the role doesn't exist.

**Important invariant:** On `df.nodes`, these columns are **nullable** and only set when a node is linked to an instance by `df.start()`. Unlinked nodes (created by DSL functions but not yet started) have `NULL` for both columns. On `df.instances`, they are `NOT NULL` — every instance always has identity.

### Where Identity Is Captured: Only in `df.start()`

Unlike earlier designs, DSL functions (`df.sql()`, `df.seq()`, etc.) do **not** capture user identity. Nodes are created without `submitted_by` or `login_role` — these columns remain NULL until the node is linked to an instance.

Identity is captured **only** in `df.start()`, which is the security boundary. This simplifies the DSL functions and ensures a single authoritative capture point.

#### `df.start()` — instance creation and node linking

When `df.start()` is called, three things happen:

**a) Capture identity in Rust:**
```rust
let session_user_oid = unsafe { pgrx::pg_sys::GetSessionUserId() };
let outer_user_oid = unsafe { pgrx::pg_sys::GetOuterUserId() };
```

We intentionally keep these values as **OIDs**. PostgreSQL's `REGROLE` type stores role OIDs and renders them as names for display.

**b) Instance row is created with both identity columns:**
```sql
INSERT INTO df.instances (id, label, root_node, status, submitted_by, login_role)
VALUES (
    '{id}',
    {label},
    '{root_node}',
    'pending',
    {outer_user_oid}::oid::regrole,
    {session_user_oid}::oid::regrole
)
```

**c) All nodes in the graph are linked and their identity columns are set** from the instance:
```sql
UPDATE df.nodes
SET instance_id  = '{instance_id}',
    submitted_by = {outer_user_oid}::oid::regrole,
    login_role   = {session_user_oid}::oid::regrole
WHERE id = '{node_id}'
```

### The `Durofut::insert_node()` change

The `insert_node()` method writes nodes to `df.nodes` but does **not** set `submitted_by` or `login_role`. These columns are omitted from the INSERT (they will be NULL):

```sql
INSERT INTO df.nodes (id, node_type, query, result_name, left_node, right_node)
VALUES ('abcd1234', 'SQL', 'SELECT 1', NULL, NULL, NULL)
-- submitted_by and login_role are NULL until df.start() links this node
```

This means the DSL functions and `Durofut` struct do not need `submitted_by` or `login_role` fields at all. These are only on `FunctionNode` (the runtime representation loaded from the database).

### Rust struct changes

Only `FunctionNode` gains the two identity fields. `Durofut` is unchanged.

```rust
pub struct FunctionNode {
    pub id: String,
    pub node_type: String,
    pub query: Option<String>,
    pub result_name: Option<String>,
    pub left_node: Option<String>,
    pub right_node: Option<String>,
    /// Effective role (outer user) for privilege isolation
    pub submitted_by: String,
    /// Authenticated role (session user) for connection authentication
    pub login_role: String,
}

// Durofut is UNCHANGED — no identity fields needed
pub struct Durofut {
    pub node_id: String,
    pub node_type: String,
    pub left_node: Option<String>,
    pub right_node: Option<String>,
    pub query: Option<String>,
    pub result_name: Option<String>,
}
```

### Loading identity from the database

The `load_function_graph` activity reads nodes from `df.nodes`. The query must include both columns, cast to text:

```sql
SELECT id, node_type, query, result_name,
       left_node, right_node,
       submitted_by::text AS submitted_by,
       login_role::text AS login_role
FROM df.nodes WHERE instance_id = '{instance_id}'
```

These are guaranteed to be non-NULL for linked nodes (the only ones queried here).

### `df.explain()` — no changes needed

The explain function creates a temporary table for dry-run visualization. Since `df.explain()` only builds the node graph without starting an instance, and identity columns are only set at `df.start()` time, the explain temporary table does **not** need `submitted_by` or `login_role` columns.

## Part 2: Executing SQL as the Submitting User

### Approach: Connect as `session_user`, then `SET ROLE` to outer user

When the background worker needs to execute a SQL node, instead of using its shared `PgPool`, it:

1. Creates a **single `PgConnection`** authenticated as `login_role` (the session user)
2. Runs `SET ROLE {submitted_by}` on the connection to switch to the effective role
3. Executes the SQL with the correct privileges

### Single connection, not a pool

Use `sqlx::postgres::PgConnection::connect_with()` to create a single connection per SQL execution, rather than creating a pool:

```rust
use sqlx::postgres::PgConnection;
use sqlx::Connection;

/// Create a single PostgreSQL connection authenticated as `login_role`,
/// then SET ROLE to `effective_role`.
pub async fn connect_as_user(
    login_role: &str,
    effective_role: &str,
) -> Result<PgConnection, String> {
    let mut options = PgConnectOptions::new()
        .username(login_role)
        .database(&target_database())
        .port(get_port().parse::<u16>().unwrap_or(5432));

    // Set socket directory if configured
    let host = get_host();
    if !host.is_empty() {
        options = options.host(&host);
    }

    let mut conn = PgConnection::connect_with(&options)
        .await
        .map_err(|e| format!(
            "Failed to connect as '{}' (for effective role '{}'). Error: {}",
            login_role, effective_role, e
        ))?;

    // Switch to effective role if different from login role
    if login_role != effective_role {
        sqlx::query(&format!("SET ROLE \"{}\"", effective_role.replace('"', "\"\"")))
            .execute(&mut conn)
            .await
            .map_err(|e| format!("SET ROLE {} failed: {}", effective_role, e))?;
    }

    // Mark this connection as running inside a workflow.
    // Currently used to prevent variable mutations (setvar/unsetvar/clearvars)
    // during execution. Could also be checked in df.start() to prevent
    // recursive workflow invocation in a future improvement.
    sqlx::query("SET df.in_workflow = 'true'")
        .execute(&mut conn)
        .await
        .map_err(|e| format!("SET df.in_workflow failed: {}", e))?;

    Ok(conn)
}
```

Key details:
- **Single connection**: `PgConnection` is a single, non-pooled connection. Created when needed, dropped when done.
- **`SET ROLE` skipped when roles match**: The common case (no `SET ROLE` was active) avoids the extra round-trip.
- **`SET df.in_workflow = 'true'`**: Marks the connection as running inside a workflow. Currently prevents variable mutations (`setvar`/`unsetvar`/`clearvars`) during execution. Does not yet prevent recursive `df.start()` calls — that is a potential future improvement.
- **Identifier quoting**: Role names are double-quoted with internal `"` escaped to `""`.

#### Future: Connection reuse across nodes in the same instance

Opening a new connection per SQL node is correct but has overhead. A natural optimization:

**Proposed approach — instance-scoped connection cache:**
- When the first SQL node for an instance executes, create the connection and cache it keyed by `(instance_id, login_role, submitted_by)`.
- Subsequent SQL nodes for the same instance reuse the cached connection.
- The connection is closed when the instance orchestration completes (or fails).

This works because all nodes in an instance share the same `login_role` and `submitted_by` (they're propagated from the instance). The cache could live as a thread-local or be passed through the orchestration context.

**Trade-offs:**
- Reduces connection overhead from O(nodes) to O(instances)
- Must handle connection failures mid-instance (reconnect and re-SET ROLE)
- Must ensure the connection is closed even if the orchestration panics (Drop impl or explicit cleanup)

This optimization is deferred to a follow-up.

### Activity input change

The `execute_sql` activity previously received a plain SQL string. It now receives a JSON object containing the query and both user identities:

```rust
#[derive(Serialize, Deserialize)]
struct ExecuteSqlInput {
    query: String,
    submitted_by: String,
    login_role: String,
}
```

### Orchestration change (deterministic code)

In `execute_function_graph.rs`, the orchestration packages the query and both identities together before scheduling the activity:

```rust
let input = serde_json::json!({
    "query": final_query,
    "submitted_by": node.submitted_by,
    "login_role": node.login_role,
});

let result = ctx
    .schedule_activity(activities::execute_sql::NAME, input.to_string())
    .into_activity()
    .await?;
```

This is safe for determinism: both values come from the `FunctionGraph` which was loaded via a prior activity. They are stable across replays.

### Activity registration change

The activity registry signature changes from `query: String` to `input_json: String`:

```rust
ActivityRegistry::builder()
    .register(
        activities::execute_sql::NAME,
        move |ctx: ActivityContext, input_json: String| {
            let pool = sql_pool.clone();
            async move { activities::execute_sql::execute(ctx, pool, input_json).await }
        },
    )
```

### The `execute_sql` activity

```rust
pub async fn execute(
    ctx: ActivityContext,
    _pool: Arc<PgPool>,       // shared pool — not used for user SQL
    input_json: String,
) -> Result<String, String> {
    let input: ExecuteSqlInput = serde_json::from_str(&input_json)
        .map_err(|e| format!("Invalid execute_sql input: {e}"))?;

    ctx.trace_info(format!(
        "Executing SQL as '{}' (connected as '{}'): {}",
        input.submitted_by, input.login_role, input.query
    ));

    // Create a single connection as login_role, SET ROLE to submitted_by
    let mut conn = connect_as_user(&input.login_role, &input.submitted_by).await?;

    // Execute with the effective user's privileges
    match sqlx::query(&input.query).fetch_all(&mut conn).await {
        Ok(rows) => { /* serialize results as JSON */ }
        Err(e) => Err(format!("SQL error: {e}"))
    }
    // conn is dropped here — connection closed
}
```

### `pg_hba.conf` requirement

The background worker connects to PostgreSQL as different users. This requires permissive authentication for local connections:

```
# pg_hba.conf — allow the background worker to connect as any local user
local   all   all   trust
```

Or with peer authentication (more secure — verifies the OS user matches):
```
local   all   all   peer
```

In development with pgrx (TCP connections), trust auth on localhost is typical:
```
host    all   all   127.0.0.1/32   trust
```

For this proposal we assume this local trust configuration is acceptable.

### Worker tracing adjustment

Per-user connections via sqlx generate noisy warnings about missing `.pgpass` files (since we use trust/peer auth, not passwords). Filter these:

```rust
EnvFilter::new(
    "warn,duroxide::orchestration=info,duroxide::activity=info,sqlx_postgres::options::pgpass=error"
)
```

---

## Dropped Role Behavior

If the `login_role` or `submitted_by` role is dropped between submission and execution, the behavior is:

- **Connection as `login_role` fails**: sqlx/libpq will return an authentication error since the role no longer exists. The activity returns an error, and the instance transitions to `failed` status.
- **`SET ROLE submitted_by` fails**: The connection succeeds (as `login_role`), but `SET ROLE` returns an error because the target role doesn't exist. Same outcome — activity error, instance fails.

This is the correct behavior: a dropped role cannot execute SQL. No special handling is needed, but we should have an E2E test that verifies the failure mode and produces a clear error message.

---

## Security Properties

### What this protects

- **Table access**: User A cannot read/write User B's tables through durable functions.
- **Privilege alignment**: SQL runs with the exact same effective role as the submitter had at `df.start()` time.
- **Group roles**: `SET ROLE analysts` before `df.start()` correctly executes with `analysts` privileges, even though `analysts` has no `LOGIN`.
- **SECURITY DEFINER safety**: Using `GetOuterUserId()` means that even if `df.start()` is called inside a `SECURITY DEFINER` function, we capture the *caller's* identity, not the definer's.
- **No escalation**: A non-superuser cannot gain superuser privileges by submitting a durable function.

### What this does NOT protect

- **Superusers**: A superuser's durable functions run with superuser privileges (expected behavior).
- **DoS**: No rate limiting on durable function submissions.
- **Cross-instance visibility**: Any user with `SELECT` on `df.instances` can see all instances. Row-level security (RLS) is future work.

### Role membership requirement

For the `SET ROLE` to succeed, the `login_role` (session user) must be a **member** of `submitted_by` (outer user). In normal PostgreSQL usage, this is always satisfied:
- If no `SET ROLE` was used, both are the same role.
- If `SET ROLE analysts` was used, the session user must already be a member of `analysts` (otherwise PostgreSQL would have rejected the `SET ROLE` in the original session).

So the membership invariant is guaranteed by PostgreSQL itself — we're replaying the same role relationship.

### Trust model

- Extension installation requires superuser (`CREATE EXTENSION pg_durable`).
- The background worker is trusted code running inside PostgreSQL.
- Authentication is delegated to PostgreSQL's `pg_hba.conf` — the extension does not manage credentials.
- This model is similar to `pg_cron`, which also executes jobs as specific database roles.

---

## Files Changed (Implementation Checklist)

| File | Change |
|------|--------|
| `src/lib.rs` | Add `submitted_by REGROLE` and `login_role REGROLE` columns to `df.nodes` (nullable) and `df.instances` (NOT NULL) DDL; add column comments |
| `src/types.rs` | Add `submitted_by` and `login_role` fields to `FunctionNode` only (not Durofut); add `connect_as_user(login_role, effective_role)` returning a single `PgConnection`; no changes to `Durofut` or `insert_node()` |
| `src/dsl.rs` | Only `df.start()` changes: capture `GetSessionUserId()` and `GetOuterUserId()`, write both to instance row, propagate both to nodes via UPDATE |
| `src/activities/execute_sql.rs` | Add `ExecuteSqlInput` struct with `query`, `submitted_by`, `login_role`; use `connect_as_user()` for a single connection; execute SQL on that connection |
| `src/activities/load_function_graph.rs` | Add `submitted_by::text` and `login_role::text` to SELECT; map both into `FunctionNode` |
| `src/orchestrations/execute_function_graph.rs` | Package `query` + `submitted_by` + `login_role` as JSON input when scheduling `execute_sql` activity |
| `src/registry.rs` | Change activity registration from `query: String` to `input_json: String` |
| `src/worker.rs` | Filter `sqlx_postgres::options::pgpass` warnings from tracing |

**Not changed:** `src/explain.rs` (explain does not use identity columns), `Durofut` struct, DSL functions other than `df.start()`.

## E2E Test Strategy

### Baseline: run E2E as a non-privileged role

Today, E2E tests commonly connect as a superuser (`postgres` in Docker, `$USER` in local pgrx). For user-isolation work, we want the default E2E posture to be:

- **Run most E2E tests as a non-privileged login role**, created by setup.
- Keep a small number of tests that must run as **superuser** (extension installation/security tests, and an explicit “superuser durable function” scenario).

Proposed mechanics:

- Update `tests/e2e/sql/00_setup_playground.sql` to:
    - Create a role like `df_e2e_user` (LOGIN, non-superuser)
    - Grant it the minimum privileges needed for the existing E2E suite (schema `df` usage + execute, and the current table privileges required by `df.start()`'s implementation)
    - Ensure `playground` objects are accessible (ideally owned by `df_e2e_user`)

- Update the **local** E2E runner (`./scripts/test-e2e-local.sh`) to:
    - Run `00_setup_playground.sql` as superuser
    - Run most tests as `df_e2e_user`
    - Run `25_extension_creation_security.sql` as superuser
    - Add a new test (e.g. `26_superuser_*.sql`) that runs as superuser and verifies a superuser-only query inside `df.start(df.sql(...))` succeeds.

Docker E2E runner changes are intentionally **deferred**.

### Test 1: Basic isolation

Create two database users, each with their own table:

1. **User A can access their own table** via a durable function → completes successfully
2. **User A cannot access User B's table** → fails with "permission denied"
3. **User B can access their own table** → completes successfully
4. **User B cannot access User A's table** → fails with "permission denied"

### Test 2: `SET ROLE` with a group role (no LOGIN)

Validates that we connect as `session_user` and SET ROLE to the group:

```sql
CREATE ROLE analysts NOLOGIN;
CREATE TABLE analyst_data (id INT, value TEXT);
ALTER TABLE analyst_data OWNER TO analysts;

CREATE USER alice LOGIN;
GRANT analysts TO alice;

-- Grant df permissions to alice
GRANT USAGE ON SCHEMA df TO alice;
GRANT EXECUTE ON FUNCTION df.start, df.sql, df.status, df.result TO alice;
GRANT SELECT, INSERT, UPDATE ON df.instances, df.nodes TO alice;
GRANT SELECT ON df.vars TO alice;

-- Submit with SET ROLE
SET SESSION AUTHORIZATION alice;
SET ROLE analysts;
-- session_user = alice, current_user (outer) = analysts
SELECT df.start(df.sql('SELECT * FROM analyst_data'), 'analyst-query');
RESET ROLE;
RESET SESSION AUTHORIZATION;

-- Expected: login_role = alice, submitted_by = analysts
-- Worker connects as alice, SET ROLE analysts, query succeeds
```

### Test 3: `SECURITY DEFINER` function

Validates that `GetOuterUserId()` correctly captures the caller, not the definer:

```sql
CREATE USER bob LOGIN;
GRANT USAGE ON SCHEMA df TO bob;
GRANT EXECUTE ON FUNCTION df.start, df.sql, df.status, df.result TO bob;
GRANT SELECT, INSERT, UPDATE ON df.instances, df.nodes TO bob;
GRANT SELECT ON df.vars TO bob;

CREATE TABLE bob_data (value TEXT);
ALTER TABLE bob_data OWNER TO bob;
INSERT INTO bob_data VALUES ('bob secret');

-- Create a SECURITY DEFINER wrapper owned by superuser
CREATE OR REPLACE FUNCTION submit_query(q TEXT) RETURNS TEXT
LANGUAGE SQL SECURITY DEFINER
AS $$
    SELECT df.start(df.sql(q), 'secdef-test');
$$;
GRANT EXECUTE ON FUNCTION submit_query TO bob;

-- Bob calls the SECURITY DEFINER function
SET SESSION AUTHORIZATION bob;
SELECT submit_query('SELECT * FROM bob_data');
RESET SESSION AUTHORIZATION;

-- Expected: login_role = bob, submitted_by = bob (NOT superuser)
-- Because GetOuterUserId() returns the caller's identity outside the SECURITY DEFINER
-- Worker connects as bob, runs as bob, can access bob_data
```

### Test 4: `SECURITY DEFINER` + unauthorized access

Same setup, but Bob tries to access a table he shouldn't:

```sql
CREATE TABLE admin_secrets (value TEXT);
INSERT INTO admin_secrets VALUES ('classified');
-- admin_secrets owned by superuser, bob has no access

SET SESSION AUTHORIZATION bob;
SELECT submit_query('SELECT * FROM admin_secrets');
RESET SESSION AUTHORIZATION;

-- Expected: FAILS - bob cannot access admin_secrets
-- Even though submit_query is SECURITY DEFINER owned by superuser,
-- the durable function runs as bob
```

### Test 5: Dropped role at execution time

Validates that a clear error is produced if the submitting role is dropped before execution:

```sql
CREATE USER ephemeral_user LOGIN;
-- Grant df permissions...

SET SESSION AUTHORIZATION ephemeral_user;
SELECT df.start(df.sql('SELECT 1'), 'ephemeral-test');
RESET SESSION AUTHORIZATION;

-- Drop the user before the worker picks up the job
-- (may need to add a delay mechanism or pause the worker)
DROP OWNED BY ephemeral_user;
DROP USER ephemeral_user;

-- Expected: instance transitions to 'failed' with a clear error message
-- about the role not existing
```

### Setup requirements

Test users need `GRANT` of `df` schema usage, execute on `df.start`/`df.sql`/`df.status`/`df.result`, and `SELECT`/`INSERT`/`UPDATE` on `df.instances` and `df.nodes`.

---

## Future Work

- **Execution context capture (hybrid approach)**: Add a `execution_context JSONB` column to capture environment settings like `search_path`, `statement_timeout`, `work_mem`, etc. Identity fields (`login_role`, `submitted_by`) remain strongly-typed `REGROLE` columns because they're security-critical and benefit from type validation. Execution context is supplementary and may evolve, making JSONB more appropriate for flexibility.
- **Connection reuse across nodes**: Cache connections keyed by `(instance_id, login_role, submitted_by)` and reuse across SQL nodes within the same instance execution. Close on instance completion.
- **SPI-based execution**: Instead of opening a new connection, use `SetUserIdAndSecContext()` to switch the effective user within the background worker process. This would eliminate connection overhead entirely and remove the `pg_hba.conf` trust requirement.
- **Row-level security**: Apply RLS to `df.instances` and `df.nodes` so users can only see their own submissions.
- **Per-user `df.vars` and `df.secrets`**: Currently shared across all users.
- **HTTP activity scoping**: URL allowlists or per-user SSRF protection.
