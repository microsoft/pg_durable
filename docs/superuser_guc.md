# Superuser Submission GUC

This document specifies a GUC that controls whether pg_durable allows durable
function instances to run with a superuser execution identity.

## Summary

Add a new boolean GUC:

- `pg_durable.enable_superuser_instances`

Recommended behavior:

- Default: `off`
- Context: `SUSET`
- Effect when `off`: pg_durable rejects any instance whose `submitted_by` role
  is a PostgreSQL superuser.
- Effect when `on`: pg_durable preserves the current behavior and allows
  superuser-submitted instances.

The design reference is pg_cron's `cron.enable_superuser_jobs`: privileged job
submission should be behind an explicit operator-controlled switch, not enabled
implicitly.

## Problem

pg_durable records an execution identity in `df.instances.submitted_by` and
`df.nodes.submitted_by`, then later uses that identity to execute SQL with the
submitter's privileges.

That is correct for normal privilege isolation, but it creates a clean
escalation path in environments where:

- customers do not have `SUPERUSER`
- customers do have `BYPASSRLS` or an equivalent managed-service capability
- customers have the normal pg_durable table privileges granted by
  `df.grant_usage()`

`df.grant_usage()` grants `INSERT` on the `submitted_by` columns of
`df.instances` and `df.nodes`. Under normal circumstances this is safe: the
RLS `WITH CHECK` policy (`submitted_by = current_user::regrole`) prevents a
user from inserting a row that claims a different identity. However, a role
with `BYPASSRLS` skips that `WITH CHECK` constraint entirely and can therefore
insert rows with an arbitrary `submitted_by` value, including a superuser's
OID. If pg_durable later accepts those rows, the worker can be tricked into
executing user-controlled durable functions as that superuser.

Blocking superuser execution identities removes that escalation target.

## Design Reference: pg_cron

pg_cron has a closely related setting, `cron.enable_superuser_jobs`, which
recognizes that superuser-scheduled jobs are a special trust boundary and
should be explicitly operator-enabled.

pg_durable should follow the same design principle:

- normal durable function execution should work without superuser identities
- superuser durable execution should require an explicit opt-in
- the secure default should be the restrictive setting

We are not required to match pg_cron's exact implementation details. The key
point is the product decision: privileged durable execution is exceptional and
must be controlled by a dedicated GUC.

## Goals

- Prevent `BYPASSRLS` users from forging pg_durable rows that execute as a
  superuser.
- Preserve an escape hatch for deployments that intentionally want superuser
  durable functions.
- Keep the change runtime-only with no `df` schema changes.
- Fail closed with a clear error message when superuser instances are
  disallowed.

## Non-Goals

- Solving the broader problem of safely supporting all roles with
  `BYPASSRLS`-like privileges.
- Introducing a custom allowlist role such as `df_superuser`.
- Redesigning the table grant model in this change.

Future work may revisit how to support both superusers and roles with RLS
bypass while preventing privilege-escalation attacks by the latter.

## Proposed Semantics

### GUC definition

Add:

```rust
GucRegistry::define_bool_guc(
    c"pg_durable.enable_superuser_instances",
    c"Allow pg_durable instances whose submitted_by role is a PostgreSQL superuser",
    c"Disabled by default to prevent superuser execution-identity forgery via RLS-bypassing roles.",
    &ENABLE_SUPERUSER_INSTANCES,
    GucContext::Postmaster,
    GucFlags::SUPERUSER_ONLY,
);
```

Note: in pgrx, `GucFlags::NO_SHOW_ALL` is a combined constant that sets both
`GUC_NO_SHOW_ALL` (hides from `SHOW ALL` and `pg_settings`) and `GUC_NOT_IN_SAMPLE`
(hides from the sample `postgresql.conf`). However, `GUC_NO_SHOW_ALL` also hides the
GUC from `pg_settings`, which breaks any unit tests that query that view to verify
`boot_val` or `context`. Therefore **do not use `GucFlags::NO_SHOW_ALL`** for this GUC.
`GucFlags::SUPERUSER_ONLY` already ensures non-superusers cannot see the GUC in
`pg_settings`; that is the meaningful security property here.

