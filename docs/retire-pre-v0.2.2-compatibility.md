---
title: "refactor: Retire pre-v0.2.2 compatibility"
type: refactor
status: abandoned
date: 2026-08-06
---

# refactor: Retire pre-v0.2.2 compatibility

> **Abandoned — premise disproved. Do not act on this plan.**
>
> PR #339 was closed on 2026-08-11 after v0.2.1 installations were found in the
> field. The Safety Verdict below rests entirely on "published GitHub releases
> begin at v0.2.2, so no released artifact exists below the floor" — an inference
> from release history rather than a population measurement, as the Evidence
> Basis section itself concedes. That inference was wrong.
>
> Deleting `sql/pg_durable--0.2.1--0.2.2.sql` and the BGW ownership conversion
> would remove the only upgrade path those installations have: the upgrade script
> carries the `df` schema changes, and the conversion plus `ApplyAll` carries the
> `duroxide-pg-opt` to `duroxide-pg` provider transition. This plan deletes both
> halves.
>
> Retained as a record of the analysis and of how the floor decision was reached.

## Safety Verdict

**Yes, it is safe to retire every pre-v0.2.2 compatibility path and SQL artifact
from this repository now, with one downstream caveat.**

Two terms are used throughout this document and nowhere else are they varied.
The **provider compatibility line** is the set of supported open-source releases,
v0.2.2 and later. The **v0.2.2 floor** is its minimum version, defined by
`PROVIDER_COMPAT_START_VERSION` in `scripts/test-upgrade.sh`.

The v0.2.2 install fixture is the lowest schema any current binary must serve. It
has only `submitted_by`, has owner-scoped variables, starts with an empty
extension-owned provider schema, and records readiness in `_worker_ready`.
Therefore none of the four retired runtime paths — `login_role` inserts,
pre-v0.2.0 global-variable queries, v0.1.1 provider-object ownership conversion,
and `df._worker_epoch` readiness polling — is reachable from any schema covered
by the current B1 contract.

`sql/pg_durable--0.1.1.sql` is only a reconstruction fixture and is not included
in current package output, so deleting it has no package impact. Three migration
edges — `0.1.1→0.2.0`, `0.2.0→0.2.1`, and `0.2.1→0.2.2` — are included in current
package output, and each advertises a PostgreSQL upgrade route whose source
version is below the v0.2.2 floor. PostgreSQL does not require released scripts
to remain forever; deleting all three intentionally removes those routes from
future packages. This is appropriate only because pre-v0.2.2 installations are
outside the provider compatibility line.

It is **not** safe for a downstream fork whose floor is below v0.2.2. In
particular, a v0.1.1 `df.instances.login_role` column is `NOT NULL`, and
pre-v0.2.2 releases use a different durable-state provider line. The repository
documentation assigns the older `duroxide-pg-opt` line to the Azure fork; that
fork must retain all four retired SQL artifacts and the retired Rust
compatibility paths, or make its own compatibility-boundary decision, rather than
taking this cleanup blindly.

**Evidence basis for the floor.** The claim that no supported installation sits
below v0.2.2 rests on one verified fact: this repository's published GitHub
releases begin at v0.2.2 (2026-06-10), so no released artifact exists below the
floor. Tags `v0.1.1`, `v0.2.0`, and `v0.2.1` exist and remain installable from
source. No telemetry, download statistics, or support data were consulted, and
none are available. The R8 background-worker guard exists precisely because the
evidence is a release-history argument rather than a population measurement.

## Overview

Enforce the existing v0.2.2 floor across packaging, tests, and documentation:
remove all incoming SQL paths from older versions, then delete runtime and
harness compatibility that only serves those retired schemas. This includes
`login_role`, pre-v0.2.0 global-variable queries, v0.1.1 provider-object
ownership conversion, and legacy readiness polling. Rewrite current-tense
documentation that implies any pre-v0.2.2 schema remains inside this repository's
compatibility matrix.

