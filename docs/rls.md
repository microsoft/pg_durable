# Row-Level Security (RLS) Design

**Status**: Draft  
**Branch**: `pinodeca/rls`  
**Created**: 2026-03-09

---

## 1. Motivation

pg_durable functions are all **SECURITY INVOKER** (the pgrx default — no function uses `security_definer`). This means every SQL statement inside a `df.*` function runs with the *calling user's* privileges, including table access checks.

Today, the E2E test setup manually grants DML on `df.instances`, `df.nodes`, and `df.vars` to each test user:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON df.instances TO df_e2e_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.nodes     TO df_e2e_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars      TO df_e2e_user;
```

Without table-level grants, `df.start()` would fail — it INSERTs into `df.nodes` and `df.instances` and SELECTs from `df.vars` via SPI, which runs as the calling user.

But granting unrestricted DML means:
- **Any user can read/modify any other user's instances and nodes** (confidentiality + integrity)
- **Any user can DELETE another user's instances** (destructive)
- **`df.vars` is a global key-value store** with no per-user scoping
- **No protection against cross-user `df.cancel()` / `df.signal()`** (the functions take an arbitrary instance_id and don't check ownership)

RLS solves this: keep the DML grants (users need them for the SPI calls inside `df.*` functions), but restrict which rows each user can see and modify.

---

## 2. Scope

### In scope

| Table | RLS needed? | Reason |
|-------|-------------|--------|
| `df.instances` | **Yes** | Contains per-user workflow state; has `submitted_by` column |
| `df.nodes` | **Yes** | Contains per-user node definitions; has `submitted_by` column |
| `df.vars` | **Yes** | Per-user variable isolation; has `owner` column |

### Out of scope

| Table / schema | Why |
|----------------|-----|
| `df._worker_epoch` | Internal sentinel; users should not have access at all (no GRANT) |
| `duroxide.*` tables | Internal runtime state; accessed only by the background worker's pooled connection (worker role). Users should not have direct access. The monitoring functions (`df.list_instances()`, `df.metrics()`, etc.) access these via a dedicated sqlx pool authenticated as the worker role, not via SPI-as-calling-user |
| `df.secrets` | Not yet implemented; when it lands, it should be admin-only (no user SELECT, no RLS — just REVOKE) |

### Functions that need RLS-aware data access

These `df.*` functions access `df.instances` or `df.nodes` via SPI (which runs as the calling user and therefore goes through RLS):

| Function | Tables accessed | Access type | RLS effect |
|----------|----------------|-------------|------------|
| `df.start()` | `df.nodes` (INSERT), `df.instances` (INSERT), `df.vars` (SELECT) | Write + Read | INSERT policies must allow; vars must be readable |
| `df.status()` | `df.instances` (SELECT) | Read | User sees only own instances |
| `df.result()` | `df.instances` (SELECT), `df.nodes` (SELECT) | Read | User sees only own |
| `df.cancel()` | `df.instances` (SELECT for ownership check) | Read | User can only cancel own instances |
| `df.signal()` | _(no direct table access — goes through duroxide client)_ | — | No RLS impact |
| `df.await_instance()` | `df.instances` (SELECT, polling) | Read | User sees only own |
| `df.explain()` | `df.nodes` (SELECT, for existing instances) | Read | User sees only own |
| `df.list_instances()` | `df.instances` (SELECT for labels) | Read | User sees only own labels |
| `df.instance_info()` | `df.instances` (SELECT for label) | Read | User sees only own |
| `df.instance_nodes()` | `df.nodes` (SELECT) | Read | User sees only own |
| `df.setvar()` | `df.vars` (INSERT/UPDATE) | Write | User can only set own vars (RLS + owner DEFAULT + ON CONFLICT) |
| `df.getvar()` | `df.vars` (SELECT) | Read | User can only read own vars (RLS + explicit owner filter) |
| `df.unsetvar()` | `df.vars` (DELETE) | Write | User can only delete own vars (RLS + explicit owner filter) |
| `df.clearvars()` | `df.vars` (DELETE) | Write | User can only clear own vars (RLS + explicit owner filter) |

### Background worker access (NOT affected by RLS)

The background worker accesses `df.instances` and `df.nodes` via sqlx pool connections authenticated as the worker role. The worker role must **bypass RLS** because it needs to load and update any user's instances/nodes:

| Activity | Tables accessed | Worker needs |
|----------|----------------|--------------|
| `load_function_graph` | `df.instances` (SELECT), `df.nodes` (SELECT) | Read all rows |
| `update_node_status` | `df.nodes` (UPDATE) | Update any row |
| `update_instance_status` | `df.instances` (UPDATE) | Update any row |
| `execute_sql` | _(User SQL on separate per-user connection)_ | Not applicable |

---

## 3. Design Decisions

### Decision 1: RLS policy column — `submitted_by` vs `current_user`

`df.instances.submitted_by` stores the effective role (outer user) captured at `df.start()` time as a `REGROLE`. The RLS policy compares this to `current_user`:

```sql
CREATE POLICY instances_user_isolation ON df.instances
    USING (submitted_by = current_user::regrole);
