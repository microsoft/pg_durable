# Upgrade Testing Plan

## Deployment Model

pg_durable follows a two-phase upgrade model:

1. **Binary update** (maintenance window): The `.so` shared library is replaced. PostgreSQL processes load the new `.so` on next connection. This happens during scheduled maintenance.
2. **Schema update** (customer-initiated): `ALTER EXTENSION pg_durable UPDATE TO '<version>'` runs the upgrade SQL script. Customers may defer this for days, months, or indefinitely.

This means the new `.so` **must be backward compatible** with the previous version's schema. The `.so` and the upgrade script are not atomic — there is an extended period where the new binary runs against the old schema.

We never downgrade. Downgrade scripts are not needed.

## Test Scenarios

### Chain tests vs. direct-contact tests

Scenarios A and B2 are **chain tests**: PostgreSQL applies upgrade scripts sequentially (v0.1.1→v0.2.0→v0.3.0), so each step is validated transitively by its own version's CI. Testing the current upgrade script against the immediately previous version is sufficient.

Scenario B1 is a **direct-contact test**: the `.so` faces whatever raw schema the customer has, with no intermediate transformation. There is no chain — a customer on v0.1.1 who receives the v0.5.0 binary without ever upgrading has a v0.1.1 schema with a v0.5.0 `.so`. That's why B1 must test against all previous versions.

### Major version boundaries

All three scenarios scope to versions within the same major version:
- **B1**: A major version bump is the boundary where binary backward compatibility may be dropped. The new `.so` does not need to work with schemas from a previous major version.
- **A and B2**: Upgrade scripts still need to work across a major version bump — customers must be able to upgrade their schema. However, the transitive chain property means testing only the immediately previous version is still sufficient.

### Scenario A: Schema Upgrade Correctness

**Goal:** Verify that `ALTER EXTENSION UPDATE` produces an identical schema to a fresh `CREATE EXTENSION`.

**Contract:** For a not-yet-released version, the fresh-install schema is expected to match what an existing customer would get by starting from the immediately previous shipped version and applying the shipped upgrade chain to the new version. In other words, Scenario A treats the upgrade result as the reference shape for already-shipped versions. If fresh install and upgrade differ before release, prefer aligning the new version's fresh-install DDL with the upgrade path unless there is a deliberate reason to change the contract.

**Method:**
1. Install current `.so` and all upgrade SQL files
2. In a clean test database, run `CREATE EXTENSION pg_durable VERSION '<prev>'` → `ALTER EXTENSION pg_durable UPDATE TO '<current>'`, then capture a schema snapshot
3. In the same clean test database (after dropping the extension) or in a second clean database, run `CREATE EXTENSION pg_durable` and capture a fresh-install snapshot
4. Compare schemas: tables, columns, types, constraints, indexes, RLS policies, grants

**What it catches:**
- Missing DDL in upgrade script (forgotten tables, columns, policies)
- Wrong column types, defaults, or constraint names
- Ordering issues in upgrade SQL

**Why only the immediately previous version?** Upgrade scripts are frozen once shipped. The chain of upgrades (v0.1.1 → v0.2.0 → v0.3.0) is validated transitively — each version's CI tests its own upgrade script. Only the current work-in-progress upgrade script might introduce an inconsistency, so testing it against the immediately previous version is sufficient.

**Priority:** High — foundational test, catches the most common class of upgrade bugs.

### Scenario B1: Binary Backward Compatibility

**Goal:** Verify that the new `.so` works correctly against **all** previous versions' schemas, not just the immediately previous one. Customers may never run `ALTER EXTENSION UPDATE`, so the new binary must work against any older schema.

This is the **most deployment-critical test** because the new binary may run against any older schema indefinitely. A customer on v0.1.1 who receives the v0.5.0 binary without ever upgrading must still be able to use the extension.

We test against all previous versions within the same major version. A major version bump is the boundary where backward compatibility may be dropped.

**Method:**
1. Install the new `.so`
2. For each previous version (same major): create the extension with that version's install SQL
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

**Goal:** Verify that data created under the previous version remains accessible and functional after `ALTER EXTENSION UPDATE`.

This is a **chain test** (like Scenario A) — upgrade scripts are applied sequentially, so testing against the immediately previous version is sufficient. Each intermediate upgrade was validated by its own version's CI.

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
- `scripts/test-upgrade.sh` — runs Scenarios A, B1, and B2
- CI step in `.github/workflows/ci.yml`

### Per-version checklist

Each PR that changes the extension schema or modifies SQL queries in Rust code should:

1. Add the necessary DDL to the upgrade script (`sql/pg_durable--<prev>--<current>.sql`)
2. Ensure the `.so` is backward compatible with **all** previous schemas within the same major version (Scenario B1)
3. Add version-specific notes to this document under "Version-Specific Changes" below
4. Pass upgrade tests in CI

### Future work

- **pg_regress-style upgrade test**: pg_cron and similar extensions use `pg_regress` with expected-output diffs to validate upgrade scripts. This is simpler than our Scenario A schema snapshot approach but less thorough — it doesn't cover B1 (binary backward compat) or B2 (data survival). Consider adopting as a complementary check if `pg_regress` integration becomes worthwhile.

### Preparing for the next version

**Minor release** (e.g. 0.2.0 → 0.3.0):
1. Create empty `sql/pg_durable--<N>--<N+1>.sql` upgrade script
2. Bump `Cargo.toml` version to `<N+1>`

If this is the first minor after a new major (e.g. 1.0.0 → 1.1.0), also:

3. Check in `sql/pg_durable--<major>.sql` as the first install SQL fixture for the new major (e.g. copy the generated `pg_durable--1.0.0.sql` from the extension directory)
4. Optionally delete the previous major's install SQL fixture and upgrade scripts — they are no longer needed by any of A, B1, or B2

No additional fixture is needed for subsequent minors — intermediate versions are reconstructed by chaining `ALTER EXTENSION UPDATE` from the first version's install SQL.

**Major release** (e.g. 0.x → 1.0.0):
1. Create empty `sql/pg_durable--<N>--<1.0.0>.sql` upgrade script
2. Bump `Cargo.toml` version to `<1.0.0>`

`cargo pgrx package` generates the new major's install SQL. The previous major's install SQL and upgrade scripts are still needed for the A/B2 upgrade chain. B1 will be a no-op — there are no previous versions within the new major to test backward compatibility against.

---

## Version-Specific Changes

Each schema-changing PR should add a section here documenting what changed,
what the upgrade script handles, and any backward compatibility considerations.

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
- **Current status:** Implemented — submodule at `4a6bf6b`, `Cargo.toml` pinned to `duroxide = "=0.1.26"`.