No supported schema changes shape: this adds no DDL and no replacement upgrade
script, and the generated v0.2.2+ install SQL and the v0.2.2+ upgrade edges are
byte-identical after this change. It is **not** neutral for packaging: four
pre-floor SQL artifacts are deleted, so future packages advertise fewer
`ALTER EXTENSION UPDATE` source versions.

## Problem Frame

`src/dsl.rs` still carries a `legacy_login_role_schema()` probe and two insert
layouts. The legacy layout exists solely to satisfy v0.1.1 table constraints.
That compatibility work predates the v0.2.2 switch from `duroxide-pg-opt` to
`duroxide-pg`, which established the provider compatibility line and excluded
pre-v0.2.2 schemas from A, B1, and B2 upgrade testing.

The old support adds conditional SQL generation, argument-count bookkeeping,
extension-version caching and parsing, five variable-query branches, a large
background-worker ownership-conversion path, readiness fallback logic, four SQL
artifacts, and stale documentation. None is exercised by the current v0.2.2+
upgrade matrix.

## Requirements Trace

- **R1.** Remove all executable `login_role` detection and insert behavior from
  the current Rust binary.
- **R2.** Preserve binary compatibility with every supported schema in the
  current provider line, including an unmigrated v0.2.2 schema.
- **R3.** Remove every install or upgrade SQL artifact whose source version is
  below v0.2.2 while retaining useful release history in prose and Git history.
- **R4.** Make the current compatibility policy unambiguous: support is scoped to
  the provider line, while pre-v0.2.2 behavior is historical and downstream-owned.
- **R5.** Preserve current graph batching, parameter numbering, identity capture,
  RLS behavior, and workflow execution semantics.
- **R6.** Remove variable-schema branches, worker ownership conversion, and
  test-harness readiness fallback that only serve pre-v0.2.2.
- **R7.** Keep every compatibility shim still required by v0.2.2 or later.
- **R8.** Reject a pre-v0.2.2 schema at background-worker initialization with an
  actionable error, before any provider DDL runs.

## Scope Boundaries

- Do not change the single-identity `submitted_by` security model.
- Do not add DDL or a replacement extension upgrade script; supported schemas
  already have the required shape.
- Do not delete or rewrite historical changelog entries merely because their SQL
  artifacts are removed. Git history remains the canonical source for the exact
  retired DDL.
- Do not rely on an incidental failure to protect a pre-v0.2.2 schema. The BGW
  guard (R8) is the designated control; `df.start()` failing on a `NOT NULL`
  violation is a side effect, not a contract.
- Do not remove `LEGACY_DUROXIDE_SCHEMA`, `resolve_duroxide_schema_spi()`, or
  `resolve_duroxide_schema_pool()`; an unaltered v0.2.2 schema does not have
  `df.duroxide_schema()` and still requires the legacy `duroxide` provider schema
  name.
- Do not remove the `debug_connection`, three-argument `start`, or
  `wait_for_completion` wrapper symbols. Supported v0.2.2-v0.2.4 catalogs still
  bind to them until the v0.2.2 floor advances past the catalogs that bind them.
- Do not remove graph-envelope, break-sentinel, or other data compatibility based
  only on the word “legacy”; those paths protect persisted data from supported
  releases and are unrelated to the v0.2.2 floor.

## Context & Research

### Relevant Code and Patterns

- `src/dsl.rs`: `legacy_login_role_schema()`, `node_insert_sql()`, nested
  `insert_nodes()`, and the `df.start()` instance insert are the complete runtime
  dependency set. No worker, activity, or orchestration reads `login_role`.
- `src/dsl.rs`: `parse_semver()`, `installed_extension_version()`, and
  `owner_scoped_vars_enabled()` exist only to select pre-v0.2.0 global-variable
  queries. With a v0.2.2 floor, all variable operations can use owner-scoped SQL.
  `installed_extension_version()` reads through SPI and is therefore
  backend-only; the BGW guard added by this plan reads through the sqlx pool and
  cannot reuse it.
