# User Isolation

pg_durable's background worker executes SQL on behalf of users. Without isolation, all SQL would run with the worker's privileges (typically superuser). User isolation ensures that SQL executed inside durable functions runs with the privileges of the user who submitted them.

## Design

The design has two parts:

1. **Track who submitted each durable function** — record `current_user` at `df.start()` time as `submitted_by`.
2. **Execute SQL as that user** — the background worker connects directly as `submitted_by`.

### Identity capture

pg_durable captures a single identity — `current_user` — at `df.start()` time using `pgrx::pg_sys::GetUserId()` ([src/dsl.rs](../src/dsl.rs#L628)). This OID is stored as `submitted_by` (type `REGROLE`) on both `df.nodes` and `df.instances`.

`current_user` must have the `LOGIN` attribute. This is validated at `df.start()` time ([src/dsl.rs](../src/dsl.rs#L632)). If `current_user` does not have LOGIN (e.g., after `SET ROLE` to a NOLOGIN group role), `df.start()` raises an error immediately.

DSL functions (`df.sql()`, `df.seq()`, etc.) build an in-memory JSON tree (`Durofut`). No rows are inserted into `df.nodes` until `df.start()` is called. Identity is captured **only** in `df.start()`, which is the single security boundary.

### SQL execution as `submitted_by`

When the background worker executes a SQL node, it creates a single `PgConnection` authenticated as `submitted_by` via `connect_as_user()` ([src/types.rs](../src/types.rs#L96)). SQL runs with `submitted_by`'s privileges. No `SET ROLE` is involved — the connection authenticates directly as the user.

The connection also sets `df.in_workflow = 'true'`, which currently prevents variable mutations (`setvar`/`unsetvar`/`clearvars`) during execution.

### `pg_hba.conf` requirement

The background worker connects to PostgreSQL as different users. This requires permissive authentication for local connections (e.g., `trust` or `peer` in `pg_hba.conf`). The extension does not manage credentials — authentication is delegated entirely to PostgreSQL.

## Schema

The `submitted_by REGROLE` column exists on both tables:

- **`df.instances`**: `NOT NULL` — every instance has an identity.
- **`df.nodes`**: Nullable in schema, but always set when a node is inserted by `df.start()`.

A composite unique constraint `UNIQUE (id, submitted_by)` on `df.instances` and a corresponding foreign key from `df.nodes` enforce referential integrity.

Row-Level Security (RLS) policies on both tables use `submitted_by = current_user::regrole` so that users can only see and insert their own rows.

## Key types

- **`Durofut`** ([src/types.rs](../src/types.rs)) — In-memory DSL representation. Has no identity fields.
- **`FunctionNode`** ([src/types.rs](../src/types.rs#L654)) — Runtime representation loaded from `df.nodes`. Includes `submitted_by: String`, used to establish the per-user connection.

## Scenarios

| Scenario | `current_user` | Connects as | Notes |
|----------|----------------|-------------|-------|
| Normal user | alice | alice | |
| `SET ROLE` to NOLOGIN role | analysts | — | Rejected at `df.start()` — no LOGIN |
| Inside `SECURITY DEFINER` fn | definer | definer | Runs with definer's privileges (expected) |
| Dropped role before execution | (deleted) | — | Connection fails, instance → `failed` |

### SECURITY DEFINER

Inside a `SECURITY DEFINER` function, `current_user` is the function owner (definer), not the caller. Durable functions submitted from `SECURITY DEFINER` wrappers run with the definer's privileges. This is standard PostgreSQL behavior.

### RESET ROLE

The connection authenticates directly as `submitted_by`. `RESET ROLE` reverts to the same user — a no-op. No privilege escalation is possible.

## `df.explain()`

`df.explain()` does not interact with user isolation. It builds a graph in memory (for DSL expressions) or reads existing nodes (for instance IDs) for visualization. It does not insert rows into `df.nodes` or `df.instances`, so `submitted_by` is not involved.

## Security properties

**Protected:**
- **Table access**: User A cannot access User B's tables through durable functions.
- **Privilege alignment**: SQL runs with the exact privileges the submitter had at `df.start()` time.
- **No escalation**: Non-superusers cannot gain elevated privileges.
- **RESET ROLE safety**: No-op since connection authenticates directly as `submitted_by`.

**Not protected:**
- **Superusers**: By default (`pg_durable.enable_superuser_instances = off`), superuser submissions are **blocked** — `df.start()` raises an error if `current_user` is a superuser, and the background worker rejects any instance whose `submitted_by` resolves to a superuser at execution time. Set `enable_superuser_instances = on` to opt in for administrative use cases. See [superuser_guc.md](superuser_guc.md).
- **SECURITY DEFINER**: Runs as definer, not caller (expected; documented above).
- **DoS**: No rate limiting on durable function submissions.

**Trust model:**
- Extension installation requires superuser.
- The background worker is trusted code running inside PostgreSQL.
- Authentication is delegated to `pg_hba.conf`.
- Similar to `pg_cron`, which also executes jobs as specific database roles.

## Tests

- [tests/e2e/sql/27_user_isolation.sql](../tests/e2e/sql/27_user_isolation.sql) — Basic isolation (alice/bob), NOLOGIN group role rejection, SECURITY DEFINER behavior, dropped role handling.
- [tests/e2e/sql/37_rls.sql](../tests/e2e/sql/37_rls.sql) — Row-Level Security policy enforcement on `df.instances` and `df.nodes`.
- [tests/e2e/sql/38_rls_vars.sql](../tests/e2e/sql/38_rls_vars.sql) — RLS enforcement on `df.vars`.
- [tests/e2e/sql/25_extension_creation_security.sql](../tests/e2e/sql/25_extension_creation_security.sql) — Extension creation requires superuser.
- [tests/e2e/sql/17_superuser_guc.sql](../tests/e2e/sql/17_superuser_guc.sql) — `pg_durable.enable_superuser_instances` GUC enforcement: superuser rejection (GUC off), superuser submission (GUC on), non-superuser unaffected, BYPASSRLS forgery rejection by the worker.

## History

v0.1.1 captured two identities: `login_role` (the session's authenticated user, via `GetSessionUserId()`) and `submitted_by` (the effective user, via `GetOuterUserId()`). The background worker connected as `login_role` and then ran `SET ROLE submitted_by` before executing SQL. This two-user model handled the case where a user did `SET ROLE` to a NOLOGIN group role — the worker could still authenticate as the original login role.

In v0.2.0, `login_role` was dropped and the model simplified to a single `submitted_by` column. The added complexity of tracking two identities (extra column, composite constraints, `SET ROLE` in the worker, more nuanced RLS policies) was not justified at pg_durable's current stage of maturity and adoption.

The identity function also changed from `GetOuterUserId()` to `GetUserId()` (`current_user`). pg_durable does not use `SECURITY DEFINER` functions internally, so the distinction only matters for external callers — function authors can choose whether to call `df.start()` from a `SECURITY DEFINER` or `SECURITY INVOKER` function, and the captured identity will reflect that choice.

**Backward compatibility:** The new binary still works with the v0.1.1 schema shape because it detects the legacy tables and continues to populate `login_role` on inserts until the customer runs `ALTER EXTENSION UPDATE`. Pre-existing v0.1.1 instances also continue to run when `submitted_by` itself has the `LOGIN` attribute, because the worker now authenticates directly as `submitted_by`.

**Breaking edge case:** pg_durable no longer preserves the old `login_role + SET ROLE submitted_by` execution path. A pending or running v0.1.1 instance whose `submitted_by` is a NOLOGIN role from the old `SET ROLE` workflow will fail after the binary upgrade, regardless of whether `ALTER EXTENSION UPDATE` has been run. Those instances must be allowed to finish before upgrading, or be recreated afterward under the new model.

## Future work

- **Execution context capture**: Add an `execution_context JSONB` column to capture environment settings like `search_path`, `statement_timeout`, `work_mem`, etc. The `submitted_by` column remains a strongly-typed `REGROLE` because it's security-critical. Execution context is supplementary and may evolve, making JSONB more appropriate.