Recommended default:

- `false`

Recommended operational guidance:

- keep `off` in managed / multi-tenant / PaaS environments
- only set `on` when the operator intentionally wants durable functions to run
  with superuser privileges

### Enforcement rule

When `pg_durable.enable_superuser_instances = off`, pg_durable must reject any
instance whose effective execution identity is a superuser.

The checked identity is:

- `df.instances.submitted_by` for the instance as a whole
- `df.nodes.submitted_by` as defense in depth while loading the graph

This is intentionally about the persisted execution identity, not only the SQL
caller that invoked `df.start()`. That distinction matters because the threat
includes forged rows inserted directly into `df.instances` / `df.nodes`.

### Failure behavior

Two enforcement points are required.

#### 1. Submission-time guard in `df.start()`

If `current_user` is a superuser and the GUC is `off`, `df.start()` raises an
error before inserting any rows.

Purpose:

- gives legitimate callers an immediate, clear error
- keeps the common path simple and explicit

#### 2. Worker-side guard on persisted metadata

When the background worker loads a graph, it must reject any instance or node
whose `submitted_by` resolves to a superuser while the GUC is `off`.

Purpose:

- blocks rows forged via direct table `INSERT`/`UPDATE`
- keeps the security guarantee intact even when callers bypass `df.start()`

If such an instance is encountered, the instance should fail with an error that
explains the policy, for example:

```text
pg_durable blocked instance 1234abcd: submitted_by role "postgres" is a superuser,
but pg_durable.enable_superuser_instances is off
```

## Why Worker-Side Enforcement Is Mandatory

A `df.start()`-only check does not mitigate the attack described above.

Today `df.grant_usage()` grants:

- `INSERT (id, label, root_node, submitted_by, database)` on `df.instances`
- `INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database)` on `df.nodes`

RLS normally constrains those inserts, but a role with `BYPASSRLS` can bypass
that protection. That means the trusted enforcement point must be somewhere the
attacker cannot skip: the worker path that consumes persisted rows.

This mirrors the existing `df.http()` design, where execution-time privilege
validation closes gaps left by DSL-time validation.

## Implementation Plan

> **Status: implemented.** All four steps below are complete and the build is
> clean. Changed files:
> - [`src/lib.rs`](../src/lib.rs) — GUC static + registration
> - [`src/types.rs`](../src/types.rs) — helper functions
> - [`src/dsl.rs`](../src/dsl.rs) — submission-time check
> - [`src/activities/load_function_graph.rs`](../src/activities/load_function_graph.rs) — worker-side guard

### 1. Add the GUC in `src/lib.rs`

- Define a new static `GucSetting<bool>` with default `false`.
- Register `pg_durable.enable_superuser_instances` in `_PG_init()`.
- Use `GucContext::Postmaster` so the GUC requires a server restart to change.
- Use `GucFlags::SUPERUSER_ONLY`: restricts `pg_settings` visibility to
  superusers. Do **not** use `GucFlags::NO_SHOW_ALL`; that flag maps to
  `GUC_NO_SHOW_ALL` which hides the GUC from `pg_settings` entirely, breaking
  unit tests that verify `boot_val` and `context`.

### 2. Add a helper for role privilege classification

Add a small shared helper, likely in `src/types.rs` or a nearby security
utility module, that answers:

- whether a given role OID is a superuser
- whether a given role name is a superuser

Suggested API shape:

```rust
pub fn superuser_instances_enabled() -> bool;
pub fn is_role_superuser_oid(role_oid: pgrx::pg_sys::Oid) -> Result<bool, String>;
pub async fn is_role_superuser_name(pool: &PgPool, role_name: &str) -> Result<bool, String>;
```