- `src/worker.rs`: `has_extension_owned_duroxide_objects()` and
  `release_extension_owned_duroxide_objects()` only convert provider objects
  embedded by the v0.1.1 install SQL. The v0.2.2 fixture starts with an empty,
  extension-owned provider schema whose objects are created by `ApplyAll` and
  are not extension members.
- `src/dsl.rs` tests: one test covers the supported nine-parameter node layout;
  one covers only the unsupported ten-parameter legacy layout.
- `tests/e2e/sql/09_graph_and_validation.sql`: the existing 1,002-node scenario
  crosses `NODE_INSERT_BATCH_SIZE` and is the integration regression for the
  simplified node SQL generator.
- `scripts/test-upgrade.sh`: the executable compatibility policy defaults to a
  v0.2.2 floor and runs B1 directly against every prior schema at or above it.
- `sql/pg_durable--0.2.2.sql`: the baseline fixture has `submitted_by` and
  `database` columns but no `login_role` on either table.
- `sql/pg_durable--0.1.1.sql`: a reconstruction fixture below the v0.2.2 floor;
  current pgrx package output does not include it.
- `sql/pg_durable--0.1.1--0.2.0.sql`, `sql/pg_durable--0.2.0--0.2.1.sql`, and
  `sql/pg_durable--0.2.1--0.2.2.sql`: three incoming upgrade edges whose source
  version is below the v0.2.2 floor. All three are in current pgrx package
  output. A supported v0.2.2 installation starts from `sql/pg_durable--0.2.2.sql`,
  so none of them participates in a v0.2.2+ upgrade chain.
- `scripts/pgspot-gate.sh`: its `EXCLUDE` array lists all three pre-pgspot
  migrations (`0.1.1--0.2.0`, `0.2.0--0.2.1`, `0.2.1--0.2.2`); every entry becomes
  a stale exclusion once the files are deleted.
- `docs/upgrade-testing.md`: provider compatibility line rules are authoritative,
  but the
  historical `login_role` subsection still uses current-tense B1 wording.
- `docs/user-isolation.md`: accurately records the old model but currently says
  “the new binary” still supports v0.1.1, which would become false.
- `.github/copilot-instructions.md` and the header of `scripts/test-upgrade.sh`:
  summarize B1 as same-major support and should instead name the provider
  compatibility line and the v0.2.2 floor.

### Historical Decisions

- PR #91 removed `login_role` from the v0.2.0 schema and simplified execution to
  authenticate directly as `submitted_by`.
- PR #158 established v0.2.2 as the first open-source `duroxide-pg` provider
  compatibility version. Pre-v0.2.2 provider state is not a supported upgrade or
  direct-contact source in this repository.
- PR #337 retained the legacy layout while batching graph node inserts; its
  supported-layout and batch-boundary coverage should remain after cleanup.

### External Research

None. The repository's explicit provider compatibility line and checked-in
fixtures fully determine the v0.2.2 floor.

## Key Technical Decisions

- **Use the v0.2.2 floor as the removal gate.** It is stricter than the package's
  major version and matches the actual CI matrix.
- **Collapse to one insert shape rather than retaining a disabled flag.** A
  constant `false` branch would preserve complexity without preserving a
  supported behavior.
- **Retire the unsupported SQL edges together with the runtime paths that served
  them.** Keeping the three pre-v0.2.2 migrations in package output would imply
  upgrade routes that cross the provider compatibility line. Prose, changelog
  entries, and Git history are sufficient for historical explanation.
- **Order the work inside one PR rather than splitting it across releases.** Both
  halves land in the same unreleased version, so a phase split would produce an
  intermediate commit, not an intermediate release, and would deliver no safety
  property that internal ordering does not. The real constraint is that the
  runtime removals must never appear in a released artifact that precedes the
  package and documentation changes; a single PR satisfies that by construction.
- **Add a background-worker version guard instead of relying on incidental
  failure.** On a pre-v0.2.2 schema, `MigrationPolicy::ApplyAll` runs
  `duroxide-pg` migrations against a `duroxide-pg-opt` schema — `DROP FUNCTION`
  and `ALTER TABLE` against live orchestration state, executed by a background
  process with no user in the loop. The realistic worst case is partial migration
  and provider-state corruption, not a clean failure. One `SELECT extversion` at
  BGW init that refuses to proceed below the floor is far cheaper than the
  conditional fork it replaces, and it makes the removals in this plan provably
  unreachable rather than merely untested.

