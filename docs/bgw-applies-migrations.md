# BGW-Managed Duroxide Migrations

**Status:** Implemented  
**Target version:** 0.2.0

## Motivation

Previously, `CREATE EXTENSION pg_durable` included the full duroxide-pg-opt schema DDL via `extension_sql_file!("../sql/duroxide_install.sql")`, creating all duroxide tables, functions, indexes, and triggers as extension-owned objects. This change moved schema migration responsibility from the extension to the background worker (BGW).

Three concrete motivations:

1. **Decoupling**: pg_durable extension state (`df.*`) and duroxide engine state (`duroxide.*`) have different lifecycles. The extension schema is a stable contract; the duroxide schema is an implementation detail that may evolve independently.

2. **Future provider flexibility**: pg_durable may use a different duroxide provider in the future. If DDL lives in the BGW rather than the extension SQL, swapping providers does not require touching extension install/upgrade scripts.

3. **Backward compatibility relief**: duroxide-pg-opt does not offer binary compatibility with old schema versions. With BGW-managed migrations, new duroxide migrations are applied automatically at BGW startup — no extension upgrade involvement needed, no `.so` compatibility burden.

## Architecture

### What `CREATE EXTENSION pg_durable` does (changed)

**Before:** Extension SQL includes the full duroxide DDL (~2300 lines), creating all duroxide objects as extension members. The `_duroxide_migrations` table is pre-populated with rows 1–N.

**After:** Extension SQL creates only a bare `CREATE SCHEMA duroxide;` — no `IF NOT EXISTS`. The empty schema is an extension-owned object.

The absence of `IF NOT EXISTS` is intentional: if a `duroxide` schema already exists when the user runs `CREATE EXTENSION pg_durable`, the statement fails immediately with a clear PostgreSQL error. This prevents a pre-existing (potentially attacker-crafted) schema from silently becoming part of the extension's state.

The `df.*` tables, RLS policies, functions, and operators are all unchanged.

### Background worker initialization (changed)

**Before:**
1. Wait for extension to be created
2. `PostgresProvider::new_with_config(VerifyOnly)` — verifies schema is already populated
3. Write epoch sentinel to `df._worker_epoch`
4. Start duroxide runtime

**After:**
1. Wait for extension to be created
2. Verify `duroxide` schema exists **and is extension-owned** (security gate)
3. Release extension ownership of any objects inside the `duroxide` schema (no-op on fresh installs; on upgrades from ≤0.1.1 it de-registers the embedded DDL so that `ApplyAll` can modify those objects)
4. `PostgresProvider::new_with_config(ApplyAll)` — applies pending migrations (no-op if already current), creates activity pool, starts duroxide runtime
5. Write readiness record to `duroxide._worker_ready`
6. Write epoch sentinel to `df._worker_epoch`

Steps 4–6 are grouped inside the main loop in `run_duroxide_runtime()`. Step 4 is performed by `initialize_duroxide_runtime()`, which returns the running runtime handle. Steps 5 and 6 execute immediately after, before entering the running-state poll loop.

Step 1 is unchanged from the previous design and is not detailed further.

#### Steps 2–3: ownership check and release

The BGW queries `pg_depend` to confirm the schema was created by the extension:

```sql
SELECT EXISTS (
    SELECT 1
    FROM pg_namespace n
    JOIN pg_depend d
        ON d.objid = n.oid
        AND d.classid = 'pg_namespace'::regclass
        AND d.deptype = 'e'
    JOIN pg_extension e
        ON e.oid = d.refobjid
        AND e.extname = 'pg_durable'
    WHERE n.nspname = 'duroxide'
)
```

If this check fails (schema missing or not extension-owned), the BGW logs a warning and retries after the normal initialization retry interval (`INIT_RETRY_INTERVAL`). Under normal operation this can only fail transiently (race between extension creation and BGW polling) or if someone manually created a `duroxide` schema before or after extension install, which warrants visible log noise.

After the ownership check passes, the BGW releases extension ownership of any objects inside the `duroxide` schema. This is a no-op on fresh installs (schema is empty). On upgrades from ≤0.1.1 it de-registers the embedded DDL so that future migration DDL can modify those objects.

