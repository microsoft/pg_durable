# Spec: df.http() Function Permissions

> **Status:** Implemented (see implementation plan below).
> This spec is a retroactive design record for the changes landed in
> PR #100. Once `docs/http-security.md` has been updated to reflect this
> design, this file can be deleted — `http-security.md` is the authoritative
> reference.

---

## Problem

`df.http()` makes outbound network requests from within the PostgreSQL
background worker. Prior to this change, any role granted `df.grant_usage()`
— or one that existed before the default-PUBLIC-grant removal in v0.2.0 —
automatically had access to HTTP. There was no way to allow a role to use
durable functions without also enabling outbound HTTP.

A secondary problem: a user who knows the Durofut JSON schema can call
`df.start()` directly with a hand-crafted HTTP node, bypassing the DSL-time
guard inside `df.http()`. The original design relied on the DSL function as
the only gate.

---

## Goals

1. HTTP access must be **opt-in**, separate from general `df` access.
2. The privilege check must be **enforced at execution time**, not only at DSL
   construction time, so that raw `df.start()` JSON injection is also blocked.
3. The privilege check must be enforced **regardless of which HTTP Cargo
   feature is enabled**. (This is moot when HTTP is entirely disabled at build
   time, since the activity rejects all requests unconditionally.)
4. Admins must be able to **revoke HTTP access** from a role without removing
   all `df` access.
5. The design must work for **fresh installs** (v0.2.0+) and for
   **upgrades from v0.1.1**.
6. `df.grant_usage()` and `df.revoke_usage()` are **admin-only** functions;
   `PUBLIC` must not retain the default `EXECUTE` privilege on them.

---

## Design

### 1. Revoke PUBLIC EXECUTE on df.http() at install time

PostgreSQL grants `EXECUTE` to `PUBLIC` by default when a function is created.
This is overridden immediately after `df.http()` is created, in the
`rls_and_grants` extension SQL block:

```sql
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM PUBLIC;
```

This means fresh installs (v0.2.0+) have no public HTTP access at all.

### 2. df.start() DSL-time check

When a user calls `df.http(url, method, ...)` directly as part of building a
`df.start()` expression, the Rust `#[pg_extern] fn http(...)` runs in the
calling session under the user's privileges. Because `EXECUTE` on `df.http` has
been revoked from `PUBLIC`, PostgreSQL itself enforces the privilege at that
point — no explicit check is needed in the Rust code.

### 3. Execution-time privilege check (bypass prevention)

A user can bypass the DSL-time check by constructing a raw Durofut JSON string
and passing it directly to `df.start()`:

```sql
SELECT df.start(
    '{"node_type":"HTTP","query":"{\"url\":\"https://example.com\"}"}',
    'my-label'
);
```

This inserts an HTTP node into `df.nodes` without ever calling `df.http()`.

To close this gap, `execute_http.rs` re-checks the privilege at execution time,
before any network activity:

```sql
SELECT has_function_privilege(
    $submitted_by::regrole,
    'df.http(text,text,text,jsonb,integer)'::regprocedure,
    'EXECUTE')
```

`submitted_by` is the role recorded in `df.nodes` at `df.start()` time. If the
check fails, the node transitions to `failed` with a message of the form:

```
Blocked: role 'alice' does not have EXECUTE privilege on df.http(). ...
```

This check is enforced regardless of which HTTP Cargo feature is active.
When no HTTP feature is enabled, the activity rejects all requests before
reaching this check, so the privilege check is effectively moot in that
configuration — but it is still compiled in and would run if the earlier
gate were ever removed.

### 4. df.grant_usage() — opt-in HTTP via include_http parameter

```sql
df.grant_usage(p_role TEXT, include_http boolean DEFAULT false, with_grant boolean DEFAULT false)
```

The second parameter defaults to `false`. The function uses a blanket
`GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df` and then immediately revokes
`df.http` unless `include_http => true`:

```sql
-- Always granted:
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO <role>;
-- Admin helpers revoked unless with_grant => true:
REVOKE EXECUTE ON FUNCTION df.grant_usage(TEXT, boolean, boolean) FROM <role>;
REVOKE EXECUTE ON FUNCTION df.revoke_usage(TEXT) FROM <role>;
-- df.http revoked unless include_http => true:
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM <role>;
```

If `include_http => false` but the role still has effective `EXECUTE` via a
`PUBLIC` grant or another inherited role, a `WARNING` is emitted:

```
pg_durable: role "X" still has effective EXECUTE privilege on df.http()
despite include_http => false (possibly via a PUBLIC grant or another role
grant). To remove it, run: REVOKE EXECUTE ON FUNCTION df.http(...) FROM PUBLIC;
```

To grant HTTP access:

```sql
SELECT df.grant_usage('my_role', include_http => true);
-- or, after initial grant_usage:
GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO my_role;
```

If `include_http => true` is requested by a delegated admin that does not have
permission to grant `df.http()`, `df.grant_usage()` raises an error rather than
silently skipping the HTTP grant.

To revoke:

```sql
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM my_role;
```

`df.revoke_usage()` revokes all `df` access including `df.http` (via the
blanket `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA df`); no changes needed.

### 5. Revoke PUBLIC EXECUTE on df.grant_usage() / df.revoke_usage()

`df.grant_usage()` and `df.revoke_usage()` are powerful admin functions — they
manage schema, table, and function privileges for arbitrary roles. PostgreSQL
grants `EXECUTE` to `PUBLIC` by default, so without an explicit revoke any
authenticated user could call them.

The `rls_and_grants` extension SQL block revokes the default grant immediately
after both functions are created:

```sql
REVOKE EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.revoke_usage(text) FROM PUBLIC;
```

Authorization is enforced by two PostgreSQL-native mechanisms:
1. **EXECUTE privilege** on the functions (revoked from PUBLIC) — controls who can call them
2. **WITH GRANT OPTION** on underlying objects — the inner GRANT/REVOKE statements run as the caller via SECURITY INVOKER, so PostgreSQL's native privilege checks prevent escalation

When `with_grant => true` is used, the target role receives all privileges
WITH GRANT OPTION and retains EXECUTE on the admin helpers. Authorization is
enforced by PostgreSQL’s native WITH GRANT OPTION mechanism: the caller must
hold each underlying privilege WITH GRANT OPTION, which is automatically true
for superusers and for delegated admins granted via `with_grant => true`.

These functions are new in v0.2.0, so this does not affect the upgrade path
from v0.1.1 — there is no pre-existing PUBLIC grant to worry about.

> **Warning for admins:** `df.grant_usage()` issues
> `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df`, which includes
> `df.grant_usage()` and `df.revoke_usage()` themselves. It immediately revokes
> those two functions from the target role afterward, but if an admin manually
> runs the blanket `GRANT` without the follow-up `REVOKE`, the role will gain
> access to the admin helpers. Always use `df.grant_usage()` rather than
> hand-crafting the `GRANT` statements, or carefully replicate the revocations
> from its body.

### 6. Behaviour for upgrades from v0.1.1

v0.1.1 issued `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO PUBLIC`, which
covered `df.http()`. The upgrade script (`pg_durable--0.1.1--0.2.0.sql`) does
**not** revoke this automatically, because:

- The upgrade may be applied to installs that intentionally chose to allow HTTP
  for all users.
- Silently revoking PUBLIC access during an upgrade is a behaviour change that
  could break running workflows.

Instead, the upgrade script contains a documentation comment explaining the
situation and telling admins how to opt in to the stricter model if desired:

```sql
-- If you want to adopt opt-in HTTP permissions after upgrading, run:
--   REVOKE EXECUTE ON FUNCTION df.http(text,text,text,jsonb,integer) FROM PUBLIC;
-- Then use df.grant_usage(role, include_http => true) to re-grant selectively.
```