## Open Questions

### Resolved During Planning

- **Does any supported schema require `login_role`?** No. The v0.2.2 floor is the
  lowest B1 target, and its fixture does not contain the column.
- **Does the worker use `login_role` to execute old instances?** No. Current
  execution authenticates as `submitted_by`; the remaining code only writes the
  legacy column during `df.start()`.
- **Is extension DDL required?** No. This removes compatibility with an
  unsupported old shape rather than changing the supported shape.
- **Should all pre-floor SQL be removed?** Yes. Delete the v0.1.1 install fixture
  and all three incoming migration edges through v0.2.2. The v0.2.2 fixture is
  the complete baseline for every supported reconstruction and upgrade.
- **Can extension-version detection go too?** Partly. `owner_scoped_vars_enabled()`
  and `installed_extension_version()` go: the former has no supported consumer,
  and the latter is SPI-based with no caller once the former is deleted. Keep
  `parse_semver()` — the new BGW guard (R8) needs it, so make it `pub(crate)`.
  The guard reads `extversion` through the sqlx pool, which is why the SPI
  helper cannot be reused.
- **Can every legacy shim go?** No. Provider schema-name fallback and old SQL
  wrapper symbols are still required by supported v0.2.2-v0.2.4 schemas.
- **How should `wait_for_ready()` be simplified?** Resolved: move the existence
  test *inside* the polling loop (`to_regclass`) and resolve the provider schema
  via `df.duroxide_schema()` with the legacy `duroxide` fallback. The original
  wording rested on a false premise. `wait_for_ready()` performs a *one-shot*
  probe for `duroxide._worker_ready` **before** its loop, and the BGW creates
  that table lazily after `CREATE EXTENSION` returns, so the probe normally fails
  and `df._worker_epoch` is the branch the harness takes on essentially every run
  today. Deleting the fallback without moving the probe makes the first poll
  error on a missing relation and `return 1`, failing readiness immediately for
  every B1 and B2 version. The hardcoded `duroxide` schema is correct today only
  because every reconstructed install derives from the v0.2.2 fixture; it breaks
  as soon as the floor advances, which is this plan's direction.
- **Keep or delete the worker ownership conversion?** Delete. Any installation
  that started on v0.1.1 has already run `ALTER EXTENSION UPDATE` past it, and
  the conversion is idempotent and self-healing, so one completed BGW start
  clears the state permanently. Residual exposure is narrow and accepted: a
  database that upgraded past v0.1.1 but has *never* completed a single BGW
  initialization. Note this is not covered by the R8 guard, which only rejects
  schemas below the floor.
- **How is the contract break released?** In the next unreleased version with a
  changelog notice only — no version bump beyond the normal patch, no deprecation
  window. Justification: published GitHub releases begin at v0.2.2, so there is
  no released artifact below the floor.
- **One PR or two phases?** One PR, ordered internally: package and script
  changes, then documentation, then runtime removals.

### Deferred Outside This Repository

- **Downstream coordination:** The Azure fork must retain or recover all four SQL
  files and the retired Rust compatibility if it still claims pre-v0.2.2
  compatibility. This does not block cleanup in the open-source line, but it
  blocks an unreviewed downstream merge of the deletion.

## Delivery

This is approximately a medium-sized compatibility cleanup: four SQL deletions,
two Rust modules, two scripts, and roughly nine documentation or instruction
files. Most changed lines are deletions, but package and B1 behavior make the
blast radius larger than the original single-module cleanup.

Ship as **one PR**, ordered internally so the runtime removals never precede the
package and documentation changes: Unit 1, then Unit 2, then Units 3 and 4. A
phase split would produce an intermediate commit, not an intermediate release,
since every unit lands in the same unreleased version.

## Implementation Units

- [ ] **Unit 1: Retire pre-v0.2.2 package and test inputs**

