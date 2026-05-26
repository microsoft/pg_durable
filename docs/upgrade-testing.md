# Upgrade Testing Plan

## Deployment Model

pg_durable follows a two-phase upgrade model:

1. **Binary update** (maintenance window): The `.so` shared library is replaced. PostgreSQL processes load the new `.so` on next connection. This happens during scheduled maintenance.
2. **Schema update** (customer-initiated): `ALTER EXTENSION pg_durable UPDATE TO '<version>'` runs the upgrade SQL script. Customers may defer this for days, months, or indefinitely.

This means the new `.so` **must be backward compatible** with the previous version's schema. The `.so` and the upgrade script are not atomic — there is an extended period where the new binary runs against the old schema.

Compatibility is scoped to a **provider compatibility line**. A provider line is the set of pg_durable versions that use the same durable-state provider family and are expected to upgrade in place. The open-source line starts at v0.2.2, where pg_durable switches from `duroxide-pg-opt` to crates.io `duroxide-pg`. Versions before v0.2.2 used `duroxide-pg-opt`; they are not upgrade sources for the `duroxide-pg` line because the provider schemas and runtime state are different. Azure's fork owns upgrade testing for the `duroxide-pg-opt` line.

We never downgrade. Downgrade scripts are not needed.

## Test Scenarios

### Chain tests vs. direct-contact tests

Scenarios A and B2 are **chain tests**: PostgreSQL applies upgrade scripts sequentially (v0.2.2→v0.2.3→v0.3.0 within the current provider line), so each step is validated transitively by its own version's CI. Testing the current upgrade script against the immediately previous compatible version is sufficient.

Scenario B1 is a **direct-contact test**: the `.so` faces whatever raw schema the customer has, with no intermediate transformation. There is no chain — a customer on v0.2.2 who receives the v0.5.0 binary without ever upgrading has a v0.2.2 schema with a v0.5.0 `.so`. That's why B1 must test against all previous compatible versions in the same provider line.

### Compatibility boundaries

All three scenarios scope to versions within the same provider compatibility line. A provider-line boundary is stronger than a major-version boundary: the new `.so` does not need to execute against provider state from another line, and the upgrade tests should not treat that crossing as a required customer path.

- **B1**: Tests all previous schemas in the current provider line. It skips versions before `PROVIDER_COMPAT_START_VERSION`.
- **A and B2**: Test the immediately previous version only when that previous version is in the current provider line. If the current version is the first version in a provider line, A and B2 are skipped because there is no valid previous upgrade source for that line.
- **Major versions**: A major version bump can still be used as a compatibility boundary. When no provider-line split is involved, the previous same-major rules continue to apply.

### Scenario A: Schema Upgrade Correctness

**Goal:** Verify that `ALTER EXTENSION UPDATE` produces an identical schema to a fresh `CREATE EXTENSION`.

**Contract:** For a not-yet-released version, the fresh-install schema is expected to match what an existing customer would get by starting from the immediately previous compatible shipped version and applying the shipped upgrade chain to the new version. In other words, Scenario A treats the upgrade result as the reference shape for already-shipped versions in the current provider line. If fresh install and upgrade differ before release, prefer aligning the new version's fresh-install DDL with the upgrade path unless there is a deliberate reason to change the contract.

**Method:**
1. Install current `.so` and all upgrade SQL files
2. In a clean test database, run `CREATE EXTENSION pg_durable VERSION '<prev>'` → `ALTER EXTENSION pg_durable UPDATE TO '<current>'`, then capture a schema snapshot
3. In the same clean test database (after dropping the extension) or in a second clean database, run `CREATE EXTENSION pg_durable` and capture a fresh-install snapshot
4. Compare schemas: tables, columns, types, constraints, indexes, RLS policies, grants

**What it catches:**
- Missing DDL in upgrade script (forgotten tables, columns, policies)
- Wrong column types, defaults, or constraint names
- Ordering issues in upgrade SQL