The updated `df.grant_usage(role, include_http => false)` function (also added
in the upgrade script) will emit a `WARNING` if the role still inherits HTTP
access via the PUBLIC grant, prompting the admin to take action.

---

## Implementation Plan

### ✅ Already done in this commit (PR #100)

- [x] **Execution-time privilege check** — `src/activities/execute_http.rs`
      calls `check_http_privilege()` using `has_function_privilege` before any
      network activity (layers 0 in the three-layer model).
- [x] **REVOKE FROM PUBLIC at install time** — `rls_and_grants` extension SQL
      block in `src/lib.rs` revokes `EXECUTE ON FUNCTION df.http(...)  FROM PUBLIC`
      immediately after the function is created (`requires = [dsl::http]`).
- [x] **REVOKE grant_usage / revoke_usage FROM PUBLIC** — added
      `REVOKE EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) FROM PUBLIC` and
      `REVOKE EXECUTE ON FUNCTION df.revoke_usage(text) FROM PUBLIC` to the
      `rls_and_grants` block.  These functions are new in v0.2.0 so no upgrade
      script changes are needed.
- [x] **`df.grant_usage(role, include_http DEFAULT false, with_grant DEFAULT false)`** — signature updated
      in both `src/lib.rs` and `sql/pg_durable--0.1.1--0.2.0.sql`.  The function
      uses explicit per-function GRANTs; `df.http()` is only granted when
      `include_http => true`.  When `with_grant => true`, all grants include
      `WITH GRANT OPTION` and admin helpers are granted to the target role.
      The function is purely additive — it never issues REVOKE.
- [x] **Upgrade script** — section 7 of `pg_durable--0.1.1--0.2.0.sql` is
      documentation only (no DDL); explains that PUBLIC HTTP access is retained
      after upgrade and how to tighten it.
- [x] **E2E test skeleton** — `tests/e2e/sql/49_http_grant_check.sql` covers
      grant-allowed, revoke-blocks, and restore-allows cases.

### ⬜ Still to do

- [x] **Rename E2E test file** — renamed to `tests/e2e/sql/49_http_permissions.sql`.

- [x] **Expand E2E test coverage** — `49_http_permissions.sql` now covers:
  - [x] `grant_usage(role)` default blocks HTTP at execution (Test 4)
  - [x] `grant_usage(role, false)` does not grant df.http; residual PUBLIC grant persists (Test 5)
  - [x] `grant_usage(role, include_http => true)` — HTTP works, no privilege error (Test 1)
  - [x] Manual `GRANT/REVOKE` respected at execution time (Tests 2 & 3)
  - [x] Superuser bypasses the privilege check (Test 6)

- [x] **Update `docs/http-security.md`** — section 3.3 updated to reflect opt-in
      model, `include_http` parameter, WARNING behaviour, and upgrade note.

- [x] **Add section to `docs/upgrade-testing.md`** — "df.http() opt-in permissions
      (PR #100)" entry added under v0.1.1 → v0.2.0, covering all three scenarios.

- [x] **Remove feature-flag gate on privilege check** — `check_http_privilege()`
      and its call site no longer have `#[cfg]` gates; the check compiles and runs
      unconditionally.  The `#[cfg(not(...))] let _ = &pool` suppressor was also removed.

- [x] **Merge `49_http_permissions.sql` into `06_http_and_ssrf.sql`** — Permission
      tests merged as a distinct section at the end of `06_http_and_ssrf.sql`,
      after `RESET SESSION AUTHORIZATION` returns to superuser context.
      `49_http_permissions.sql` deleted.

- [ ] **Delete this spec file** — Once `docs/http-security.md` has been
      updated to fully cover the opt-in permission model (section 3.3 is done;
      verify nothing is missing), delete `docs/spec-http-function-permissions.md`.
      `http-security.md` is the authoritative reference.

---

## Code Review — `7fafe73` (2026-04-02)

The implementation and documentation have continued to move after the original
review notes were captured here. Keep the authoritative behavioral details in
`docs/http-security.md`; this file is only a temporary design record until it
is deleted.