**Goal:** Make v0.2.2 the first and only baseline from which current upgrade
tests and future packages advertise support.

**Requirements:** R3, R4, R6

**Dependencies:** None.

**Files:**
- Delete: `sql/pg_durable--0.1.1.sql`
- Delete: `sql/pg_durable--0.1.1--0.2.0.sql`
- Delete: `sql/pg_durable--0.2.0--0.2.1.sql`
- Delete: `sql/pg_durable--0.2.1--0.2.2.sql`
- Modify: `scripts/pgspot-gate.sh`
- Modify: `scripts/test-upgrade.sh`

**Approach:**
- Delete the reconstruction fixture and all three migration edges entering the
  provider compatibility line from a release below the v0.2.2 floor.
- Remove all three deleted migrations from the pgspot legacy exclusion list.
- Leave `first_fixture_for_major()` and `FIRST_VERSION` alone. Verified: after
  the deletion they resolve to v0.2.2 and keep working with no edits, and
  `base_fixture_for_version()` already refuses sub-floor fixtures via the
  `PROVIDER_COMPAT_START_VERSION` guard. Keep that guard as defensive code even
  though no sub-floor fixture will remain.
- Simplify `wait_for_ready()`: move the `_worker_ready` existence test *inside*
  the polling loop (`to_regclass`), resolve the provider schema via
  `df.duroxide_schema()` with the legacy `duroxide` fallback, and only then drop
  the `df._worker_epoch` branch. Removing the fallback without the first two
  steps breaks every B1 and B2 run — see Open Questions.

**Test scenarios:**
- **Packaging:** Package the extension and verify no SQL file begins below
  v0.2.2 while current install SQL and v0.2.2+ migrations remain present.
- **Readiness:** Create the extension at v0.2.2 and at v0.2.5 and verify the
  harness observes `_worker_ready` in each install's resolved provider schema
  before running B1 operations.
- **SQL gate:** Verify pgspot has no stale exclusions for deleted files and scans
  every remaining active migration.

**Verification:**
- Package validation and the full upgrade harness pass.
- PostgreSQL reports no available update path whose source is below v0.2.2.

- [ ] **Unit 2: Publish the retirement policy**

**Goal:** Make the v0.2.2 floor and downstream ownership explicit without
erasing useful release history.

**Requirements:** R3, R4

**Dependencies:** Unit 1.

**Files:**

Required — contains a link to a deleted SQL file, or a present-tense claim that
the current binary or test matrix supports a pre-v0.2.2 schema:
- Modify: `CHANGELOG.md`
- Modify: `.github/copilot-instructions.md` (the only actual markdown link to a
  deleted file)
- Modify: `docs/upgrade-testing.md` (also rewrite the "preparing for the next
  version" worked example, which uses the two deleted v0.1.1 files as its model
  and is the contributor onboarding path)
- Modify: `docs/user-isolation.md`
- Modify: `docs/bgw-applies-migrations.md`
- Modify: `docs/extension_lifecycle.md`
- Modify: `USER_GUIDE.md` (user-facing present-tense claim about v0.1.1-upgraded
  installs retaining legacy PUBLIC grants)
- Modify: `docs/http-security.md` (same claim)
- Modify: `docs/move-duroxide-schema.md` (records Azure-shipped v0.1.1/v0.2.1)

Narrative sweep — plain-text mentions inside past-tense design history, no broken
links; correct only where the tense or framing is now misleading:
- Review: `docs/rls.md`, `docs/spec-http-function-permissions.md`,
  `docs/spec-security-model.md`

**Approach:**
- Apply this selection rule: a file needs a required edit only if it (a) contains
  a markdown link to a deleted SQL file, or (b) makes a present-tense claim that
  the current binary or test matrix supports a pre-v0.2.2 schema. Separately
  sweep past-tense narrative and correct anything whose framing now misleads.
- State that current open-source binaries, packages, and tests support v0.2.2+
  only; pre-v0.2.2 belongs to the retired `duroxide-pg-opt` line.
