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
| In-flight work | Orchestrations started before `.so` swap complete after swap (except across an activity-input change — see #129) |

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
| In-flight work | Work started before `ALTER EXTENSION UPDATE` can still complete afterward (except across an activity-input change — see #129) |
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

- `sql/pg_durable--0.1.1.sql` — first install SQL for the current major version
- `sql/pg_durable--0.2.2.sql` — install SQL fixture at the start of the current provider compatibility line (`PROVIDER_COMPAT_START_VERSION`). The harness reconstructs a target version from the **highest install fixture at or below it** (see `base_fixture_for_version` in `scripts/test-upgrade.sh`), then chains `ALTER EXTENSION UPDATE`. A fixture is required at the provider-compat-start boundary so reconstruction never has to chain across it — the pre-0.2.2 install SQL embeds a hand-written `duroxide` schema that is incompatible with the duroxide-pg provider's migration tracking (`_duroxide_migrations`).
- `sql/pg_durable--0.1.1--0.2.0.sql` — upgrade script (initially empty, populated by subsequent PRs)
- `scripts/test-upgrade.sh` — runs Scenarios A, B1, and B2. The `PROVIDER_COMPAT_START_VERSION` environment variable/default controls the first version in the current provider compatibility line. Versions before that boundary are excluded from B1 and cannot be used as A/B2 upgrade sources.
- CI step in `.github/workflows/ci.yml`

### Per-version checklist

Each PR that changes the extension schema or modifies SQL queries in Rust code should:

1. Add the necessary DDL to the upgrade script (`sql/pg_durable--<prev>--<current>.sql`)
2. Ensure the `.so` is backward compatible with **all** previous schemas in the same provider compatibility line (Scenario B1)
3. Keep all new DDL — in the Rust install SQL *and* in any new upgrade script — schema-qualified so it passes the pgspot SQL security gate (`scripts/pgspot-gate.sh`): qualify operators as `OPERATOR(pg_catalog.<op>)`, functions/types/objects by schema (e.g. `pg_catalog.now()`), and qualify references inside anonymous `DO` blocks (they run under the session search_path). New upgrade scripts are gated automatically.
4. Add version-specific notes to this document under "Version-Specific Changes" below
5. Pass upgrade and pgspot tests in CI

### Future work

- **pg_regress-style upgrade test**: pg_cron and similar extensions use `pg_regress` with expected-output diffs to validate upgrade scripts. This is simpler than our Scenario A schema snapshot approach but less thorough — it doesn't cover B1 (binary backward compat) or B2 (data survival). Consider adopting as a complementary check if `pg_regress` integration becomes worthwhile.

### Preparing for the next version

**Minor release** (e.g. 0.2.0 → 0.3.0):
1. Create empty `sql/pg_durable--<N>--<N+1>.sql` upgrade script
2. Bump `Cargo.toml` version to `<N+1>`
3. If this release starts a new provider compatibility line, update the `PROVIDER_COMPAT_START_VERSION` default in `scripts/test-upgrade.sh`, check in an install SQL fixture (`sql/pg_durable--<start>.sql`) at that boundary so reconstruction never chains across it, and document the boundary under "Version-Specific Changes". Downstream forks can instead override `PROVIDER_COMPAT_START_VERSION` in CI to keep the script shared. When you advance `PROVIDER_COMPAT_START_VERSION`, also audit for binary-compatibility shims annotated `#[pg_extern(sql = false)]` (e.g. `df.debug_connection()` in `src/dsl.rs`, retained for #110) and delete any whose C symbol is no longer referenced by a supported schema in the new line.

If this is the first minor after a new major (e.g. 1.0.0 → 1.1.0), also:

4. Check in `sql/pg_durable--<major>.sql` as the first install SQL fixture for the new major (e.g. copy the generated `pg_durable--1.0.0.sql` from the extension directory)
5. Optionally delete the previous major's install SQL fixture and upgrade scripts — they are no longer needed by any of A, B1, or B2

No additional fixture is needed for subsequent minors — intermediate versions are reconstructed by chaining `ALTER EXTENSION UPDATE` from the first version's install SQL.

**Major release** (e.g. 0.x → 1.0.0):
1. Create empty `sql/pg_durable--<N>--<1.0.0>.sql` upgrade script
2. Bump `Cargo.toml` version to `<1.0.0>`

`cargo pgrx package` generates the new major's install SQL. The previous major's install SQL and upgrade scripts are still needed for the A/B2 upgrade chain when the provider line continues across the major bump. B1 will be a no-op if there are no previous compatible versions within the new major, or if `PROVIDER_COMPAT_START_VERSION` marks the new major as the start of a new provider line.

### Upgrade scripts and the pgspot gate

The pgspot gate scans every upgrade script matching `*--*--*.sql`, except a small
hardcoded list of pre-pgspot legacy scripts in `scripts/pgspot-gate.sh` (authored
before the install DDL was schema-qualified, and immutable now that they're
released). Every new upgrade script is gated and must pass — keep its DDL
schema-qualified (see step 3 above). Scripts written after qualification pass the
gate, so they never need to be added to the exclude list.

---

## Version-Specific Changes

Each schema-changing PR should add a section here documenting what changed,
what the upgrade script handles, and any backward compatibility considerations.

### v0.2.4 → v0.2.5

#### Add `df.http_multipart()` for multipart/form-data uploads
- **DDL change (df schema):** Adds a new node type `HTTP_MULTIPART` and a new `#[pg_extern(schema = "df")]` function `df.http_multipart(text, text, jsonb, jsonb, integer)`. The upgrade script `sql/pg_durable--0.2.4--0.2.5.sql` hand-writes the `CREATE FUNCTION ... LANGUAGE c AS 'MODULE_PATHNAME', 'http_multipart_wrapper'` (pgrx emits it for fresh installs from `src/dsl.rs`), re-adds the `nodes_node_type_chk` / `nodes_structure_chk` constraints and `df.ensure_durofut()` validator with `HTTP_MULTIPART` admitted, and re-emits `df.grant_usage()` / `df.revoke_usage()` so they GRANT/REVOKE `df.http_multipart()` alongside `df.http()`. The signature `df.grant_usage(text, boolean, boolean)` is unchanged.
- **Grant gating:** `df.http_multipart()` rides on the existing `include_http => true` flag (HTTP egress is treated as one privilege). `REVOKE EXECUTE ... FROM PUBLIC` is added for `df.http_multipart()` at install/upgrade time, matching `df.http()`.
- **Scenario B1 considerations:** The new `.so` adds the `http_multipart_wrapper` C symbol and a new activity `execute_multipart`. Pre-0.2.5 schemas have no catalog entry for `df.http_multipart` and no `HTTP_MULTIPART` rows, so a binary-only swap (no `ALTER EXTENSION UPDATE`) changes nothing for existing workflows — the new function and node type are simply absent until the customer upgrades. No existing symbol is removed or renamed.

### v0.2.3 → v0.2.4

#### Simplify `df.grant_usage()` — drop the explicit function allowlist
- **DDL change (df schema):** `df.grant_usage()` no longer loops over a hard-coded `func_sigs` array issuing `GRANT EXECUTE` per function. Fresh installs (`src/lib.rs`) and the upgrade script (`sql/pg_durable--0.2.3--0.2.4.sql`) both `CREATE OR REPLACE` the function with a body that grants `USAGE ON SCHEMA df` plus the table privileges, and conditionally grants `df.http()` / the admin helpers. The signature `df.grant_usage(text, boolean, boolean)` is unchanged.
- **DDL change (df schema):** `df.revoke_usage()` is made symmetric with the new `grant_usage()`. It no longer loops over every `df.*` function in `pg_proc` issuing `REVOKE EXECUTE` (which, post-simplification, only produced "no privileges could be revoked" warnings since ordinary functions are never granted per-function EXECUTE). The new body revokes only what `grant_usage()` grants: schema `USAGE`, EXECUTE on the sensitive functions (`df.http`, `df.grant_usage`, `df.revoke_usage`), and the table privileges. The signature `df.revoke_usage(text)` is unchanged.
- **Rationale:** The ordinary `df.*` functions retain PostgreSQL's default PUBLIC `EXECUTE`, so schema `USAGE` is the real access gate; the per-function grants/revokes were redundant. The sensitive functions have PUBLIC `EXECUTE` revoked at install time and were never in the allowlist, so their protection is unchanged.
- **Behavioral note:** A newly added `df.*` function is now callable by any role with schema `USAGE` by default. To keep a future function private, `REVOKE EXECUTE ... FROM PUBLIC` at install time and grant it explicitly in `df.grant_usage()`.
- **Legacy cleanup caveat:** A role that was granted under the *old* `grant_usage()` (explicit per-function EXECUTE) and is later revoked under the new `revoke_usage()` may retain inert EXECUTE entries on ordinary functions. These are harmless — revoking schema `USAGE` fully locks the role out — and clear on the next drop/regrant cycle.
- **Scenario A considerations:** Signatures are identical on the fresh-install and upgrade paths (only the bodies differ), so the function-signature equivalence contract passes.
- **Scenario B1/B2 considerations:** No schema/data migration and no new objects. The replaced bodies work against the existing schema and change no privileges already granted.

#### Rename `df.wait_for_completion()` to `df.await_instance()`
- **DDL change (df schema):** Adds `df.await_instance(text, integer)` as the canonical C binding for the helper formerly exposed as `df.wait_for_completion(text, integer)`. The old SQL function remains present and the new `.so` continues exporting `wait_for_completion_wrapper` as a shim, so existing customer scripts keep working.
- **Grant behavior:** No explicit grant migration is required. PostgreSQL grants `EXECUTE` on newly created functions to `PUBLIC` by default, and `df.await_instance` is not a sensitive helper whose default PUBLIC grant is revoked.
- **Scenario A considerations:** Fresh installs and upgraded schemas must both expose `df.await_instance(text, integer)` and `df.wait_for_completion(text, integer)`.
- **Scenario B1 considerations:** The new `.so` remains compatible with v0.2.3 schemas that have not run `ALTER EXTENSION UPDATE`: existing catalog entries still bind `df.wait_for_completion` to `wait_for_completion_wrapper`, which is retained as a Rust shim to `df.await_instance`.
- **Scenario B2 considerations:** No data migration. Existing instances are unaffected; the upgrade only adds a SQL function binding.

#### #110 Remove df.debug_connection() (reclassified non-security cleanup)
- **DDL change (df schema):** The upgrade script `sql/pg_durable--0.2.3--0.2.4.sql` runs `DROP FUNCTION IF EXISTS df.debug_connection();`. Fresh v0.2.4 installs never create the function: its `#[pg_extern]` in `src/dsl.rs` is annotated `#[pg_extern(sql = false)]`, so pgrx emits no `CREATE FUNCTION` for it (the generated schema records `-- Skipped due to #[pgrx(sql = false)]`). The function returned the worker connection string (no credential) and is dropped as surface-reduction, because the worker role is already exposed to any role via native PostgreSQL channels — the world-readable `pg_durable.worker_role` GUC and `pg_stat_activity.usename` (see security-review item I-6); the remaining fields (database, host/port, schema) are connection-topology metadata, not secrets (the host comes from `PGHOST`, defaulting to loopback). Reclassified from security to cleanup; see issue #110.
- **Interaction with the `df.grant_usage()` simplification:** Earlier in this release `df.grant_usage()` carried `'df.debug_connection()'` in its explicit per-function allowlist (`func_sigs`), so dropping the function would have required editing that allowlist. The grant_usage simplification above (#242) removed the allowlist entirely in this same release, so the upgrade no longer needs any `grant_usage` change to account for the removed function — it simply drops `df.debug_connection()`.
- **Scenario A considerations:** `df.debug_connection()` is absent on both the fresh-install and upgrade paths after this release, keeping the `df` schema shapes equivalent.
- **Scenario B1 considerations (symbol retention):** Removing `df.debug_connection()` from the SQL surface required care to preserve binary backward compatibility. Pre-0.2.4 schemas (0.2.2, 0.2.3) define the function as `AS 'MODULE_PATHNAME','debug_connection_wrapper'`, and PostgreSQL validates that C symbol at `CREATE FUNCTION` time (`check_function_bodies = on` by default). Fully deleting the `#[pg_extern]` would drop the `debug_connection_wrapper` symbol from the `.so`, so the new binary could no longer instantiate any previously shipped schema — failing Scenario B1. The fix is `#[pg_extern(sql = false)]`: pgrx still compiles the C wrapper symbol into the binary (verified with `nm`) but emits no SQL, so old schemas keep resolving the symbol while fresh installs omit the function. The retained Rust body still returns the same non-secret connection string, so a binary-only swap (no `ALTER EXTENSION UPDATE`) leaves any pre-existing `df.debug_connection()` working until the customer upgrades. The shim is a temporary binary-compat detail — remove it once `PROVIDER_COMPAT_START_VERSION` advances past 0.2.3 and no supported schema references the symbol.
- **Scenario B2 considerations:** No data migration. Existing instances, nodes, and vars are untouched. After `ALTER EXTENSION UPDATE`, `df.debug_connection()` no longer exists; the simplified `df.grant_usage()` never references it.
- **Dependent-object note:** The upgrade runs `DROP FUNCTION IF EXISTS df.debug_connection()` with PostgreSQL's default `RESTRICT` behavior. If a customer created their own object that depends on the function (e.g. a view or SQL function that calls it), `ALTER EXTENSION UPDATE` aborts with a dependency error and the customer must drop or repoint that object first. This is intentional for a removed debug helper — the script deliberately does not `CASCADE`, to avoid silently dropping customer-owned objects. The fresh-install (`tests/e2e/sql/18_delegated_grants.sql`) and upgrade (`scripts/test-upgrade.sh` B2 grant test) suites assert the function is absent and that `df.grant_usage()` still works after the drop.

#### #129 Promote df.nodes to a composite primary key (instance_id, id)
- **DDL change (df schema):** `df.nodes` previously had a single-column `PRIMARY KEY (id)` plus a separate composite `UNIQUE (instance_id, id)` (`nodes_instance_node_key`). The single-column key forced the random 8-hex node ID to be globally unique, so it was the sole cross-instance collision guard. Node IDs only need to be unique per instance, so the composite key is promoted to be the primary key and the global single-column key is dropped. Fresh installs (`src/lib.rs`) declare `id`/`instance_id` as `NOT NULL` and create `nodes_pkey PRIMARY KEY (instance_id, id)` directly; the upgrade script (`sql/pg_durable--0.2.3--0.2.4.sql`) restructures the existing keys in place. The three same-instance foreign keys (`nodes_left_node_same_instance_fkey`, `nodes_right_node_same_instance_fkey`, `instances_root_node_same_instance_fkey`) reference the composite key, so the upgrade drops them first, swaps the keys, then recreates them with their original `DEFERRABLE INITIALLY DEFERRED NOT VALID` definition. `nodes_instance_identity_fkey` references `df.instances`, not `df.nodes`, and is left untouched. IDs remain `VARCHAR(8)` HEX.
- **Companion runtime change (#129):** `df.start()` now reserves the instance ID by attempting the insert itself — `INSERT INTO df.instances ... ON CONFLICT (id) DO NOTHING RETURNING id` — and re-rolling the random 8-hex ID when zero rows come back (a collision); there is no separate `SELECT EXISTS` pre-check. Because `ON CONFLICT` arbitration runs against the global `id` index *below* row-level security, this also re-rolls on collisions with another role's instance that the caller cannot `SELECT`. Node inserts use the same pattern against the composite key — `INSERT INTO df.nodes ... ON CONFLICT (instance_id, id) DO NOTHING RETURNING id` — re-rolling on a per-instance collision. `df.start()` pre-generates the root node's ID and reserves the instance with `root_node` set to that value; `insert_nodes` then inserts the root node with the same forced ID. The same-instance FK on `root_node` is `DEFERRABLE INITIALLY DEFERRED`, so it is checked only at commit, by which point the referenced root node row exists — no post-insert `UPDATE` is needed (and `df.grant_usage()` deliberately grants `UPDATE (status, updated_at)` but not `UPDATE (root_node)` on `df.instances`, so an update path would fail for ordinary df roles). The `update-node-status` activity and `df.result()` now scope their `df.nodes` lookups by `instance_id` in addition to `id`, and the activity asserts the scoped `UPDATE` affects exactly one row. `instance_id` is a **required** field of the activity input — node IDs are unique only per instance, so updating by node ID alone could silently write to a *different* instance's node. There is deliberately no node-ID-only fallback.
- **Design note — collision handling for both ID spaces (#129):** Both IDs stay 8-hex `VARCHAR(8)` (the requested minimal change) and re-roll on conflict via `INSERT ... ON CONFLICT DO NOTHING RETURNING id`; the mechanism is symmetric and only the conflict target differs. `df.instances.id` is a *global* identifier with no natural scoping column, so its reserve arbitrates on the single-column primary key (`id`). `df.nodes.id` is always used together with its owning `instance_id`, so promoting the pre-existing `(instance_id, id)` UNIQUE to the primary key lets node inserts arbitrate per instance — the random node ID never has to be globally unique. Using `ON CONFLICT DO NOTHING` rather than a `SELECT EXISTS` pre-check closes a TOCTOU window and, for instances, an RLS blind spot: the pre-check only saw the caller's own rows, whereas `ON CONFLICT` detects a clash with any role's row at the index level. The retry bound (`MAX_ID_ATTEMPTS`) surfaces a hard error on exhaustion rather than returning an unverified ID.
- **In-flight orchestration compatibility (#129 — breaking for in-flight work):** Adding `instance_id` to the `update-node-status` activity input changes the input string that duroxide records in orchestration history. duroxide validates activity inputs by exact equality during replay, so any orchestration that was **in flight across the binary upgrade** (it recorded the old `{node_id, status}` input under 0.2.3) fails deterministic replay under the new `.so` and cannot complete. This is an intentional break of the general "in-flight work completes after the swap" expectation (the Scenario B1 and B2 "In-flight work" rows above) **for this release**, and follows the same drain-or-recreate precedent as the v0.1.0 → v0.1.1 execution-model change (Scenario B2, below): **operators must drain in-flight instances to a terminal state before deploying 0.2.4**, or cancel and recreate any that cannot drain. Instances that completed before the upgrade are terminal and unaffected; instances started after the upgrade carry `instance_id` from their first node update and replay normally.
- **Scenario A considerations:** Fresh-install and upgraded schemas must both end with exactly one identity constraint on `df.nodes`: `nodes_pkey PRIMARY KEY (instance_id, id)` (constraint key order `instance_id, id`), its matching unique index `nodes_pkey ON df.nodes USING btree (instance_id, id)`, and no surviving `nodes_instance_node_key` constraint or index. The recreated foreign keys keep identical names and referencing columns, so the constraint/index snapshot diff is empty.
- **Scenario B1 considerations:** The schema change is to table constraints only; the new `.so` issues the same column lists against `df.nodes`/`df.instances`, now with `ON CONFLICT ... DO NOTHING RETURNING id`. The instance reserve arbitrates on `id` (the primary key in both old and new schemas) and the node insert arbitrates on `(instance_id, id)` — an index that exists in both the pre-0.2.4 schema (the `nodes_instance_node_key` composite UNIQUE) and the new schema (the composite primary key) — so both statements stay valid against a schema that has not run `ALTER EXTENSION UPDATE`. The pre-generated-`root_id` reserve is also old-schema-safe: `instances_root_node_same_instance_fkey` is `DEFERRABLE INITIALLY DEFERRED` in every shipped schema, so `root_node` is not checked until commit, by which point the forced-ID root node row has been inserted within the same transaction. No `UPDATE df.instances` is issued, so the change relies only on the `INSERT (..., root_node, ...)` privilege every shipped `df.grant_usage()` already grants, not on any `UPDATE (root_node)` grant. One benign residual exists against the *old* schema only: a node ID that is globally duplicated but per-instance-unique would clash with the surviving single-column `nodes_pkey (id)`, which `ON CONFLICT (instance_id, id)` does not arbitrate, so it raises just as it did before this change — astronomically rare, strictly no worse than prior behavior, and eliminated once `ALTER EXTENSION UPDATE` swaps in the composite primary key. This covers **schema** compatibility only — the SQL stays valid against the old table shape. The separate in-flight *replay* break introduced by the changed activity-input shape is documented under "In-flight orchestration compatibility" above and requires draining before upgrade.
- **Scenario B2 considerations:** `ADD PRIMARY KEY (instance_id, id)` sets `NOT NULL` on both columns and builds a unique index over existing rows. `id` was already the old primary key (implicitly `NOT NULL`). `instance_id` carries a `nodes_instance_id_present_chk CHECK (instance_id IS NOT NULL)` constraint, but it was added `NOT VALID`, so it only guarantees rows written on 0.2.2+; in the unlikely event a database still holds pre-0.2.2 node rows with a NULL `instance_id`, the `ADD PRIMARY KEY` (and the explicit `ALTER COLUMN instance_id SET NOT NULL` that precedes it) will abort and the operator must backfill or remove those rows before retrying the upgrade. On an empty database the restructure is metadata-only; on a populated one PostgreSQL rebuilds the `df.nodes` primary-key index in place. Because `ADD PRIMARY KEY` / `ALTER COLUMN ... SET NOT NULL` take an `ACCESS EXCLUSIVE` lock on `df.nodes` and rebuild the index, on a large `df.nodes` the upgrade blocks concurrent access for a period that scales with the table's size; run `ALTER EXTENSION UPDATE` inside a maintenance window and consider `SET lock_timeout` for the session so the migration fails fast instead of queuing behind (or stalling in front of) long-running transactions. Combined with the in-flight replay break noted above, the recommended upgrade sequence is: stop new `df.start()` calls, drain or cancel in-flight instances, then run the upgrade.

#### Indexes on df.instances for ordered/paginated listing (issues #167/#87/#146)
- **DDL change (df schema):** `df.list_instances()` lists rows newest-first (`ORDER BY created_at DESC`), optionally filtered by status. The pre-0.2.4 `idx_instances_status(status)` covered only the status equality, so a status-filtered listing still required a sort and an unfiltered listing had no supporting index. Fresh installs (`src/lib.rs`) now create `idx_instances_status(status, created_at DESC, id)`, a new `idx_instances_created_at(created_at DESC, id)`, and a partial `idx_instances_label(label, created_at DESC, id) WHERE label IS NOT NULL` for the label-filtered path (issue #87). The upgrade script `sql/pg_durable--0.2.3--0.2.4.sql` drops any existing copies (`DROP INDEX IF EXISTS`) then recreates all three indexes with the same definitions. The trailing `id` is the keyset tiebreaker for `df.list_instances` (`ORDER BY created_at DESC, id ASC`). At the time these indexes were added `df.list_instances()` did not yet order by `id`; the **label filter, keyset pagination, timestamps** change below realizes that order, and these indexes then serve both the sort and the `after_cursor` range predicate as an index scan.
- **Design note (RLS):** `df.instances` has a row-level-security policy (`instances_user_isolation`) filtering `submitted_by = current_user::regrole`, so a per-user index leading with `submitted_by` would be more selective for an individual session. The `created_at`-leading design is intentional: it is optimal for the admin / external-client global-listing path (#146) that reads across submitters, and it still removes the per-query sort for the common case. A `submitted_by`-leading refinement can be revisited if profiling shows the per-user path dominates.
- **Scenario A considerations:** The upgrade script recreates the indexes with column lists, partial predicate, and `DESC`/tiebreaker ordering identical to the fresh-install DDL, so `pg_get_indexdef()` for `idx_instances_status`, `idx_instances_created_at`, and `idx_instances_label` is byte-identical on both paths and the Scenario A snapshot matches.
- **Scenario B1 considerations:** The new `.so` works against all previous schemas. The `df.list_instances()` queries (`ORDER BY created_at DESC LIMIT`, optionally `WHERE status = $1`) reference only the `created_at`/`status` columns, which exist in every shipped `df.instances` schema; against a schema that has not run `ALTER EXTENSION UPDATE` the queries stay valid and correct — they simply fall back to a sort without the new index until the upgrade is applied. This is a performance-only change with no correctness impact.
- **Scenario B2 considerations:** No data migration. `DROP INDEX` / `CREATE INDEX` rebuild access-path metadata only; row data is untouched. The `CREATE INDEX` statements take a `SHARE` lock on `df.instances` while they build, so on a large `df.instances` run `ALTER EXTENSION UPDATE` in a maintenance window for the same reasons noted above.

#### `df.list_instances()` — label filter, keyset pagination, timestamps (issues #87/#146)
- **DDL change (df schema):** This adds a **new overload** of `df.list_instances` rather than changing the existing one. The prior two-argument function (`df.list_instances(status_filter text, limit_count integer)` → 6 columns) is left in place **unchanged**. A new four-argument overload `df.list_instances(status_filter text, limit_count int, label_filter text, after_cursor text DEFAULT NULL)` is added, returning three extra trailing columns (`created_at`, `completed_at`, `next_cursor`) and backed by a distinct symbol (`list_instances_paged_wrapper`). Only `after_cursor` defaults, giving the overload a minimum arity of 3; the basic function matches calls of arity 0–2 and the paginated one arity 3–4, so the two never overlap and PostgreSQL never reports "function is not unique". The paginated overload orders rows `created_at DESC, id ASC`, served as an index scan by the `(created_at DESC, id)` indexes added in the previous subsection. The upgrade script `sql/pg_durable--0.2.3--0.2.4.sql` adds only the new overload (no `DROP FUNCTION`).
- **Why an overload instead of changing the function (Scenario B1):** Changing the existing two-argument/6-column function in place would break Scenario B1. A customer running 0.2.2/0.2.3 who loads the new `.so` but never runs `ALTER EXTENSION UPDATE` still has the old 6-column SQL declaration bound to the `list_instances_wrapper` symbol. If the new `.so` implemented that symbol with a 9-column shape, the returned tuple would not match the catalog declaration and calls would error. Keeping the old function frozen (same 6-column shape, same `list_instances_wrapper` symbol) preserves that contract; the new capability ships as a separate function/symbol. This mirrors the repo's `wait_for_completion`→`await_instance` precedent of keeping both functions rather than mutating one.
- **Design note (cursor):** `after_cursor` is an opaque keyset token. Each page carries `next_cursor` (identical on every row of the page, `NULL` on the final page); the client passes it back as `after_cursor` to fetch the next page. The cursor encodes `(created_at, id)` of the last row, so pagination is deterministic and seek-based (no `OFFSET`). `next_cursor` is computed over `df.instances` (RLS-filtered) independently of the per-row execution-metadata lookup, so it advances correctly even when a row is transiently skipped; a malformed cursor raises an error rather than silently restarting.
- **Scenario A considerations:** The `CREATE FUNCTION df."list_instances"(...)` block in the upgrade script is the pgrx-generated fresh-install DDL for the new overload (`src/monitoring.rs`) copied verbatim — same argument list, defaults, and `RETURNS TABLE` column list/types. The old two-argument function is unchanged from the 0.2.3 base install. So on both paths the catalog ends with exactly the same two `df.list_instances` overloads, and the Scenario A snapshot matches a fresh 0.2.4 install.
- **Scenario B1 considerations:** Both overloads of the new `.so`'s `list_instances` read only columns that exist in every shipped `df.instances` schema (`id`, `label`, `status`, `created_at`, `completed_at`), so they run correctly against a pre-0.2.4 schema that has not run `ALTER EXTENSION UPDATE` — the paginated path simply falls back to a sort without the `(created_at DESC, id)` index. Crucially, the old catalog still binds existing 0/1/2-argument callers to `list_instances_wrapper`, which the new `.so` still exports with the original 6-column shape, so those calls keep working unchanged.
- **Scenario B2 considerations:** No data migration. The `CREATE FUNCTION` adds catalog metadata only; `df.instances` rows are untouched. The new `created_at`/`completed_at` result columns are read from columns that already exist and are already populated on every prior install.
- **Dependent-object note:** Because the upgrade only adds a function (no `DROP FUNCTION`), no customer-owned object that depends on the existing two-argument `df.list_instances` is affected — there is nothing to drop or repoint.

#### `pg_durable.list_instances_max_limit` GUC — page-size cap is now a loud error (issue #146)
- **DDL change:** None. The cap is enforced entirely in the `.so`: a new `pg_durable.list_instances_max_limit` GUC (`SUSET` context, default `1000`, range `1`–`1000000`) is registered in `_PG_init` (`src/lib.rs`) and read on the `df.list_instances()` query path (`src/monitoring.rs`). There are no SQL function, table, or index changes, so this change adds no upgrade-script DDL and has no Scenario A snapshot impact.
- **Behavior change:** Both `df.list_instances()` overloads previously truncated `limit_count` silently to a fixed 10000. They now raise an error when `limit_count` exceeds the GUC (default `1000`), so an over-cap request fails fast instead of returning a silently short page. This is a runtime behavior change to a function that shipped in 0.2.2/0.2.3; it is recorded in `CHANGELOG.md` under the unreleased 0.2.4 changeset.
- **Scenario A considerations:** No schema changes — the `df` schema equivalence contract is unchanged.
- **Scenario B1 considerations:** The new `.so` works against all previous schemas. The guard runs before any SQL is issued and reads no catalog or table state — it only compares the caller's `limit_count` against an in-memory GUC value — so it is correct against a pre-0.2.4 schema that has not run `ALTER EXTENSION UPDATE`. The only visible difference against an old schema is the intended one: a large `limit_count` now errors instead of being silently capped at 10000.
- **Scenario B2 considerations:** No data migration. The GUC has no effect on schema shape or existing data.

This follows the runtime-only precedent of `pg_durable.enable_superuser_instances` below (DDL change: None, enforced entirely in the `.so`).

### v0.2.2 → v0.2.3

#### Rename duroxide provider schema to `_duroxide` for fresh installs
- **DDL change (df schema):** Adds `df.duroxide_schema()`, an `IMMUTABLE`/`PARALLEL SAFE` SQL function that returns the name of the schema holding the duroxide provider objects. Fresh 0.2.3 installs create the function (in `src/lib.rs`) returning `'_duroxide'`; the upgrade script `sql/pg_durable--0.2.2--0.2.3.sql` creates the same function returning `'duroxide'` so pre-existing installs keep using the legacy schema. Both bodies set `search_path = pg_catalog, pg_temp` to satisfy the pgspot gate.
- **DDL change (provider schema):** Fresh installs now run `CREATE SCHEMA _duroxide` (was `CREATE SCHEMA duroxide`). The upgrade script does **not** rename, drop, or move the existing `duroxide` schema — renaming an in-use provider schema would orphan the BGW's durable state. Upgraded installs therefore continue to use `duroxide`.
- **Runtime selection:** Backend sessions resolve the provider schema once per session via `backend_duroxide_schema()` (cached in a `OnceLock`); the BGW resolves it once per epoch via `resolve_duroxide_schema_pool()` (re-resolved after every CREATE EXTENSION so drop+recreate with a different schema version is handled). Both call `df.duroxide_schema()` and fall back to `'duroxide'` (`LEGACY_DUROXIDE_SCHEMA`) when the helper is absent — i.e. a new `.so` deployed against a ≤0.2.2 schema that has not run `ALTER EXTENSION pg_durable UPDATE`. Presence is detected via a `pg_proc` catalog lookup rather than catching `42883`, so the surrounding (sub)transaction is never aborted.
- **Scenario A considerations:** The Scenario A equivalence contract covers the `df` schema only and compares function signatures, not bodies. `df.duroxide_schema()` has an identical signature on the fresh-install and upgrade paths (only the returned literal differs), so Scenario A passes. The provider schema name (`_duroxide` vs `duroxide`) is intentionally excluded from the snapshot diff, as it was for v0.2.0.
- **Scenario B1 considerations:** The new `.so` works against all previous schemas: when `df.duroxide_schema()` does not exist (≤0.2.2 schemas without the upgrade applied) the runtime falls back to `'duroxide'`, which is exactly the schema those installs use.
- **Scenario B2 considerations:** No data migration. The existing `duroxide` schema and its tables are untouched; the upgrade only adds one `df` function.
- **Test fixture:** A new `sql/pg_durable--0.2.2.sql` install fixture is checked in at the provider-compat-start boundary. The upgrade harness now reconstructs 0.2.2 directly from it (an empty `duroxide` schema that the BGW populates via the duroxide-pg `ApplyAll` migration) instead of chaining from the pre-provider `pg_durable--0.1.1.sql` fixture, whose embedded hand-written `duroxide` schema lacks the `_duroxide_migrations` tracking table and is therefore incompatible with the duroxide-pg provider.

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