**Why only the immediately previous compatible version?** Upgrade scripts are frozen once shipped. The chain of upgrades (v0.2.2 → v0.2.3 → v0.3.0 within a provider line) is validated transitively — each version's CI tests its own upgrade script. Only the current work-in-progress upgrade script might introduce an inconsistency, so testing it against the immediately previous compatible version is sufficient.

**Priority:** High — foundational test, catches the most common class of upgrade bugs.

### Scenario B1: Binary Backward Compatibility

**Goal:** Verify that the new `.so` works correctly against **all** previous compatible versions' schemas, not just the immediately previous one. Customers may never run `ALTER EXTENSION UPDATE`, so the new binary must work against any older schema in the same provider line.

This is the **most deployment-critical test** because the new binary may run against any older compatible schema indefinitely. A customer on v0.2.2 who receives the v0.5.0 binary without ever upgrading must still be able to use the extension.

We test against all previous versions in the same provider compatibility line. The line starts at `PROVIDER_COMPAT_START_VERSION` in `scripts/test-upgrade.sh`, which can be overridden by downstream forks or CI environments.

**Method:**
1. Install the new `.so`
2. For each previous compatible version: create the extension with that version's install SQL
3. Exercise all SQL-callable functions against each schema
4. Verify: no errors, correct results

**What to test (expand per-version as the API surface grows):**

| Area | Functions |
|------|-----------|
| Variable functions | `df.setvar()`, `df.getvar()`, `df.unsetvar()`, `df.clearvars()` |
| Variable capture | `df.start()` with vars set |
| DSL construction | `df.sql()`, `df.seq()`, `df.if()`, `df.loop()`, `df.sleep()`, `df.http()` |
| Execution | Starting and completing orchestrations |
| Monitoring | `df.status()`, `df.result()`, `df.list_instances()`, `df.instance_info()` |
| In-flight work | Orchestrations started before `.so` swap complete after swap |

**What it catches:**
- SQL queries in Rust code referencing columns/constraints that don't exist in the old schema
- Changed function signatures that conflict with old SQL wrappers
- Behavioral regressions for customers who haven't run the upgrade script

**Priority:** Critical — this reflects the real-world deployment state for potentially all customers.

### Scenario B2: Data Compatibility After Upgrade

**Goal:** Verify that data created under the previous compatible version remains accessible and functional after `ALTER EXTENSION UPDATE`.

This is a **chain test** (like Scenario A) — upgrade scripts are applied sequentially within the provider compatibility line, so testing against the immediately previous compatible version is sufficient. Each intermediate upgrade was validated by its own version's CI.

**Method:**
1. Create extension at previous version
2. Insert test data (vars, completed instances, and optionally in-flight work)
3. Run `ALTER EXTENSION UPDATE`
4. Verify: existing data is accessible, functions work on the new schema

**What to test (expand per-version as changes accumulate):**

| Area | What to verify |
|------|---------------|
| Variables | Pre-existing vars accessible via `df.getvar()` after upgrade |
| Pre-existing instances | `df.result()`, `df.instance_info()`, and `df.list_instances()` work for instances created before upgrade |
| In-flight work | Work started before `ALTER EXTENSION UPDATE` can still complete afterward |
| New operations | `df.start()` works with new schema |

**Priority:** High — validates the upgrade doesn't corrupt or lose existing data.

## Backward Compatibility Patterns

When a new `.so` must support both old and new schemas (Scenario B1), code should detect the schema state at runtime. Approaches:

### Option 1: Runtime schema detection (preferred)

Check column/table existence and branch accordingly:

```rust
// Example: check if a column exists before referencing it
let has_column = Spi::get_one::<bool>(
    "SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'df' AND table_name = 'example' AND column_name = 'new_col'
    )"
).unwrap_or(Some(false)).unwrap_or(false);

if has_column {
    // New schema: use new query
} else {
    // Old schema: use compatible query
}
```