- Add a changelog entry under the next unreleased version stating that packages
  from that release forward contain no incoming pre-v0.2.2 upgrade paths, and
  that the BGW now refuses to initialize against a pre-v0.2.2 schema. At time of
  writing that version is `[0.2.6] - Unreleased`; confirm before editing. No
  version bump beyond the normal patch and no deprecation window — published
  releases begin at v0.2.2, so no released artifact sits below the floor.
- Convert current-tense old-schema claims to clearly labeled history. Preserve
  security and design rationale, but stop presenting deleted files as active
  fixtures or supported migrations.
- Record in `docs/upgrade-testing.md` what the floor decision actually rests on:
  published GitHub releases begin at v0.2.2; no telemetry or support data was
  consulted.
- Keep historical release entries; Git history retains exact retired DDL.

**Test scenarios:**
- **Consistency:** Every present-tense compatibility rule names the provider
  compatibility line and the v0.2.2 floor.
- **References:** No active link or instruction expects one of the four deleted
  SQL files to exist.
- **Downstream:** The retirement notice states that forks supporting the old
  provider line must retain their own artifacts and compatibility code.

**Verification:**
- Repository search finds no claim that the current binary supports pre-v0.2.2,
  and no active reference to any of the four deleted filenames.
- Documentation lint/diagnostics report no broken local references.

- [ ] **Unit 3: Simplify DSL persistence and variables**

**Goal:** Collapse all schema-sensitive DSL queries to the v0.2.2+ table shapes.

**Requirements:** R1, R2, R5, R6, R7

**Dependencies:** Unit 1.

**Files:**
- Modify and test: `src/dsl.rs`

**Approach:**
- Delete `legacy_login_role_schema()` and simplify instance and batched-node
  inserts to the current `submitted_by`-only layouts.
- Delete `owner_scoped_vars_enabled()` and `installed_extension_version()` plus
  the latter's cache. Trim the now-orphaned `RefCell` import; `Duration` and
  `Instant` remain in use elsewhere in the module.
- **Keep `parse_semver()` and its four unit tests**, and raise it to `pub(crate)`
  so the Unit 4 BGW guard can use it. `installed_extension_version()` cannot be
  kept alongside it: it reads through SPI, the BGW guard reads through the sqlx
  pool, and once `owner_scoped_vars_enabled()` is gone it has no caller — leaving
  it would fail `cargo clippy` in CI.
- Make `setvar()`, `getvar()`, `unsetvar()`, `clearvars()`, and variable capture
  always use owner-scoped v0.2.2+ SQL.
- Preserve batching, parameter numbering, identity casts, transaction modes, and
  the supported old SQL wrapper symbols.

**Test scenarios:**
- **Node SQL:** Two generated rows use nine parameters each and contain no
  `login_role`.
- **Batch boundary:** The existing 1,002-node scenario persists exactly 1,002
  nodes across two batches.
- **Variables:** Two roles can set the same variable name independently; get,
  unset, clear, and start-time capture remain owner-scoped.
- **B1:** Current binary against an unaltered v0.2.2 schema completes start,
  result, monitoring, and variable operations.

**Verification:**
- Formatting, unit tests, variable/RLS E2E, graph E2E, and B1 pass.
- No runtime code selects a query shape by extension version, and no runtime code
  mentions `login_role`. `parse_semver()` survives with the BGW guard as its
  only non-test caller.

- [ ] **Unit 4: Guard the floor at BGW init and remove ownership conversion**

**Goal:** Refuse to initialize against a pre-v0.2.2 schema before any provider
DDL runs, then remove the background-worker DDL that only converted provider
objects embedded by the retired v0.1.1 install SQL.

**Requirements:** R2, R6, R7, R8

**Dependencies:** Unit 1, Unit 3.

**Files:**
- Modify: `src/worker.rs`
- Test: worker startup and upgrade coverage in `scripts/test-upgrade.sh`