The implementation should query `pg_catalog.pg_roles.rolsuper`.

### 3. Add a submission-time check in `src/dsl.rs`

Inside `df.start()`, after obtaining `current_user_oid` and before inserting
rows:

- if the new GUC is `off`
- query whether `current_user_oid` is a superuser
- if yes, raise an error

This check should be adjacent to the existing `LOGIN` validation because both
are execution-identity validation rules for `df.start()`.

### 4. Add worker-side validation in graph loading

The best place is `src/activities/load_function_graph.rs`, because that is the
first trusted point where persisted instance/node metadata is materialized into
the executable graph.

Recommended behavior:

- load `df.instances.submitted_by` alongside `root_node`
- reject the instance immediately if that role is superuser and the GUC is off
- while iterating nodes, reject if any node `submitted_by` is superuser and the
  GUC is off

Reasons to enforce here:

- it blocks forged rows before any user SQL is executed
- it avoids opening a per-user connection as the forbidden role
- it protects both SQL and future activity types that depend on
  `submitted_by`

### 5. Keep `connect_as_user()` simple

Do not make `connect_as_user()` the primary policy gate.

It is acceptable to add a defensive assertion there later, but the primary
rejection should happen before execution begins, with an error message that is
about durable-function policy rather than connection mechanics.

## Upgrade And Migration

This should be treated as a runtime-only security hardening change.

- **DDL change:** None.
- **Scenario A:** No `df` schema changes. Fresh install and upgraded schema are
  identical.
- **Scenario B1:** The new `.so` works against all previous schemas because the
  check relies only on existing `submitted_by` columns and `pg_roles`.
- **Scenario B2:** No data migration is needed.

Operational consequence when the default is `off`:

- existing queued or future forged superuser instances will fail instead of
  running
- legitimate superuser-submitted instances will also fail until the operator
  explicitly sets the GUC to `on`

That behavior is intentional. This is a security posture change, not a schema
evolution.

## Testing Plan

> **Status: implemented.**
> - `scripts/test-e2e-local.sh` — `enable_superuser_instances = on` added to all phases in `configure_phase()` so existing tests are unaffected.
> - [`tests/e2e/sql/17_superuser_guc.sql`](../tests/e2e/sql/17_superuser_guc.sql) — new E2E test (cases 1–4 below).

### Impact on existing E2E tests

The test runner (`scripts/test-e2e-local.sh`) connects as `postgres` (a
superuser) for all tests. Individual test files switch away from that identity
using `SET SESSION AUTHORIZATION` or `SET ROLE` before calling `df.start()`.

With the GUC defaulting to `off`, a `df.start()` call made while still in the
`postgres` identity will now fail. This affects every test file that calls
`df.start()` **without** first switching identity, or that contains a section
that does DDL-level setup as `postgres` and then calls `df.start()` directly.

The table below lists the affected tests. Tests not listed are already safe
because they switch to `df_e2e_user` or another non-superuser role before any
`df.start()` call.

| File | Status | Required action |
|------|--------|-----------------|
| `10_connection_limits.sql` | **Broken** — calls `df.start()` as `postgres` throughout | Add `SET SESSION AUTHORIZATION df_e2e_user` at the top and `RESET` at the end |
| `11_cross_connection.sql` | **Broken** — calls `df.start()` as `postgres` throughout | Add `SET SESSION AUTHORIZATION df_e2e_user` at the top and `RESET` at the end |
| `12_extension_lifecycle.sql` | **Partially broken** — some `df.start()` calls are inside `SET ROLE df_e2e_user` blocks; others may be as `postgres`; needs audit | Audit and add explicit identity switching around any `df.start()` calls that run as `postgres` |
| `14_database.sql` | **Partially broken** — some tests already use `SET SESSION AUTHORIZATION df_e2e_user`; the `df.start()` on line 46 runs as `postgres` | Guard that call and any others that remain as `postgres` |
| `44_connection_limit_backpressure.sql` | **Broken** — calls `df.start()` as `postgres` throughout | Add `SET SESSION AUTHORIZATION df_e2e_user` at the top and `RESET` at the end |
| `45_connection_limit_timeout.sql` | **Broken** — calls `df.start()` as `postgres` throughout | Add `SET SESSION AUTHORIZATION df_e2e_user` at the top and `RESET` at the end |
| `15_rls.sql` | **Needs audit** — comment says "runs as postgres throughout"; check if any `df.start()` calls happen before a `SET SESSION AUTHORIZATION` | Audit |