#### Step 4: `MigrationPolicy::ApplyAll`

- **Fresh 0.2.0 install**: schema is empty → BGW creates all duroxide tables, functions, indexes, triggers, and records all migrations in `_duroxide_migrations` (5 as of 0.2.0).
- **Upgraded from 0.1.1**: all migrations already recorded in `_duroxide_migrations` → `ApplyAll` detects no pending work → no-ops → starts runtime normally.
- **Future duroxide-pg-opt upgrade**: new migration files embedded in the binary are applied automatically without any `ALTER EXTENSION` involvement.

Unknown-migration rejection is always enforced: `duroxide-pg-opt` unconditionally calls `check_no_unknown_migrations()` after both `ApplyAll` and `VerifyOnly`. If the database has a migration row the binary does not recognize, initialization fails with an error (schema is newer than code — indicates a downgrade scenario).

#### Step 5: readiness record via `duroxide._worker_ready`

After `CREATE EXTENSION`, the duroxide schema is empty until the BGW completes its first `ApplyAll`. Similarly, after a binary upgrade that introduces new duroxide migrations, the schema may be incompatible until the BGW applies the pending changes. Calling `df.status()`, `df.result()`, or any function that instantiates a duroxide client during either window fails with a schema-not-initialized error.

Readiness is **not** exposed as a SQL function. It is an internal Rust check called by `get_duroxide_client()` before instantiating the duroxide client. If the check fails, the function raises a PostgreSQL error: `"pg_durable background worker not yet initialized — try again in a moment"`. The readiness state is stored in a single-row table written by the BGW:

```sql
CREATE TABLE IF NOT EXISTS duroxide._worker_ready (
    sentinel        BOOLEAN PRIMARY KEY DEFAULT TRUE,
    CONSTRAINT      only_one_sentinel CHECK (sentinel),
    schema_version  INT NOT NULL,
    initialized_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

After `ApplyAll` succeeds, the BGW writes a row with the current `WORKER_SCHEMA_VERSION` — but only if the row is missing or has a different version. If a row already exists with `schema_version = WORKER_SCHEMA_VERSION`, the write is skipped: the schema state hasn't changed and `initialized_at` should reflect when it was first established, not when the BGW last restarted.

```rust
/// Monotonically increasing schema version written to duroxide._worker_ready
/// after successful BGW initialization. Increment whenever a new binary
/// introduces new duroxide-pg-opt migration scripts or any other BGW-applied
/// duroxide schema change.
const WORKER_SCHEMA_VERSION: i32 = 1;
```

The internal readiness check in `get_duroxide_client()` (SPI, backend process context):

```rust
fn is_worker_ready() -> bool {
    Spi::get_one::<i32>(
        "SELECT schema_version FROM duroxide._worker_ready LIMIT 1"
    )
    .ok()
    .flatten()
    .map(|v| v >= WORKER_SCHEMA_VERSION)
    .unwrap_or(false)  // table missing or no row → not ready
}
```

The integer version is decoupled from the pg_durable release version string:

- A patch release that introduces no duroxide schema changes does not increment `WORKER_SCHEMA_VERSION` — the existing row from the previous binary remains valid.
- When a release does change the duroxide schema (new migration files or any other BGW-applied DDL), `WORKER_SCHEMA_VERSION` is incremented, and the BGW overwrites the row after completing `ApplyAll`.
- Old binaries writing a lower version number will cause `is_worker_ready()` in the new binary to return `false` until the new BGW has run.

Under normal circumstances the table is populated within a few seconds of `CREATE EXTENSION` (bounded by the BGW's extension-detection poll interval, ~5s).

**Backend sessions** are unchanged: `backend_provider_config()` retains `MigrationPolicy::VerifyOnly`. Backend sessions never run DDL.

### `DROP EXTENSION` semantics

Once the BGW has run (any install path):

- The `duroxide` schema itself is extension-owned.
- The tables and functions inside it are **not** extension-owned (fresh installs: created by `ApplyAll` outside the extension transaction; upgrades: released by the BGW before `ApplyAll`).
- `DROP EXTENSION pg_durable` fails: PostgreSQL tries to drop the extension-owned schema but finds non-owned objects inside it.
- `DROP EXTENSION pg_durable CASCADE` succeeds: drops `df.*` (extension-owned), drops the `duroxide` schema (extension-owned), CASCADE drops everything inside the `duroxide` schema.

**CASCADE is always required.** We document this unconditionally and do not qualify it by upgrade path.

### Security model

Two-layer defense against schema squatting:

1. **`CREATE SCHEMA duroxide`** (no `IF NOT EXISTS`): blocks installation if a `duroxide` schema already exists. Prevents pre-installation schema squatting — an attacker cannot pre-create a `duroxide` schema with malicious functions and have the extension silently adopt it.

2. **BGW ownership check via `pg_depend`**: prevents the BGW from applying migrations into a schema it does not own. Handles the residual case where something creates a `duroxide` schema after extension installation but before the BGW first polls.

Together these ensure the BGW only ever writes into state it (via the extension) created and owns.

## Upgrade path: 0.1.1 → 0.2.0

The 0.1.1 → 0.2.0 upgrade script does not touch the duroxide schema. The BGW handles ownership release at startup.

### Fresh 0.2.0 install
- `CREATE EXTENSION pg_durable` creates `df.*` + empty `duroxide` schema.
- BGW polls, detects extension, verifies ownership, runs `ApplyAll` (applies migrations 1–5), writes `duroxide._worker_ready` row (`schema_version = 1`), writes epoch sentinel to `df._worker_epoch`, starts runtime.
- Duroxide tables/functions exist but are not extension-owned.

### Upgrade 0.1.1 → 0.2.0
- `ALTER EXTENSION pg_durable UPDATE TO '0.2.0'` applies the standard 0.2.0 changes to `df.*` (vars owner column, RLS, search_path hardening).
- The duroxide schema is left untouched by the upgrade script.
- BGW (0.2.0 binary) polls, detects extension, verifies ownership (✓ — duroxide schema is extension-owned), releases extension ownership of duroxide objects, runs `ApplyAll` (all 5 migrations already recorded → no-op), writes `duroxide._worker_ready` row (`schema_version = 1`), writes epoch sentinel to `df._worker_epoch`, starts runtime.

The BGW releases extension ownership of objects in the duroxide schema before running `ApplyAll`; otherwise PostgreSQL would reject any migration DDL that modifies them.

### Upgrade test impact

#### Scenario A (schema equivalence)

`test-upgrade.sh`'s `snapshot_schema()` only captures the `df` schema (all queries filter `table_schema = 'df'` or `n.nspname = 'df'`). The duroxide schema is not compared. Scenario A continues to pass without changes.

**Documentation note:** the Scenario A contract ("fresh install matches upgrade path") applies only to the `df` schema. The duroxide schema is not compared, but both paths converge to the same state (objects not extension-owned) after the BGW runs.

#### Scenario B1 (binary backward compatibility)

The 0.2.0 `.so` running against a 0.1.1 schema:
- Ownership check: 0.1.1 has duroxide schema extension-owned → passes.
- Release: de-registers extension ownership of duroxide objects.
- `ApplyAll`: migrations 1–5 already recorded → no-ops.
- Runtime starts normally.

The `df.vars.owner` B1 concern (from PR #53, version-detection at runtime) is orthogonal and handled separately.

#### Readiness polling in tests

Previously `CREATE EXTENSION` populated duroxide synchronously. Now it is asynchronous. Any code that exercises the full workflow lifecycle (calls `df.start()` and waits for completion) must wait for the BGW to finish after creating the extension. Three places handle this:

- **`tests/e2e/sql/00_setup_playground.sql`** — `_e2e_wait_for_worker_ready()` polls `duroxide._worker_ready` directly (checks row existence, not `schema_version` — E2E tests always run against the current version). Called at end of setup and by tests that DROP/CREATE the extension mid-suite. The same pattern is used inline in `sql/00_init.sql`.

- **`scripts/test-upgrade.sh`** — `wait_for_ready()` must work against both 0.1.1 and 0.2.0+ schemas. Probes `information_schema.tables` for `duroxide._worker_ready` at runtime; falls back to `df._worker_epoch` for pre-0.2.0 schemas.

Call `wait_for_ready` after any `CREATE EXTENSION` in scenarios that subsequently call `df.start()`.

## Files changed

### Deleted
- `scripts/gen-duroxide-install-sql.sh`
- `scripts/verify-duroxide-migrations.sh`
- `sql/duroxide_install.sql`
- `sql/duroxide_upstream/` (entire directory, 5 migration copies)

### Modified

| File | What changes |
|------|-------------|
| `src/lib.rs` | Replace `extension_sql_file!("../sql/duroxide_install.sql", name = "duroxide_migrations_install", ...)` with `extension_sql!("CREATE SCHEMA duroxide;", name = "create_duroxide_schema", requires = ["validate_database"])`. Add `WORKER_SCHEMA_VERSION` constant. |
| `src/client.rs` | Add internal `is_worker_ready()` fn (SPI check against `duroxide._worker_ready`). Call it from `get_duroxide_client()` and raise an error if not ready. |
| `src/types.rs` | `worker_provider_config()`: change `MigrationPolicy::VerifyOnly` → `MigrationPolicy::ApplyAll`. Update doc comment. |
| `src/worker.rs` | Add `check_duroxide_schema_owned`, `release_extension_owned_duroxide_objects`, `has_extension_owned_duroxide_objects` async helpers. Insert ownership check + release step in `initialize_duroxide_runtime()` before constructing `PostgresProvider`. After `ApplyAll` succeeds, upsert `duroxide._worker_ready` row with `WORKER_SCHEMA_VERSION`. |
| `sql/pg_durable--0.1.1--0.2.0.sql` | Unchanged — no duroxide DDL added. Included for completeness. |
| `sql/pg_durable--0.1.1.sql` | **Not changed** — kept as upgrade test fixture. Contains extension-owned duroxide DDL as it was when generated, which is correct for B1/B2 testing. |
| `scripts/test-upgrade.sh` | Add `wait_for_ready()` helper (polls `duroxide._worker_ready`). Call it after any `CREATE EXTENSION` in scenarios that subsequently exercise workflow execution. |
| `.github/workflows/ci.yml` | Remove the "Verify duroxide migrations match upstream" step. |
| `.github/copilot-instructions.md` | Remove "Duroxide Migration Sync Workflow" section and related scripts from the scripts table. Update BGW and activity descriptions. |
| `docs/extension_lifecycle.md` | Update sections on extension-managed schema (section 1) and BGW lifecycle (section 3). Remove references to `gen-duroxide-install-sql.sh` and migration verification. Update state machine to show ownership-check and `_worker_ready` write steps. |
| `docs/upgrade-testing.md` | Add duroxide ownership entry to the v0.1.1→v0.2.0 version-specific changes section. Note that both paths converge (objects not extension-owned after BGW runs). Note `wait_for_ready()` requirement in upgrade test infrastructure. |
| `USER_GUIDE.md` | Add note that `DROP EXTENSION pg_durable CASCADE` is always required. Update readiness polling to use `duroxide._worker_ready` directly. |

The `duroxide-pg-opt/` submodule and `submodules: true` in CI remain — the submodule is still a Rust code dependency.

## What this enables going forward

To summarize the benefits outlined in Motivation:

- **Duroxide upgrades decouple from pg_durable releases**: adding a new migration to `duroxide-pg-opt` requires no changes to pg_durable extension SQL, upgrade scripts, or the migration-copy sync scripts. The BGW applies it on next startup.
- **Provider swap path**: swapping `duroxide-pg-opt` for a different provider means changing BGW initialization code, not extension DDL.
- **No extension upgrade required for engine fixes**: duroxide bug fixes that involve schema changes are applied automatically by the BGW after the `.so` is updated, even for customers who never run `ALTER EXTENSION UPDATE`.
- **Cleaner `pg_dump`**: duroxide schema objects are not extension-owned (on any install path), so they do not appear as extension members in `pg_dump` output.