Cache the result per-session to avoid repeated catalog queries.

### Option 2: SQL that works on both schemas

Write queries valid regardless of which schema version is active. Not always possible (e.g., `ON CONFLICT` must name actual constraint columns).

### Option 3: Use extension version from pg_catalog

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_durable'
```

Returns the version that was last installed/updated. Compare against known thresholds.

## Implementation

### Test infrastructure

- `sql/pg_durable--0.1.1.sql` — first install SQL for the current major version (only the first version per major needs a fixture; intermediate versions are reconstructed by chaining upgrade scripts)
- `sql/pg_durable--0.1.1--0.2.0.sql` — upgrade script (initially empty, populated by subsequent PRs)
- `scripts/test-upgrade.sh` — runs Scenarios A, B1, and B2. The `PROVIDER_COMPAT_START_VERSION` environment variable/default controls the first version in the current provider compatibility line. Versions before that boundary are excluded from B1 and cannot be used as A/B2 upgrade sources.
- CI step in `.github/workflows/ci.yml`

### Per-version checklist

Each PR that changes the extension schema or modifies SQL queries in Rust code should:

1. Add the necessary DDL to the upgrade script (`sql/pg_durable--<prev>--<current>.sql`)
2. Ensure the `.so` is backward compatible with **all** previous schemas in the same provider compatibility line (Scenario B1)
3. Add version-specific notes to this document under "Version-Specific Changes" below
4. Pass upgrade tests in CI

### Future work

- **pg_regress-style upgrade test**: pg_cron and similar extensions use `pg_regress` with expected-output diffs to validate upgrade scripts. This is simpler than our Scenario A schema snapshot approach but less thorough — it doesn't cover B1 (binary backward compat) or B2 (data survival). Consider adopting as a complementary check if `pg_regress` integration becomes worthwhile.

### Preparing for the next version

**Minor release** (e.g. 0.2.0 → 0.3.0):
1. Create empty `sql/pg_durable--<N>--<N+1>.sql` upgrade script
2. Bump `Cargo.toml` version to `<N+1>`
3. If this release starts a new provider compatibility line, update the `PROVIDER_COMPAT_START_VERSION` default in `scripts/test-upgrade.sh` and document the boundary under "Version-Specific Changes". Downstream forks can instead override `PROVIDER_COMPAT_START_VERSION` in CI to keep the script shared.

If this is the first minor after a new major (e.g. 1.0.0 → 1.1.0), also:

4. Check in `sql/pg_durable--<major>.sql` as the first install SQL fixture for the new major (e.g. copy the generated `pg_durable--1.0.0.sql` from the extension directory)
5. Optionally delete the previous major's install SQL fixture and upgrade scripts — they are no longer needed by any of A, B1, or B2

No additional fixture is needed for subsequent minors — intermediate versions are reconstructed by chaining `ALTER EXTENSION UPDATE` from the first version's install SQL.

**Major release** (e.g. 0.x → 1.0.0):
1. Create empty `sql/pg_durable--<N>--<1.0.0>.sql` upgrade script
2. Bump `Cargo.toml` version to `<1.0.0>`

`cargo pgrx package` generates the new major's install SQL. The previous major's install SQL and upgrade scripts are still needed for the A/B2 upgrade chain when the provider line continues across the major bump. B1 will be a no-op if there are no previous compatible versions within the new major, or if `PROVIDER_COMPAT_START_VERSION` marks the new major as the start of a new provider line.

---

## Version-Specific Changes

Each schema-changing PR should add a section here documenting what changed,
what the upgrade script handles, and any backward compatibility considerations.

### v0.2.1 → v0.2.2

#### #162 quote_ident-wrapped `current_user::regrole` (fixes #161)
- **DDL change:** The three RLS policies (`instances_user_isolation`, `nodes_user_isolation`, `vars_user_isolation`) are dropped and recreated to compare against `quote_ident(current_user)::regrole` instead of `current_user::regrole`. The `df.vars.owner` column default is changed the same way via `ALTER TABLE ... ALTER COLUMN ... SET DEFAULT`. Casting `name → regrole` directly reparses the value as an unquoted SQL identifier and case-folds it, so a role like `labUser` resolved to `labuser`, raising `role "labuser" does not exist` at INSERT time on the `WITH CHECK` clause (and at variable read/write time on the policy). `quote_ident()` wraps the name in double quotes so `regrole_in` preserves casing and other reserved characters.
- **Scenario A considerations:** Schema comparison must verify the three policy expressions and the `df.vars.owner` default text match the new `quote_ident(...)` form on both fresh installs and upgraded databases.
- **Scenario B1 considerations:** The new `.so` continues to work against pre-0.2.2 schemas. The runtime SPI queries in `src/dsl.rs` that read/write `df.vars` now use `quote_ident(current_user)::regrole`; the comparison still resolves correctly against the older `owner REGROLE` column regardless of which expression the policy uses, because `regrole = regrole` is OID equality once both sides resolve. The pre-existing bug (policy lookup on the older schema for non-owner mixed-case roles) is not reintroduced by the new `.so` — it was always present in those schemas, and is only fixed by running `ALTER EXTENSION pg_durable UPDATE`.
- **Scenario B2 considerations:** No data migration needed. The change is purely DDL on policies + a column default. Existing rows in `df.instances`, `df.nodes`, and `df.vars` are untouched.

### v0.1.1 → v0.2.0

#### #51 security hardening (helper `search_path` pinning + SPI parameterization)
- **DDL change:** Upgrade SQL now redefines helper SQL/PLpgSQL functions (`df.as_op()`, `df.if_then_op()`, `df.if_else_op()`, `df.ensure_durofut()`, `df.loop_prefix_op()`) with `SET search_path = pg_catalog, df, pg_temp` for defense-in-depth.
- **Scenario A considerations:** Schema comparison should verify helper function definitions match fresh-install SQL, including the `SET search_path` clause in `proconfig`/function definition text.
- **Scenario B1 considerations:** Runtime code moved key internal lookups to parameterized SPI/sqlx queries. This is backward compatible with prior schemas because query parameterization changed execution style, not table/column contracts.
- **Scenario B2 considerations:** Existing instances/graphs created pre-upgrade should remain readable and executable after `ALTER EXTENSION UPDATE`; tests should include status/result and graph loading paths to cover updated internal query call sites.

#### #53 per-user df.vars scoping via owner column + RLS
- **DDL change:** `df.vars` adds `owner REGROLE NOT NULL DEFAULT current_user::regrole`, changes the primary key from `(name)` to `(owner, name)`, enables RLS, and adds the `vars_user_isolation` policy.
- **Scenario A considerations:** The schema comparison must verify the new column, its default, the new primary key definition, RLS enabled state, the `vars_user_isolation` policy, and table grants. Because the upgrade script adds `owner` with `ALTER TABLE ... ADD COLUMN`, upgraded schemas place `owner` after the existing columns. Fresh-install DDL for v0.2.0 has been aligned to that order so Scenario A continues to compare `ordinal_position`.
- **Scenario B1 considerations:** This change touches the highest-risk upgrade surface because the Rust code now queries `df.vars.owner` and uses `ON CONFLICT (owner, name)`. The new `.so` still has to work against the v0.1.1 schema, which has neither the `owner` column nor the `(owner, name)` primary key. The implementation therefore uses the installed extension version as the compatibility boundary: v0.1.x stays in legacy global-vars mode, while v0.2.0+ uses owner-scoped queries.
- **Scenario B2 considerations:** The upgrade script assigns all pre-existing `df.vars` rows to the role running `ALTER EXTENSION` via the `DEFAULT current_user::regrole` backfill. Upgrade tests verify that existing vars remain readable after upgrade for the role that performed the upgrade, that the migrated row is re-homed to that upgrade-running role, and that new post-upgrade writes/executions use owner-scoped semantics. This migration does not preserve per-user ownership for legacy rows; it intentionally re-homes them to the upgrade runner.
- **Current status on this branch:** `scripts/test-upgrade.sh` now passes all Scenario A, B1, and B2 checks for this change.

#### Metadata table hardening for direct INSERT + RLS
- **DDL change:** `df.instances` and `df.nodes` add structural `CHECK` constraints, same-instance foreign keys, and supporting unique constraints. Table-wide `INSERT` grants are narrowed to column-level `INSERT` grants that match the columns `df.start()` writes, while preserving direct user `INSERT` under RLS.
- **Scenario A considerations:** Schema comparison must include the new constraints, foreign keys, and narrowed grants on `df.instances` and `df.nodes`.
- **Scenario B1 considerations:** The `.so` remains backward compatible with older schemas because the hardening is schema-only and does not introduce new columns or change Rust query shapes.
- **Scenario B2 considerations:** The upgrade script adds the new `CHECK` and foreign-key constraints as `NOT VALID` so malformed legacy metadata rows do not block `ALTER EXTENSION UPDATE`, while all new writes are still enforced immediately after the upgrade.

#### BGW applies duroxide migrations (replaces extension-SQL approach)
- **DDL change (df schema):** No new SQL functions added for readiness. The internal Rust `is_worker_ready()` check (not SQL-callable) gates `df.*` functions until the BGW writes a row to `duroxide._worker_ready`.
- **DDL change (duroxide schema):** None required in the upgrade script. Fresh v0.2.0 installs create `CREATE SCHEMA duroxide` via extension SQL (extension-owned). The BGW's `ApplyAll` policy applies duroxide table DDL at runtime. For customers upgrading from v0.1.1, the duroxide schema and its objects already exist (extension-owned from the earlier SQL-hand-over approach); the BGW will verify they are up-to-date and continue normally.
- **Scenario A considerations:** The Scenario A equivalence contract covers the `df` schema only. The duroxide schema diverges intentionally between the fresh-install and upgrade paths in v0.2.0: fresh installs have an empty `duroxide` schema (tables added later by BGW), while upgrades have a fully populated `duroxide` schema (carried forward from v0.1.1 extension SQL). This divergence is expected and acceptable — `scripts/test-upgrade.sh` excludes the `duroxide` schema from the snapshot diff.
- **Scenario B1 considerations:** Readiness checking is internal to the Rust binary — no SQL function needs to be registered. The new `.so` continues to work against v0.1.1 schemas that have not run `ALTER EXTENSION UPDATE`.
- **Scenario B2 considerations:** The BGW readiness check (`wait_for_ready()`) is called in both B1 and B2 scenarios to ensure the BGW has applied all pending duroxide migrations before exercising the extension.
- **Current status on this branch:** Implemented. BGW now uses `MigrationPolicy::ApplyAll`, verifies duroxide schema extension ownership before applying, and writes `duroxide._worker_ready` after initialization completes.

#### Bump to duroxide 0.1.26 + duroxide-pg-opt 4a6bf6b (migrations 0006–0010)
- **DDL change (df schema):** None. All new schema objects are in the `duroxide` schema and are applied at runtime by the BGW.
- **DDL change (duroxide schema):** Five new migrations applied by BGW at startup:
  - 0006: `worker_queue.tag TEXT` column + index; updated `enqueue_worker_work` and `fetch_work_item` SPs
  - 0007: `fetch_orchestration_item` SP body change only (no schema change)
  - 0008: new `kv_store` table; updated `fetch_orchestration_item`, `ack_orchestration_item`, deletion/pruning SPs
  - 0009: `kv_store.last_updated_at_ms BIGINT` column; updated KV materialization SPs
  - 0010: new `kv_delta` table; two-table KV write model; delta→store merge on terminal transition
- **Scenario A considerations:** The `df` schema equivalence contract is unchanged. The `duroxide` schema is excluded from snapshot diffs — fresh installs start with an empty `duroxide` schema (BGW fills it in at runtime) while upgrades carry forward the fully-populated schema from v0.1.1. This is expected and acceptable.
- **Scenario B1 considerations:** The BGW uses `MigrationPolicy::ApplyAll`. A database that has only migrations 0001–0005 is handled gracefully: the BGW detects the gap and applies 0006–0010 at startup. No manual intervention is needed.
- **Scenario B2 considerations:** All five new migrations are additive (new tables and columns with defaults or nullable). Existing `df.vars`, `df.nodes`, `df.instances`, and `df.graphs` data is untouched.
- **Historical status:** Implemented with the provider source at `4a6bf6b` and `Cargo.toml` pinned to `duroxide = "=0.1.26"`.

#### Switch to crates.io duroxide-pg 0.1.34 + duroxide 0.1.29
- **DDL change (df schema):** None. This is a provider source and version update only.
- **DDL change (duroxide schema):** No extension upgrade script DDL is required. The BGW continues to own provider migrations through `MigrationPolicy::ApplyAll`.
- **Provider compatibility boundary:** v0.2.2 is the first version in the open-source `duroxide-pg` provider line. Earlier pg_durable versions used `duroxide-pg-opt`, whose SQL migrations and runtime state are not an upgrade source for this line. GitHub CI therefore sets `PROVIDER_COMPAT_START_VERSION=0.2.2` by default and skips A/B1/B2 coverage that would cross from `duroxide-pg-opt` to `duroxide-pg`. Azure's fork owns upgrade testing for the `duroxide-pg-opt` line.
- **Scenario A considerations:** Skipped for the v0.2.1 → v0.2.2 boundary in GitHub CI because v0.2.1 is before the provider compatibility start. Future `duroxide-pg`-line releases resume the normal fresh-vs-upgraded `df` schema comparison against the immediately previous compatible version.
- **Scenario B1 considerations:** The new `.so` is not required to execute against pre-v0.2.2 `duroxide-pg-opt` provider state. A failure pattern where basic `df.*` functions work but provider-backed execution remains pending is expected across that boundary and should not be treated as a GitHub CI regression. Future `duroxide-pg`-line releases must remain binary-compatible with v0.2.2+ schemas unless a later provider-line or major-version boundary explicitly changes that contract.
- **Scenario B2 considerations:** Data compatibility is not tested across the `duroxide-pg-opt` → `duroxide-pg` split. Future `duroxide-pg`-line releases must preserve data created under the immediately previous compatible version.
- **Current status:** Implemented — `Cargo.toml` exactly pins `duroxide = "=0.1.29"` and `duroxide-pg = "=0.1.34"`; `scripts/test-upgrade.sh` defaults `PROVIDER_COMPAT_START_VERSION` to `0.2.2` while allowing forks/CI to override it.

#### Named Results v2 — df.if_rows
- **DDL change:** Upgrade script adds `CREATE FUNCTION df.if_rows(result_name text, then_branch text, else_branch text)` — a new C-language function backed by the pgrx `#[pg_extern]` `if_rows_fn_wrapper` symbol.
- **Scenario A considerations:** Fresh install picks up `df.if_rows` automatically from pgrx-generated SQL. The upgrade path required an explicit `CREATE FUNCTION` in the upgrade script to match.
- **Scenario B1 considerations:** No backward compatibility concern. `df.if_rows` is a new function that doesn't exist in v0.1.1 schemas — it simply won't be callable until the customer runs `ALTER EXTENSION UPDATE`. The `.so` symbol exists but is never invoked from old schemas. All other changes (substitution engine rewrite, `Result` return type) are internal to orchestration code and don't touch any SQL queries or table schemas.
- **Scenario B2 considerations:** No data migration needed. The change is purely additive (new function) with no table or column changes.