Tests already using `SET SESSION AUTHORIZATION df_e2e_user` at the top level
before all `df.start()` calls (`01`, `02`, `03`, `04`, `05`, `06`, `07`, `08`,
`09`, `13`) are **unaffected** and require no changes.

The `00_setup_playground.sql` is also unaffected — it runs DDL as a superuser
but does not call `df.start()`.

### Approach: set the GUC in `postgresql.conf` for tests, not per-test

An alternative to fixing the identity of every broken test is to set
`pg_durable.enable_superuser_instances = on` in `postgresql.conf` during test
runs, restoring pre-implementation behavior for all existing tests and letting
the new security E2E test cover the GUC-off path explicitly.

This is the **recommended approach** because:

- it fixes all broken tests in one place (the test runner)
- it avoids changing many existing test files for reasons unrelated to what
  they are testing
- the GUC-off path is validated by the new dedicated E2E test

The test runner already writes a `postgresql.conf` line for `worker_role`; add
a matching line:

```bash
set_conf_line "pg_durable.enable_superuser_instances" "on"
```

This should be set for all phases in `prepare_phase()`, not just `standard`.

### New E2E test

Add `17_superuser_guc.sql` to cover the following cases when the GUC is off:

1. **superuser calls `df.start()`** — expect error  
2. **Non-superuser submission unaffected** — `df_e2e_user` can submit.
3. **Worker-side forgery rejection** — as a role with `BYPASSRLS`, insert a
   forged row directly into `df.instances` and `df.nodes` with
   `submitted_by = postgres`, then verify the instance transitions to `failed`
   with the expected error message before any SQL is executed.

Case 3 requires a role that has both `df.grant_usage()` privileges and
`BYPASSRLS`. The test must set up that role in its own body (not via
`00_setup_playground.sql`) and grant it `BYPASSRLS` explicitly.

### Unit / pg_test coverage

Add tests for:

- GUC default is `false`
- `is_role_superuser_oid()` correctly identifies a superuser role
- `is_role_superuser_oid()` correctly identifies a non-superuser role
- `df.start()` rejects superuser submissions when the GUC is `off`
- `df.start()` allows superuser submissions when the GUC is `on`

## Documentation Follow-Ups

If implemented, update these docs:

- `docs/spec-security-model.md`
  - resolve or revise the open question about superuser durable functions
  - document the new GUC as the controlling policy
- `docs/user-isolation.md`
  - change the current statement that superuser durable functions run as
    superuser unconditionally
- `docs/upgrade-testing.md`
  - add a runtime-only hardening entry documenting B1/B2 expectations
- `docs/api-reference.md`
  - document the new GUC and its default

## Open Questions

### Should the GUC be `SUSET` or `POSTMASTER`?

Recommendation: `SUSET`.

Reasoning:

- the check runs at submission/load time, not worker initialization time
- changing it does not require rebuilding pools or restarting the BGW
- it remains operator-controlled because only superusers can set it

If the team wants stricter operational change control, `POSTMASTER` is also
defensible, but it is not technically required.

### Should pg_durable also block `BYPASSRLS` execution identities?

Not in this change.

This proposal intentionally solves the narrower and more urgent problem:
preventing RLS-bypassing users from reaching a superuser execution identity.
Supporting or restricting `BYPASSRLS` roles directly is future work.