**Approach:**
- Add a version guard at the start of `initialize_duroxide_runtime()`, before
  `MigrationPolicy::ApplyAll`. Read `extversion` from `pg_extension` through the
  sqlx pool, compare with `parse_semver()`, and on a version below v0.2.2 log a
  fatal, actionable error naming the installed version, the required floor, and
  the `duroxide-pg-opt` downstream process. Do not enter the retry loop — a
  retry cannot fix a schema-version mismatch.
- Delete `has_extension_owned_duroxide_objects()` and
  `release_extension_owned_duroxide_objects()` and remove their initialization
  branch.
- Delete or re-scope `test_b1_no_extension_owned_duroxide_objects` in
  `scripts/test-upgrade.sh`. It exists solely to verify the removed function and
  becomes a tautology afterward; if retained, rewrite its comment to state it is
  a fresh-install invariant, not an upgrade assertion.
- Keep `check_duroxide_schema_owned()`: it protects against an attacker-crafted
  provider schema and applies to supported installations.
- Keep `MigrationPolicy::ApplyAll`, readiness recording, and all v0.2.2 schema
  name resolution unchanged.

**Test scenarios:**
- **Guard rejects:** A schema below v0.2.2 causes BGW init to fail with the
  actionable message and no provider DDL is executed.
- **Guard admits:** v0.2.2 through the current version initialize normally.
- **Startup:** BGW verifies the extension-owned provider schema, applies provider
  migrations, writes readiness, and starts normally on both a fresh install and a
  restart of a fully migrated database.
- **Security:** A provider schema not owned by `pg_durable` is still rejected.
  Write this test if it does not exist — `check_duroxide_schema_owned()` is
  currently only exercised implicitly on the happy path.

**Verification:**
- Worker startup, E2E, shutdown, and full upgrade tests pass.
- No worker SQL issues `ALTER EXTENSION ... DROP` for provider objects.
- The guard runs before any statement that could mutate provider state.

**Accepted residual risk:** the ownership conversion is a state-conditional
repair keyed on `pg_depend`, not a version branch, so the R8 guard does not cover
it — the guard admits any v0.2.2+ schema regardless of lineage. Exposure is a
database that upgraded past v0.1.1 but has never completed a single BGW
initialization. Accepted on the basis that the conversion is idempotent and one
completed BGW start clears the state permanently, and that no known installation
started on v0.1.1 without having already upgraded. Note that neither Scenario A
(which excludes the provider schema from the snapshot diff) nor B1 (which
reconstructs from an empty v0.2.2 provider schema) can detect a regression here.

## Explicitly Retained Compatibility

- `LEGACY_DUROXIDE_SCHEMA`, `resolve_duroxide_schema_spi()`, and
  `resolve_duroxide_schema_pool()` remain for an unaltered v0.2.2 schema.
- `parse_semver()` remains as the comparison primitive for the R8 BGW guard.
- `check_duroxide_schema_owned()` remains as a security control.
- `debug_connection`, three-argument `start`, and `wait_for_completion` wrapper
  symbols remain for supported old catalog bindings.
- Persisted graph/envelope compatibility remains unless a separate versioned
  analysis proves its originating releases are below the v0.2.2 floor.

## System-Wide Impact

- **Interaction graph:** `df.start()` continues to materialize the graph, reserve
  the instance, insert batched nodes, and capture owner-scoped variables. Only
  unreachable pre-v0.2.2 query layouts disappear.
- **Error propagation:** Supported schemas keep existing errors. A pre-v0.2.2
  schema is rejected by the R8 guard at BGW initialization with an actionable
  message, before `ApplyAll` can execute provider DDL. This replaces the previous
  worst case — partial migration of a `duroxide-pg-opt` schema by the
  `duroxide-pg` migration set, with no user in the loop.
- **State lifecycle risks:** No supported persisted row changes. In-flight v0.2.2+
  instances use the retained schema resolver and persisted-data compatibility and
  are unaffected.
- **API surface parity:** No SQL function signature, operator, activity input, or
  orchestration history changes.
- **Integration coverage:** Unit SQL-generation coverage is insufficient by
  itself; variable/RLS E2E, worker startup, package inspection, and v0.2.2
  direct-contact B1 collectively prove the affected paths.