#### Connection Limits — GUC-controlled pool sizing and backpressure
- **DDL change:** None. All changes are runtime-only (pool consolidation, semaphore backpressure, new GUCs).
- **Scenario A considerations:** No schema changes — the `df` schema equivalence contract is unchanged.
- **Scenario B1 considerations:** The new `.so` defaults match previous hard-coded values (management=6 covers the former polling=1 + activity=5, duroxide=10, backend=10→1 is internal). The new `.so` works against all previous schemas without any GUC configuration.
- **Scenario B2 considerations:** No data migration needed. Existing instances, nodes, and graphs are unaffected. The four new GUCs (`max_management_connections`, `max_duroxide_connections`, `max_user_connections`, `execution_acquire_timeout`) are Postmaster-context and default to values preserving previous behavior.

#### User isolation simplification (drop login_role)
- **DDL change:** v0.1.1 shipped with both `submitted_by REGROLE` and `login_role REGROLE` on `df.nodes` and `df.instances`. The v0.2.0 schema removes `login_role` from both tables and keeps `submitted_by` as the sole identity column. The composite unique constraint on instances is `UNIQUE (id, submitted_by)`, and the composite FK from nodes references `(id, submitted_by)`. This change is unrelated to the separate v0.2.0 `df.vars.owner` addition.
- **Scenario A considerations:** Schema comparison must verify the absence of `login_role` on both tables, the narrower unique constraint, and the updated FK definition.
- **Scenario B1 considerations:** The v0.1.1 schema does have `login_role`, so B1 must still verify that the new `.so` works with the old table shape and can insert into the legacy schema by populating `login_role` as needed. For execution compatibility, the supported contract is narrower: old instances continue to work when `submitted_by` itself has `LOGIN`, because the worker now authenticates directly as `submitted_by`. Instances that relied on the old split-identity path (`login_role != submitted_by`, especially `submitted_by` on a NOLOGIN role) are an intentional breaking change, not a compatibility target.
- **Scenario B2 considerations:** No data migration is needed for completed rows, but in-flight v0.1.1 work created under `SET ROLE` to a NOLOGIN role is expected to break under the new execution model. Upgrade planning and tests should call out that customers must drain or recreate those instances rather than expecting them to survive the change.

