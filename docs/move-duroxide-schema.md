# Move Duroxide Provider Schema

Issue: [Move PostgresProvider's schema out of "duroxide" microsoft/pg_durable#175](https://github.com/microsoft/pg_durable/issues/175)

## Goal

Move pg_durable's internal duroxide provider schema away from the generic `duroxide` name for new installations, while preserving existing installations that already have an extension-owned `duroxide` schema.

The proposed default provider schema name for new installations is:

```text
df-duroxide
```

The schema name should also be configurable through a postmaster-context, superuser-only GUC so deployments can choose a different provider schema before creating the extension.

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

The compatibility rule should be:

- If the installed extension already owns `duroxide`, use `duroxide`.
- If the installed extension already owns the configured/new schema, use that schema.
- Do not rename, copy, drop, or migrate provider state automatically.
- A fresh `CREATE EXTENSION pg_durable` under the new SQL should create and use `df-duroxide` by default.

## Proposed GUC

Add a new GUC:

```text
pg_durable.duroxide_schema = 'df-duroxide'
```

Recommended properties:

- Context: `Postmaster`
- Flags: `SUPERUSER_ONLY`
- Default: `df-duroxide`
- Validated as a PostgreSQL identifier/name suitable for a schema name
- Documented as install-time configuration, not a runtime migration switch

The setting should mean: "which provider schema should new extension installs create and which schema should the background worker expect when there is no legacy extension-owned `duroxide` schema."

## Desired Behavior

### Fresh install, default GUC

1. `pg_durable.duroxide_schema` is unset or set to `df-duroxide`.
2. `CREATE EXTENSION pg_durable` creates an extension-owned schema named `df-duroxide`.
3. The background worker verifies `df-duroxide` is extension-owned.
4. The worker runs duroxide-pg migrations in `df-duroxide`.
5. Backend sessions use `df-duroxide._worker_ready` and a provider configured with `schema_name = "df-duroxide"`.

### Fresh install, custom GUC

1. Admin sets `pg_durable.duroxide_schema = 'custom_schema'` in `postgresql.conf` and restarts PostgreSQL.
2. `CREATE EXTENSION pg_durable` creates an extension-owned schema named `custom_schema`.
3. The worker and backend sessions use `custom_schema`.

### Existing install using `duroxide`, new binary deployed, GUC unset/default

1. The database already has `pg_durable` installed and owns schema `duroxide`.
2. The new binary default is `df-duroxide`.
3. The worker detects the extension-owned `duroxide` schema and keeps using it.
4. No provider state is moved.
5. Existing instances continue to run and monitoring APIs continue to work.

This is the most important backward-compatibility path.

### Existing install using `duroxide`, admin changes GUC to `df-duroxide` or custom value without dropping extension

Current requested behavior: do not delete or migrate the old schema. The extension still has the schema it already owns, while the worker is configured to wait for the new schema name to exist and be extension-owned. Functions will not make progress until the extension is dropped and recreated with the new setting.

This mirrors the existing operational hazard for `pg_durable.database`: changing the GUC after extension creation can leave the worker watching a database/schema state that does not match the existing extension installation.

This requirement has one tension with the previous compatibility path: if the new binary always falls back to extension-owned `duroxide`, then changing the GUC would not intentionally stall the worker. We need a crisp rule to distinguish "legacy default compatibility" from "admin explicitly changed the schema setting." See Open Questions.

### Drop and recreate after changing GUC

1. Admin sets `pg_durable.duroxide_schema` to the desired schema and restarts.
2. Admin runs `DROP EXTENSION pg_durable CASCADE`.
3. The extension-owned provider schema and provider state are dropped by PostgreSQL cascade.
4. Admin runs `CREATE EXTENSION pg_durable`.
5. The new extension creates the configured schema and starts with fresh provider state.

This is a destructive reset of durable engine state, not a migration.

### Upgrade script path

`ALTER EXTENSION pg_durable UPDATE` should not rename `duroxide` or create `df-duroxide` for existing installations. The upgrade path should preserve existing provider state and should leave schema selection to runtime detection/configuration.

Scenario A schema-equivalence tests must account for the fact that provider schema state is intentionally not compared as part of `df` schema snapshots. Scenario B1 is the critical test: new `.so` against an older compatible schema must still use `duroxide`.

## Open Questions

### How do we detect an explicit schema GUC change?

Postmaster GUC access normally gives the effective value, not whether it came from the compiled default or from a config file. If the compiled default changes from `duroxide` to `df-duroxide`, an existing installation with no explicit setting will also observe `df-duroxide`.

That means these two cases look identical unless we add another signal:

1. Existing install, admin did nothing, new binary default is now `df-duroxide`.
2. Existing install, admin explicitly set `pg_durable.duroxide_schema = 'df-duroxide'` without dropping/recreating.

The requested behavior wants case 1 to keep using `duroxide`, but case 2 to wait for `df-duroxide`. We need a way to tell them apart.

Possible approaches:

- Use PostgreSQL GUC source inspection if pgrx exposes enough information or if we can safely call the relevant PostgreSQL APIs. Treat `PGC_S_DEFAULT` as compatibility mode and non-default config sources as explicit admin intent.
- Avoid trying to detect explicitness. Rule: an existing extension-owned `duroxide` schema always wins. This is simpler and safer for upgrades, but changing the GUC alone would not stall/move an old install.
- Persist the selected provider schema in `df` metadata during `CREATE EXTENSION`. This would make runtime behavior explicit after install, but it requires new DDL and does not help already-shipped installs unless absence of metadata means legacy `duroxide`.
- Create both a GUC and a SQL helper that records the selected schema at install time. This is probably overkill unless PostgreSQL GUC source inspection is not viable.

Recommendation: prefer explicit metadata if we want deterministic behavior independent of GUC-source quirks. Add a small `df._provider_config` or similar table with `duroxide_schema TEXT NOT NULL`, populated by install SQL from the GUC value. For old installs without the table/row, fallback to extension-owned `duroxide`.

### Can `CREATE SCHEMA` use a GUC-derived dynamic name in extension SQL?

Static extension SQL currently uses literal `CREATE SCHEMA duroxide;`. A configurable schema name probably requires a `DO` block that reads `current_setting('pg_durable.duroxide_schema')`, validates it, executes `CREATE SCHEMA %I`, and then runs `ALTER EXTENSION pg_durable ADD SCHEMA %I` if dynamic schema creation is not automatically registered as an extension member.

This needs a prototype. The cheap check is to package/install locally and inspect `pg_depend` for the dynamically created schema.

### Is `df-duroxide` an acceptable PostgreSQL schema name?

Yes if quoted: `"df-duroxide"`. It is not a bare identifier because of the hyphen. All SQL that references it must use identifier quoting. Rust/provider config can pass the raw name, assuming duroxide-pg quotes identifiers correctly internally. pg_durable's own dynamic SQL must use `quote_ident()` or equivalent.

This also affects test scripts and readiness probes: direct SQL must refer to `"df-duroxide"._worker_ready`, or better use formatted SQL with `%I`.

### Should we choose `df_duroxide` instead?

`df-duroxide` clearly signals an internal implementation schema and avoids ordinary bare-identifier collisions, but it increases quoting requirements and test churn. `df_duroxide` is simpler operationally. The current requested default is `df-duroxide`; keep it unless we decide the quoting burden is not worth it.

## Implementation Plan

### Phase 1: Schema-name abstraction

- Replace the hardcoded `DUROXIDE_SCHEMA` constant with functions that return the selected provider schema.
- Add helpers for quoted identifier rendering in SQL snippets that must mention the schema directly.
- Update `backend_provider_config()` and `worker_provider_config()` to use the selected schema.
- Update debug/status messages to display the selected schema.

### Phase 2: Install-time schema creation

- Add `pg_durable.duroxide_schema` GUC in `src/lib.rs`.
- Replace literal `CREATE SCHEMA duroxide;` with dynamic schema creation using the configured name.
- Ensure the created schema is an extension member.
- Preserve the no-adoption rule: if the target schema already exists, `CREATE EXTENSION` must fail.
- Decide whether to persist the chosen schema in `df` metadata.

### Phase 3: Runtime schema selection

Recommended selection algorithm if metadata is added:

1. If `df._provider_config.duroxide_schema` exists and has a value, use it.
2. Else if the extension owns `duroxide`, use `duroxide` for legacy compatibility.
3. Else use the current GUC value.

If metadata is not added, the selection algorithm must explicitly resolve the open question about GUC explicitness.

### Phase 4: Worker ownership and migration flow

- Generalize `check_duroxide_schema_owned()` to accept the selected schema name.
- Generalize `has_extension_owned_duroxide_objects()` and `release_extension_owned_duroxide_objects()` to filter on the selected schema.
- Generalize `write_worker_ready()` to create/grant/upsert in the selected schema.
- Ensure all dynamic SQL uses identifier quoting.
- Keep `MigrationPolicy::ApplyAll` in the worker and `VerifyOnly` in backend sessions.

### Phase 5: Backend readiness checks

- Generalize `is_worker_ready()` in `src/client.rs` to check the selected schema's `_worker_ready` table.
- Avoid directly querying a possibly missing table; retain the current catalog-existence pre-check.
- Ensure non-superuser backend sessions can read readiness state in quoted/custom schemas.

### Phase 6: Tests and scripts

Add or update checks for:

- Fresh install uses `df-duroxide` by default.
- Fresh install with custom `pg_durable.duroxide_schema` uses the custom schema.
- Pre-existing schema with the configured name blocks `CREATE EXTENSION`.
- New binary against old schema uses existing `duroxide` and can run a workflow.
- Changing the GUC without drop/recreate has the decided behavior and emits clear logs/errors.
- Drop/recreate after changing the GUC creates the new schema and no old provider state remains unless separately preserved by the admin outside the extension lifecycle.

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

Document clearly that changing `pg_durable.duroxide_schema` does not migrate existing durable state.

## Validation Strategy

Minimum validation after implementation:

```bash
cargo fmt -p pg_durable -- --check
cargo build --features pg17
./scripts/test-e2e-local.sh 00_setup_playground
./scripts/test-upgrade.sh --verbose
```

If time is short, prioritize a targeted E2E or SQL smoke test that verifies a default fresh install creates `df-duroxide`, and the upgrade B1 path still works with an existing `duroxide` schema.

## Issue Update Draft

Proposed summary to add to the GitHub issue:

> We should make the duroxide provider schema configurable for new installs, with a new default of `df-duroxide`, but preserve existing installations that already have extension-owned `duroxide` provider state. The implementation needs to avoid automatic rename/copy/drop of provider state. Fresh installs should create the configured schema as an extension-owned object and the BGW should only run `ApplyAll` after verifying extension ownership. Existing installs should continue using their current extension-owned `duroxide` schema unless the admin intentionally drops and recreates the extension under a new setting. The main design question is how to distinguish an unchanged legacy install from an admin explicitly changing the new GUC without drop/recreate; options are GUC-source inspection, always letting legacy `duroxide` win, or persisting the selected provider schema in `df` metadata at install time.

## Current Recommendation

Do not implement the schema rename as a simple constant change. The safe implementation needs a selected-schema abstraction and a persisted install-time provider schema record, or an equally precise rule for GUC explicitness.

The metadata approach is the most deterministic:

- New installs record and use the configured schema.
- Old installs without metadata keep using `duroxide`.
- Changing the GUC after install does not mutate the recorded schema and therefore does not migrate state.
- Drop/recreate is the supported way to adopt a different provider schema.

This differs slightly from the requested "worker waits for the new schema if GUC changes" behavior, but it avoids ambiguity and matches PostgreSQL extension practice: install-time state should define which schema belongs to that extension instance.