```

This is the correct choice because:
- `current_user` in an SPI call from a SECURITY INVOKER function = the calling user
- `submitted_by` is set by trusted extension code via `GetUserId()` — users cannot forge it
- `REGROLE` comparison handles OID-based identity correctly

**Decision**: Use `submitted_by = current_user::regrole`. ✅ No ambiguity.

### Decision 2: Separate INSERT policy for `df.start()`

`df.start()` inserts rows with `submitted_by` set to the calling user's OID. The USING clause applies to SELECT/UPDATE/DELETE. For INSERT, we need a WITH CHECK clause:

```sql
CREATE POLICY instances_user_isolation ON df.instances
    FOR ALL
    USING (submitted_by = current_user::regrole)
    WITH CHECK (submitted_by = current_user::regrole);
```

This ensures a user can only INSERT rows where `submitted_by` matches their own identity. Since `df.start()` sets `submitted_by` via `GetUserId()`, this is always true for legitimate calls. It also prevents a user from manually inserting a row with a forged `submitted_by`.

**Decision**: Single FOR ALL policy with both USING and WITH CHECK. ✅ No ambiguity.

### Decision 3: `df.nodes` policy — direct column vs join to `df.instances`

Two options:

**(A) Direct column check** (simpler, faster):
```sql
CREATE POLICY nodes_user_isolation ON df.nodes
    FOR ALL
    USING (submitted_by = current_user::regrole)
    WITH CHECK (submitted_by = current_user::regrole);
```

**(B) Join to instances** (single source of truth):
```sql
CREATE POLICY nodes_user_isolation ON df.nodes
    FOR ALL
    USING (
        instance_id IS NULL  -- unlinked nodes (during DSL building)
        OR EXISTS (SELECT 1 FROM df.instances WHERE id = instance_id AND submitted_by = current_user::regrole)
    )
    WITH CHECK (...);
