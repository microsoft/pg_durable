# Move Duroxide Provider Schema

Issue: [Move PostgresProvider's schema out of "duroxide" microsoft/pg_durable#175](https://github.com/microsoft/pg_durable/issues/175)

## Goal

Move pg_durable's internal duroxide provider schema away from the generic `duroxide` name for new installations, while preserving existing installations that already have an extension-owned `duroxide` schema.

The chosen default provider schema name for new installations is:

```text
_duroxide
```

Rationale for the name:

- Bare identifier (no quoting required anywhere). `_` is a legal leading character for PostgreSQL identifiers.
- The leading underscore signals "internal / not part of the public API," matching common PostgreSQL convention for implementation-detail objects.
- Makes the relationship to duroxide-pg obvious without overloading a more generic prefix like `_df`.

There is no GUC. The schema name is an implementation detail of pg_durable, not an operator-facing setting.

## Current State

The provider schema is currently hardcoded as `duroxide` in several places:

- `src/types.rs` defines `DUROXIDE_SCHEMA = "duroxide"` and passes it to both backend and worker `duroxide_pg::ProviderConfig` values.
- `src/lib.rs` creates `CREATE SCHEMA duroxide;` as an extension-owned schema during `CREATE EXTENSION pg_durable`.
- `src/worker.rs` checks that `duroxide` exists and is owned by the `pg_durable` extension before running `MigrationPolicy::ApplyAll`.
- `src/worker.rs` writes readiness state to `duroxide._worker_ready`.
- `src/client.rs`, E2E setup SQL, upgrade tests, and helper scripts poll `duroxide._worker_ready`.

The security model intentionally depends on two properties:

1. `CREATE EXTENSION` creates the provider schema without `IF NOT EXISTS`, so a pre-existing schema with that name blocks installation instead of being adopted.
2. The background worker verifies the provider schema is extension-owned before applying duroxide migrations.

Any implementation must preserve both properties.

## Compatibility Requirement

Already-shipped versions in Azure and open source assume the provider schema is named `duroxide`:

- Azure-shipped: v0.1.1, v0.2.1, v0.2.2 in progress
- Open source supported baseline: v0.2.2

Therefore, a new binary must continue to work with existing databases where `pg_durable` already owns a `duroxide` schema. Existing instances and engine state must remain in place and must not be migrated implicitly to a different schema.

The compatibility rules:

- If the install records `duroxide` as its provider schema, use `duroxide`.
- If the install records `_duroxide` (or any future name) as its provider schema, use that name.
- Do not rename, copy, drop, or migrate provider state automatically.
- A fresh `CREATE EXTENSION pg_durable` under the new SQL creates and uses `_duroxide`.
- A `.so` upgrade that arrives **without** `ALTER EXTENSION pg_durable UPDATE` must continue to operate against the legacy `duroxide` schema (see "Selection algorithm" below).

There is **no in-place migration path** from `duroxide` to `_duroxide` for an existing cluster that wants to adopt the new name while preserving engine state. The only supported "adopt the new name" path is `DROP EXTENSION pg_durable CASCADE` followed by `CREATE EXTENSION pg_durable`, which is a destructive reset of durable engine state. This is acknowledged as a deliberate non-goal of this work.

## Design Overview

Rather than a GUC, the selected provider schema is exposed by a small extension-owned SQL function:

```sql
CREATE FUNCTION df.duroxide_schema() RETURNS TEXT
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $$ SELECT '_duroxide'::TEXT $$;
```

Both the install SQL and any future upgrade scripts are responsible for defining this function with the correct value for the lifecycle path being taken:

- The **fresh install** SQL (the new version's primary install script) defines the function to return `'_duroxide'`.
- The **upgrade script** `pg_durable--0.2.2--<v-next>.sql` defines the function to return `'duroxide'`. This pins existing clusters to their already-created legacy schema deterministically, regardless of any other heuristics.

The background worker and backend sessions read the value once at startup (or whenever they need it) and use it everywhere the provider schema is referenced.

### Why a function instead of a table?

- Mirrors the existing pattern of [`df.target_database()`](../src/lib.rs) — a parameterless function used to expose install-time configuration to validation SQL and to Rust code.
- No row management, no `CHECK` constraints to enforce a single row, no `UPDATE` ergonomics.
- The value is baked into an extension-owned object, which makes it tamper-resistant by default (non-superusers cannot `CREATE OR REPLACE` it).
- Changing the value across versions is a straightforward `CREATE OR REPLACE FUNCTION` in the relevant upgrade script.

### Selection algorithm (BGW + backend)

At runtime the selected schema is computed once per connection / once at BGW startup:

1. Try to call `df.duroxide_schema()`. If it returns a non-empty value, use that value.
2. If the function does not exist (PostgreSQL error code `42883`, `undefined_function`), fall back to `'duroxide'`.

Rule 2 is the **only** fallback, and exists strictly for the documented operational reality that customers may receive a new `.so` through a maintenance update without running `ALTER EXTENSION pg_durable UPDATE`. In that case:

- The cluster is still at the old extension version, so the helper function does not yet exist.
- The pre-existing extension-owned `duroxide` schema is the only possible provider schema.
- Falling back to `'duroxide'` is unambiguous and safe.

The fallback is self-deleting: as soon as the operator runs `ALTER EXTENSION pg_durable UPDATE`, the function is defined (by the upgrade script) to return `'duroxide'`, and selection step 1 wins on every subsequent startup.

No GUC source inspection, no `pg_depend` scan, no metadata-vs-GUC priority puzzle.

## Compatibility Matrix

| Scenario | Selection outcome | Provider schema actually used |
|---|---|---|
| Fresh `CREATE EXTENSION` on new version | Step 1: function returns `'_duroxide'` | `_duroxide` |
| Existing v0.2.2 cluster, new `.so` deployed, **no** `ALTER EXTENSION UPDATE` | Step 2: function missing, fallback | `duroxide` |
| Existing v0.2.2 cluster, new `.so` deployed, `ALTER EXTENSION UPDATE` run | Step 1: upgrade script defined function to return `'duroxide'` | `duroxide` |
| Future fresh install on v0.2.4+ where default changes again | Step 1: install script defines function to return the new value | New value |
| Operator manually drops `_duroxide` schema on a fresh install | Worker readiness check fails (extension-owned schema missing) | N/A — operator error, loud failure |

## Implementation Plan

### Phase 1: Schema-name abstraction

- Replace the hardcoded `DUROXIDE_SCHEMA` constant in `src/types.rs` with a runtime-resolved value cached at BGW startup and per backend session.
- Introduce a small helper, e.g. `resolve_duroxide_schema(conn) -> String`, implementing the selection algorithm (call function, catch `42883`, fall back to `"duroxide"`).
- Update `backend_provider_config()` and `worker_provider_config()` to consume the resolved value.
- Update debug/log messages to display the resolved schema.

### Phase 2: Install SQL changes

- Define `df.duroxide_schema()` in the new version's install SQL, returning `'_duroxide'`.
- Replace the literal `CREATE SCHEMA duroxide;` with `CREATE SCHEMA _duroxide;` (still **without** `IF NOT EXISTS`, preserving the no-adoption rule).
- Both objects are extension members by virtue of being declared inside the extension install SQL.
- No additional install-time validation is needed: a pre-existing `_duroxide` schema makes `CREATE SCHEMA` fail, which fails `CREATE EXTENSION` — the same protection the current literal `duroxide` enjoys.

### Phase 3: Upgrade script

- `sql/pg_durable--0.2.2--<v-next>.sql` defines `df.duroxide_schema()` returning `'duroxide'`.
- The script must **not** create `_duroxide`, must **not** rename `duroxide`, and must **not** touch existing provider state.
- The script is the contract that says "this cluster is staying on `duroxide` forever."

### Phase 4: Worker ownership and migration flow

- Generalize `check_duroxide_schema_owned()` to accept the resolved schema name.
- Generalize `has_extension_owned_duroxide_objects()` and `release_extension_owned_duroxide_objects()` to filter on the resolved schema.
- Generalize `write_worker_ready()` to write to `<resolved_schema>._worker_ready`.
- Keep `MigrationPolicy::ApplyAll` in the worker and `VerifyOnly` in backend sessions.
- Because `_duroxide` is a bare identifier, no special quoting is required for the new default. The schema-name string can be interpolated into SQL via the same code paths used today, but it is still good practice to use `quote_ident` for any dynamic-schema SQL to remain robust against future name choices.

### Phase 5: Backend readiness checks

- Generalize `is_worker_ready()` in `src/client.rs` to check `<resolved_schema>._worker_ready`.
- Retain the catalog-existence pre-check before querying the readiness table so missing-schema cases produce a clear "not ready" signal rather than a SQL error.
- Ensure non-superuser backend sessions have `USAGE` on the resolved schema and `SELECT` on `_worker_ready` (existing grants on the literal `duroxide` schema move to the new name).

### Phase 6: Tests and scripts

Add or update checks for:

- Fresh install creates `_duroxide` and `df.duroxide_schema()` returns `'_duroxide'`.
- Pre-existing `_duroxide` schema blocks `CREATE EXTENSION`.
- New `.so` against an unmigrated v0.2.2 schema:
  - `df.duroxide_schema()` does not exist.
  - BGW resolves to `'duroxide'` via fallback.
  - Existing workflows continue to run.
- After `ALTER EXTENSION UPDATE` on a v0.2.2 cluster:
  - `df.duroxide_schema()` exists and returns `'duroxide'`.
  - Selection step 1 is taken on subsequent restarts.
  - Provider state is unchanged.
- E2E setup SQL and helper scripts no longer hardcode the string `duroxide`. Where direct SQL must reference the schema, fetch the name via `SELECT df.duroxide_schema()` with the same `42883` fallback.

Touch points likely include:

- `tests/e2e/sql/00_setup_playground.sql`
- `sql/00_init.sql`
- `scripts/test-e2e-local.sh`
- `scripts/test-upgrade.sh`
- Any E2E tests that directly reference `duroxide._worker_ready`

### Phase 7: Documentation

Update:

- `docs/bgw-applies-migrations.md`
- `docs/extension_lifecycle.md`
- `docs/upgrade-testing.md`
- `USER_GUIDE.md` connection/troubleshooting sections if readiness probes or drop/recreate guidance changes

Document clearly that:

- The provider schema is an implementation detail, not a configurable setting.
- Existing `duroxide`-based installs are not migrated to `_duroxide`; they keep using `duroxide` indefinitely.
- The only way to adopt `_duroxide` on an existing cluster is `DROP EXTENSION pg_durable CASCADE` followed by `CREATE EXTENSION pg_durable`, which destroys durable engine state.

## Security Notes

- `df.duroxide_schema()` is created by the extension install / upgrade scripts and is therefore owned by the extension owner (typically a superuser). Non-superusers cannot `CREATE OR REPLACE` it.
- The function is `IMMUTABLE PARALLEL SAFE` and contains a literal string; no SQL injection surface.
- Falling back to `'duroxide'` on `42883` is safe because that fallback only fires when the new helper function is genuinely absent, which can only happen on a pre-upgrade-script extension version. At that version the only possible extension-owned provider schema is `duroxide`.
- The BGW must still verify extension ownership of the resolved schema before applying duroxide migrations. This invariant is unchanged.

## Open Questions

1. **Cache lifetime in backend sessions.** Resolving the schema per connection is cheap (one SQL call). Caching it for the process lifetime is fine because the value cannot change without an extension upgrade, which in turn requires a session reconnect to see new function definitions reliably. Recommend: resolve once on first use per session, cache for session lifetime.
2. **Whether to expose `df.duroxide_schema()` as `SECURITY DEFINER` or rely on default invoker rights.** Default invoker rights are sufficient since the function only returns a literal. Recommend: leave as default to minimize surface area.
3. **Whether to also remove the `DUROXIDE_SCHEMA` constant from any Rust test fixtures.** Yes, but only where tests run against a real PostgreSQL backend. Pure unit tests that never touch the schema can keep using a constant for clarity.

## Validation Strategy

Minimum validation after implementation:

```bash
cargo fmt -p pg_durable -- --check
cargo build --features pg17
./scripts/test-e2e-local.sh 00_setup_playground
./scripts/test-upgrade.sh --verbose
```

If time is short, prioritize:

1. A targeted E2E that verifies a fresh install creates `_duroxide` and that `df.duroxide_schema()` returns `'_duroxide'`.
2. An upgrade path (B1) test that verifies the new `.so` against a v0.2.2 schema (with no `ALTER EXTENSION UPDATE` run) continues to use `duroxide` via the `42883` fallback.
3. An upgrade-then-restart test that verifies, after `ALTER EXTENSION UPDATE`, selection step 1 is taken and the cluster still uses `duroxide`.

## Issue Update Draft

Proposed summary to add to the GitHub issue:

> We will rename the duroxide provider schema for new pg_durable installs to `_duroxide` (bare identifier, no quoting required, leading underscore signals internal/private). No GUC will be added — the schema name is an implementation detail of pg_durable, not an operator-facing setting. Existing installs that already own a `duroxide` schema will continue to use it indefinitely; there is no in-place migration to `_duroxide`. The selected schema is exposed by a small extension-owned function `df.duroxide_schema()`: the fresh-install SQL defines it to return `'_duroxide'`, and the `0.2.2 -> <v-next>` upgrade script defines it to return `'duroxide'`. The BGW and backend sessions resolve the schema by calling this function with a single fallback: if the function does not exist (error 42883), assume legacy `'duroxide'`. This fallback covers the case where a new `.so` is deployed without `ALTER EXTENSION UPDATE` being run, and is self-deleting once the upgrade script has run.

## Current Recommendation

Implement as described above. This design:

- Removes all GUC-related ambiguity from the original proposal.
- Has a single, well-defined fallback path tied to a concrete PostgreSQL error code rather than to fuzzy heuristics about admin intent or `pg_depend` state.
- Keeps the security invariants (no schema adoption, BGW verifies extension ownership) intact.
- Avoids identifier-quoting churn by choosing a bare-identifier default (`_duroxide`).
- Localizes "which schema does this version use" into the version-specific install and upgrade SQL, where version-specific decisions naturally belong.
- Explicitly declines to offer in-place schema migration, making the operational contract clear to operators: keep state on `duroxide`, or destroy state and adopt `_duroxide`.