- **Unchanged invariants:** Current schemas have one execution identity,
  `submitted_by`; schema upgrades remain customer-initiated; the current binary
  remains compatible with every schema in the provider compatibility line.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A downstream fork still supports pre-v0.2.2 | Call out the v0.2.2 floor in the changelog and coordinate before downstream adoption; retain the retired runtime paths and all four SQL files in that fork if needed. |
| A v0.2.2-required shim is mistaken for pre-floor code | Use the explicit retention list and require a v0.2.2 direct-contact B1 run before the PR merges. |
| Owner-scoped variable simplification changes behavior | Run the existing variable and RLS E2E coverage for multiple roles plus v0.2.2 B1 variable capture. |
| Batch parameter numbering regresses when the `legacy_login_role_schema()` branch and its argument-count bookkeeping are removed | Preserve the two-row unit assertion and run the 1,002-node E2E case. |
| Worker cleanup removes a security check with broader purpose | Remove only extension-member conversion; retain `check_duroxide_schema_owned()` and add the missing direct test for it. |
| A v0.1.1-lineage database at a supported version still holds extension-owned provider objects | Accepted: the conversion is idempotent and one completed BGW start clears it permanently. Not detectable by Scenario A or B1 — see Unit 4's residual-risk note. |
| The R8 guard rejects a schema it should admit | Test both directions explicitly (below-floor rejects, v0.2.2 through current admit) rather than only the happy path. |
| Exact historical DDL is less discoverable | Keep concise prose history and rely on immutable Git history for the retired files. |
| Packages silently stop offering a route someone still uses | Treat deletion as an explicit support-policy change, note it in the changelog, and confirm downstream ownership before adoption. Published releases begin at v0.2.2, so no released artifact sits below the floor. |
| An operator on a pre-v0.2.2 schema installs the new package and is stranded | The R8 guard fails BGW init with an actionable message instead of corrupting provider state. Recovery is a package downgrade; the changelog notice must say so. |
| Documentation continues to imply same-major support | Update contributor/test headers and current-tense historical notes in the same change. |

## Documentation / Operational Notes

- No operator migration is needed for supported open-source installations.
- Do not instruct pre-v0.2.2 users to install the new binary directly. The BGW
  will refuse to initialize and the extension will not function. They belong to
  the older `duroxide-pg-opt` line and require the upgrade/support process owned
  by that downstream distribution.
- Future packages intentionally do not support `ALTER EXTENSION UPDATE` from
  v0.1.1, v0.2.0, or v0.2.1. Anyone who unexpectedly still has one of those
  schemas must downgrade to an older package containing the migration chain, or
  follow the downstream process for the `duroxide-pg-opt` line. State this
  recovery path in the changelog notice — by the time the failure is observed the
  old package's SQL has already been overwritten on disk.
- This cleanup does not itself advance `PROVIDER_COMPAT_START_VERSION`; it merely
  removes code below the already-established v0.2.2 floor and makes that floor
  enforceable at runtime.

## Sources & References

**Retired artifacts**
- `sql/pg_durable--0.1.1.sql`
- `sql/pg_durable--0.1.1--0.2.0.sql`
- `sql/pg_durable--0.2.0--0.2.1.sql`
- `sql/pg_durable--0.2.1--0.2.2.sql`

**Modified sources**
- `src/dsl.rs`
- `src/worker.rs`
- `scripts/test-upgrade.sh`
- `scripts/pgspot-gate.sh`

**Baseline fixture**
- `sql/pg_durable--0.2.2.sql`

**Documentation**
- `CHANGELOG.md`
- `.github/copilot-instructions.md`
- `docs/upgrade-testing.md`
- `docs/user-isolation.md`
- `docs/bgw-applies-migrations.md`
- `docs/extension_lifecycle.md`

**Coverage**
- `tests/e2e/sql/09_graph_and_validation.sql`

**History**
- PR #91: single-identity `submitted_by` model
- PR #158: v0.2.2 `duroxide-pg` provider compatibility line
- PR #337: batched graph node inserts