```

**Analysis**:
- Option A is simpler and faster (no subquery). The `submitted_by` column on nodes is set by `df.start()` at the same time as `instance_id`, ensuring consistency.
- Option B adds a correctness dependency on `df.instances` — if `df.instances` rows are deleted, nodes become invisible even though they still exist. Adds query overhead.
- Unlinked nodes (`instance_id IS NULL` and `submitted_by IS NULL`): These are created during DSL expression building (e.g., `df.sql('SELECT 1')` before `df.start()`). They don't yet belong to any user. See Decision 4.

**Decision**: **Option A** — use direct column check on `df.nodes.submitted_by`. Simpler, no join overhead.

### ~~Decision 4: Unlinked nodes (pre-`df.start()`)~~ — NOT AN ISSUE

An earlier draft of this document stated that DSL functions like `df.sql()` insert rows into `df.nodes` with `submitted_by = NULL`. This is **incorrect**.

DSL functions (`df.sql()`, `df.seq()`, `df.sleep()`, etc.) do NOT insert rows into `df.nodes`. They build an in-memory JSON tree (the `Durofut` struct). All node rows are inserted inside `df.start()` via its internal `insert_nodes()` function, which sets `instance_id` and `submitted_by` on every node from the very start.

There are no "unlinked" or "orphan" nodes with `submitted_by = NULL`. Every row in `df.nodes` has `submitted_by` set at INSERT time.

**Decision**: No action needed. ✅ The simple RLS policy `submitted_by = current_user::regrole` works for both `df.instances` and `df.nodes` without any NULL handling.

> **Note on stale documentation**: [docs/user-isolation.md](user-isolation.md) (lines 112–164) describes a two-phase design where DSL functions insert nodes with NULL identity columns and `df.start()` later fills them via UPDATE. This was a design proposal, but the actual implementation took a different approach: nodes are only inserted inside `df.start()`, with identity set from the start. The `Durofut::insert_node()` method described in user-isolation.md does not exist in the codebase. The user-isolation.md doc should be updated to reflect the implemented design.

### Decision 5: `df.vars` scoping

`df.vars` was originally a global key-value table with no user scoping. The security spec (Section 4.3) identified this as a cross-user integrity/confidentiality issue.

**Decision**: Option A — per-user scoping with `owner` column + RLS. ✅ Implemented in v0.2.0.

**Schema** (fresh install):
```sql
CREATE TABLE IF NOT EXISTS df.vars (
    name TEXT NOT NULL,
    value TEXT,
    owner REGROLE NOT NULL DEFAULT current_user::regrole,
    PRIMARY KEY (owner, name)
);
```

**RLS policy**:
```sql
ALTER TABLE df.vars ENABLE ROW LEVEL SECURITY;

CREATE POLICY vars_user_isolation ON df.vars
    FOR ALL
    USING (owner = current_user::regrole)
    WITH CHECK (owner = current_user::regrole);