#### Remove default PUBLIC grants (secure-by-default)
- **DDL change (fresh install):** The `extension_sql!` block in `src/lib.rs` no longer contains GRANT statements to PUBLIC for the `df` schema, tables, or functions. Fresh installs require the admin to explicitly grant privileges to application roles.
- **DDL change (upgrade):** No REVOKE statements added to the upgrade script. Existing installs that upgraded from v0.1.1 retain their PUBLIC grants.
- **Scenario A considerations:** Grants intentionally differ between fresh install and upgrade. Fresh installs have no PUBLIC grants; upgraded installs retain them. The `scripts/test-upgrade.sh` Scenario A comparison excludes grant-related rows (`grant_table`, `grant_routine`, `grant_schema`) from the diff. This is an accepted divergence — grant changes are not part of the upgrade contract.
- **Scenario B1 considerations:** No impact. The `.so` code does not depend on grant state — it uses SPI (which inherits the calling user's privileges) and sqlx connections (which authenticate as the worker role). Whether grants are present or not does not affect the `.so`'s operation.
- **Scenario B2 considerations:** No impact. Existing data and grants are preserved after upgrade. The upgrade script does not modify permissions.

#### `pg_durable.enable_superuser_instances` GUC (runtime-only hardening)
- **DDL change:** None. This is a runtime-only change implemented entirely in the `.so`.
- **Scenario A considerations:** No schema changes — the `df` schema equivalence contract is unchanged.
- **Scenario B1 considerations:** The new GUC and the superuser checks in `df.start()`, `load_function_graph`, and `execute_sql` are all runtime behavior enforced by the new `.so`. The checks query `pg_catalog.pg_roles` (always present) and `df.instances`/`df.nodes` (present in all versions). The new `.so` works against all previous schemas without modification. The GUC defaults to `off`; the test runner sets it to `on` in `postgresql.conf` so that existing E2E tests that run as `postgres` are not broken.
- **Scenario B2 considerations:** No data migration needed. The GUC has no effect on schema shape or existing data.


- **DDL change (fresh install):** `REVOKE EXECUTE ON FUNCTION df.http(...) FROM PUBLIC` added to the `rls_and_grants` extension SQL block in `src/lib.rs`, executed immediately after `df.http()` is created. `df.grant_usage()` gains a second parameter `include_http boolean DEFAULT false`; when `false` (the default), the function revokes `df.http` from the role after the blanket `GRANT EXECUTE ON ALL FUNCTIONS` and emits a `WARNING` if the role still has effective HTTP access via a PUBLIC or inherited grant.
- **DDL change (upgrade):** No DDL executed. Section 7 of `pg_durable--0.1.1--0.2.0.sql` is a documentation comment only. The v0.1.1 PUBLIC grant on `df.http()` is intentionally preserved. `df.grant_usage()` is redefined with the new signature. Admins who want opt-in HTTP permissions after upgrade must run: `REVOKE EXECUTE ON FUNCTION df.http(text,text,text,jsonb,integer) FROM PUBLIC;`
- **Scenario A considerations:** Grant differences between fresh install and upgrade are already excluded from snapshot diffs. The `df.grant_usage` signature change (new optional parameter with a default) must match between the fresh-install SQL generated by pgrx and the `CREATE OR REPLACE FUNCTION` in the upgrade script.
- **Scenario B1 considerations:** No impact. The execution-time privilege check in `execute_http` queries the live catalog via `has_function_privilege`; it is not schema-version sensitive. On v0.1.1 schemas where PUBLIC still holds `EXECUTE` on `df.http()`, `has_function_privilege` returns `true` for all roles — consistent with the decision not to revoke the PUBLIC grant on upgrade.
- **Scenario B2 considerations:** No data migration needed. Existing nodes and instances are unaffected. Roles that had HTTP access via the v0.1.1 PUBLIC grant retain it after `ALTER EXTENSION UPDATE` (intentional).

#### Delegated df.grant_usage() / df.revoke_usage() (with_grant parameter)
- **DDL change (fresh install and upgrade):** `df.grant_usage()` gains a third parameter `with_grant boolean DEFAULT false`. When `true`, all privileges are granted WITH GRANT OPTION, including on the admin helpers (`df.grant_usage`, `df.revoke_usage`). The superuser check is removed from `df.grant_usage()` — authorization is now enforced by PostgreSQL-native mechanisms: EXECUTE privilege (revoked from PUBLIC) and WITH GRANT OPTION on underlying objects. `df.revoke_usage()` gains a self-revoke safety check using `pg_has_role(current_user, p_role, 'MEMBER')` to prevent a role from accidentally revoking its own (or a parent role's) access.
- **Scenario A considerations:** The `df.grant_usage` signature change (three parameters instead of two) must match between fresh-install SQL and the `CREATE OR REPLACE FUNCTION` in the upgrade script. Grant-related rows are already excluded from snapshot diffs.
- **Scenario B1 considerations:** No impact on backward compatibility. The `.so` code does not call `df.grant_usage` or `df.revoke_usage` internally — they are user-facing SQL functions. On v0.1.1 schemas, these functions don't exist at all; they are added by the upgrade script.
- **Scenario B2 considerations:** The upgrade script redefines both functions with `CREATE OR REPLACE FUNCTION`, replacing the two-parameter version with the three-parameter version. The new default (`with_grant => false`) preserves existing behavior for callers using `df.grant_usage(role)` or `df.grant_usage(role, include_http => true)`. No data migration needed.