```

**Upgrade script** (`pg_durable--0.1.1--0.2.0.sql`):
```sql
ALTER TABLE df.vars ADD COLUMN owner REGROLE NOT NULL DEFAULT current_user::regrole;
ALTER TABLE df.vars DROP CONSTRAINT vars_pkey;
ALTER TABLE df.vars ADD PRIMARY KEY (owner, name);
ALTER TABLE df.vars ENABLE ROW LEVEL SECURITY;
CREATE POLICY vars_user_isolation ON df.vars ...;
```

**Superuser behavior**: Superusers bypass RLS, so they can see all users' variables via direct table queries. However, read/delete functions (`df.getvar()`, `df.unsetvar()`, `df.clearvars()`) and `df.start()` vars capture use explicit `WHERE owner = current_user::regrole` filters, while `df.setvar()` scopes ownership via the column DEFAULT and `ON CONFLICT (owner, name)`. This ensures that even superusers only interact with their own variables through the DSL functions — RLS is defense-in-depth for non-superusers, while the explicit scoping provides correct behavior for all users including superusers.

### Decision 6: Worker role RLS bypass

The background worker must read/write all users' instances and nodes. It also needs to connect as arbitrary users for `execute_sql`, access duroxide schema tables, and perform other privileged operations.

**Decision**: The worker role **must be a superuser**. ✅ Decided.

Superusers bypass all permission checks in PostgreSQL, including RLS. This means:
- No `BYPASSRLS` attribute needed (superusers bypass RLS automatically)
- No per-table worker policies needed
- No additional GRANTs to the worker role needed
- Consistent with the existing trust model: the extension is installed by a superuser, and the worker is trusted code

The worker role is configured via `pg_durable.worker_role` GUC (defaults to `postgres`). The extension should document that this role must be a superuser.

### Decision 7: `df.cancel()` and `df.signal()` ownership checks

Currently `df.cancel()` takes any `instance_id` and cancels it — no ownership check. With RLS on `df.instances`:
- `df.cancel()` does `UPDATE df.instances SET status = 'cancelled' WHERE id = ...` via SPI. RLS will silently filter out non-owned rows, so the UPDATE affects 0 rows. The duroxide `cancel_instance()` call is made *before* the UPDATE, and it bypasses RLS (goes through the client connection pool as the worker role).
- `df.signal()` uses `raise_external_event()` which goes directly through the duroxide client — no SPI table access. RLS does not apply.

**Issue**: `df.cancel()` and `df.signal()` can operate on other users' instances because the duroxide client calls bypass RLS. The SPI UPDATE in `df.cancel()` would be filtered by RLS, but the actual cancellation happens through the client.

**Options**:
**(A) Add explicit ownership check** in `df.cancel()` and `df.signal()` before calling the duroxide client:
```rust
// Check ownership via SPI (which goes through RLS)
let exists: bool = Spi::get_one(&format!(
    "SELECT EXISTS(SELECT 1 FROM df.instances WHERE id = '{instance_id}')"
)).ok().flatten().unwrap_or(false);
if !exists {
    pgrx::error!("Instance not found or access denied: {}", instance_id);
}
```
This leverages RLS: the SELECT returns false if the row exists but belongs to another user.

**(B) Rely on convention** — document that `df.cancel()` / `df.signal()` on a non-owned instance is a no-op.

**Decision**: Option A — explicit ownership check via SPI (which goes through RLS) before calling the duroxide client. ✅ Decided.

### Decision 8: GRANT strategy — extension install vs. manual

Should `CREATE EXTENSION pg_durable` automatically GRANT the right permissions to `PUBLIC` (or a specific role), or require manual GRANTs?

**Current state**: No automatic grants. Admins must explicitly grant privileges to application roles after `CREATE EXTENSION`. See README.md for details.

**Options** (historical — decision has been revised):
**(A) Extension sets default grants in `extension_sql!`**: (not used)
**(B) Extension grants to PUBLIC with minimal privileges**: (was used in v0.1.1, reverted for security)
**(C) Require manual grants** (current approach): Admin explicitly grants after `CREATE EXTENSION`.

**Decision**: Option C — no automatic grants. Admins must explicitly grant privileges to each application role. ✅ Revised.

> **Why the change?** While RLS mitigates the most obvious risks of broad PUBLIC grants, granting schema usage, function execution, and table DML to every database role by default is not desirable for production/security-sensitive environments. Requiring explicit grants follows the principle of least privilege.
>
> **Backward compatibility:** Existing installs that upgraded from v0.1.1 retain their PUBLIC grants. No REVOKE statements are added to upgrade scripts. Only fresh installs use the locked-down default.

---

## 4. Proposed RLS Policies

### 4.1 `df.instances`

```sql
ALTER TABLE df.instances ENABLE ROW LEVEL SECURITY;
-- No FORCE — superuser/table-owner bypasses RLS (see Decision 4.4)

CREATE POLICY instances_user_isolation ON df.instances
    FOR ALL
    USING (submitted_by = current_user::regrole)
    WITH CHECK (submitted_by = current_user::regrole);
```

### 4.2 `df.nodes`

```sql
ALTER TABLE df.nodes ENABLE ROW LEVEL SECURITY;

CREATE POLICY nodes_user_isolation ON df.nodes
    FOR ALL
    USING (submitted_by = current_user::regrole)
    WITH CHECK (submitted_by = current_user::regrole);
```

No `submitted_by IS NULL` clause is needed — all nodes are inserted by `df.start()` with `submitted_by` already set (see Decision 4).

### 4.3 `df.vars`

```sql
ALTER TABLE df.vars ENABLE ROW LEVEL SECURITY;

CREATE POLICY vars_user_isolation ON df.vars
    FOR ALL
    USING (owner = current_user::regrole)
    WITH CHECK (owner = current_user::regrole);
```

The `owner` column defaults to `current_user::regrole` on INSERT, so `df.setvar()` automatically assigns ownership via the column DEFAULT and `ON CONFLICT (owner, name)`. Read/delete functions (`df.getvar()`, `df.unsetvar()`, `df.clearvars()`) and `df.start()` vars capture include explicit `WHERE owner = current_user::regrole` filters for correct behavior when RLS is bypassed (superusers).

### 4.4 Worker bypass

The worker role must be a superuser (see Decision 6). Superusers bypass RLS automatically — no additional configuration needed.

```sql
-- No RLS bypass configuration needed.
-- The worker role (pg_durable.worker_role GUC, default: postgres) must be a superuser.
-- Superusers bypass all permission checks including RLS.
```

### 4.5 `FORCE ROW LEVEL SECURITY`

`ENABLE ROW LEVEL SECURITY` only applies RLS to non-owner roles. If the table owner queries the table, RLS is bypassed. `FORCE ROW LEVEL SECURITY` makes RLS apply even to the table owner.

Question: Should we use `FORCE`? In pg_durable, the table "owner" is whoever ran `CREATE EXTENSION` (typically the superuser). `FORCE` would make RLS apply even to the superuser, which may be undesirable for debugging. However, without `FORCE`, the superuser sees all rows — which is expected admin behavior.

**Recommendation**: Do NOT use `FORCE ROW LEVEL SECURITY` on any `df.*` table (`df.instances`, `df.nodes`, `df.vars`). Superusers should see all rows (standard PostgreSQL convention). The spec already notes that superusers are trusted (they install the extension). Additionally, the background worker runs as a superuser (see Decision 6) and must bypass RLS to manage all users' data — `FORCE` would break worker access.

Revised:
```sql
ALTER TABLE df.instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE df.nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE df.vars ENABLE ROW LEVEL SECURITY;
-- No FORCE on any table — superuser/table-owner bypasses RLS (standard behavior)
```

---

## 5. Implementation Plan

### Phase 1: Core RLS (this PR)

1. **Add RLS policies** in `extension_sql!` in `src/lib.rs`
   - Enable RLS on `df.instances` and `df.nodes`
   - Create user isolation policies
   - Handle worker role bypass

2. **Add ownership checks** to `df.cancel()` and `df.signal()` (Decision 7)
   - SELECT from `df.instances` (goes through RLS) before calling duroxide client

3. **No automatic GRANTs** — admins grant explicitly after `CREATE EXTENSION`
    - No GRANTs to PUBLIC in `extension_sql!`
    - Document the required grant set in README.md and USER_GUIDE.md

4. **Rework monitoring functions** for per-user visibility
   - `df.list_instances()`: Query `df.instances` via SPI first (RLS-filtered to calling user's rows), then use only those instance IDs when calling the duroxide client
   - `df.instance_info()`: Already queries `df.instances` via SPI for label — RLS filters automatically. Add ownership check before calling duroxide client
   - `df.instance_executions()`: Add ownership check (SPI query on `df.instances`) before calling duroxide client
   - `df.instance_nodes()`: Already queries `df.nodes` via SPI — RLS filters automatically
    - `df.metrics()`: System-wide metrics remain private by default. An ordinary `df.grant_usage()` omits it, fresh installs revoke PUBLIC EXECUTE, and admins can grant EXECUTE explicitly to trusted roles. `df.grant_usage('role', with_grant => true)` (a pg_durable admin) grants it automatically. ✅ Implemented in v0.2.4.

5. **Update E2E tests**
   - Remove manual grants from `00_setup_playground.sql` (now automatic)
   - Update `27_user_isolation.sql` to test RLS-enforced isolation
   - Add new RLS-specific tests

### Phase 2: Variables scoping ✅ Implemented (v0.2.0)

- Added `owner REGROLE` column to `df.vars` with `DEFAULT current_user::regrole`
- Changed PK from `(name)` to `(owner, name)` for per-user namespace
- Added RLS policy `vars_user_isolation` on `df.vars`
- Updated all DSL functions (`setvar`, `getvar`, `unsetvar`, `clearvars`) with explicit `owner` filters
- Updated `df.start()` vars capture to filter by `owner = current_user::regrole`
- Created upgrade script `sql/pg_durable--0.1.1--0.2.0.sql`
- Added E2E test `38_rls_vars.sql`

---

## 6. Open Questions

All decisions have been resolved. No open questions remain.

### Resolved decisions

- **Decision 5 (vars scoping)**: Option A implemented — per-user scoping with `owner` column + RLS. ✅ Implemented in v0.2.0.
- **Decision 6 (worker bypass)**: Worker role must be a superuser → bypasses RLS automatically. ✅
- **Decision 7 (cancel/signal ownership)**: Explicit ownership check before duroxide client call. ✅
- **Decision 8 (auto-grants)**: No automatic grants to PUBLIC. Admins must explicitly grant privileges to application roles after `CREATE EXTENSION`. ✅ Revised (was auto-grant to PUBLIC in v0.1.1).
- **Monitoring functions**: Rework `df.list_instances()`, `df.instance_info()`, `df.instance_executions()`, and `df.instance_nodes()` to only show the calling user's own instances. Currently these functions fetch instance IDs from the duroxide client (which returns ALL instances via the worker's connection), then join with `df.instances` for labels. With RLS, the SPI label query is already filtered — but the duroxide client still returns other users' instance IDs, causing a mismatch. Fix: query `df.instances` via SPI first (RLS-filtered), then use only those IDs when calling the duroxide client. ✅
- **`df.metrics()`**: Controlled by explicit EXECUTE grants (security review Finding 6, v0.2.4). `df.metrics()` exposes system-wide aggregate counts (total instances, running/completed/failed counts, total executions and events) from the duroxide store without per-user filtering. Fresh installs revoke PUBLIC EXECUTE, an ordinary `df.grant_usage()` does not grant it, `df.grant_usage('role', with_grant => true)` (a pg_durable admin) grants it WITH GRANT OPTION, and `df.revoke_usage()` removes explicit metrics grants so admins can revoke and re-grant ordinary access without metrics. Roles without explicit metrics access should use `df.list_instances()` to view a summary of their own workflows. ✅

---

## 7. Test Plan

### Unit tests
- Verify `submitted_by` is set on node creation (not just at `df.start()`)
- Verify RLS policies are created during `CREATE EXTENSION`

### E2E tests

**Test: User can only see own instances**
```sql
SET SESSION AUTHORIZATION alice;
SELECT df.start(df.sql('SELECT 1'), 'alice-job');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION bob;
SELECT count(*) FROM df.instances;  -- Should be 0
SELECT df.status('<alice-instance-id>');  -- Should return NULL
RESET SESSION AUTHORIZATION;
```

**Test: User cannot cancel another user's instance**
```sql
SET SESSION AUTHORIZATION alice;
SELECT df.start(df.sql('SELECT pg_sleep(10)'), 'alice-long-job');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION bob;
SELECT df.cancel('<alice-instance-id>');  -- Should fail or no-op
RESET SESSION AUTHORIZATION;
```

**Test: User cannot see another user's nodes**
```sql
SET SESSION AUTHORIZATION bob;
SELECT count(*) FROM df.nodes WHERE instance_id = '<alice-instance-id>';  -- Should be 0
RESET SESSION AUTHORIZATION;
```

**Test: Worker can access all instances**
- Verify the background worker can load/update instances from any user
- Verify workflows complete successfully with RLS enabled

**Test: `df.vars` per-user isolation** (implemented in `38_rls_vars.sql`)
```sql
SET SESSION AUTHORIZATION alice;
SELECT df.setvar('key', 'alice-value');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION bob;
SELECT df.getvar('key');  -- Returns NULL (per-user scoping)
SELECT df.setvar('key', 'bob-value');  -- Bob gets his own 'key'
RESET SESSION AUTHORIZATION;

-- Each user's df.start() captures only their own vars
-- df.clearvars() only clears the calling user's variables
-- Superuser sees all vars via direct table access but df.start() captures only own
```
