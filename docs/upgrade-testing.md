# Upgrade Testing Plan

## Deployment Model

pg_durable follows a two-phase upgrade model:

1. **Binary update**: The new pg_durable version is installed, PostgreSQL is restarted, and the new `.so` is loaded.
2. **Schema update** (customer-initiated): `ALTER EXTENSION pg_durable UPDATE TO '<version>'` runs the upgrade SQL script. Customers may defer this for days, months, or indefinitely.

This means the new `.so` **must be backward compatible** with every older supported schema, not just the immediately previous version. The `.so` and the upgrade script are not atomic: the new binary may run against an older schema indefinitely.

Supported schemas are previous releases in the **current major version**, starting at v0.2.2. That start is `PROVIDER_COMPAT_START_VERSION` in `scripts/test-upgrade.sh` (default `0.2.2`, overridable by downstream forks). The harness does not test earlier majors or versions before that boundary. Versions before v0.2.2 used a different durable-state provider and are not upgrade sources for open-source pg_durable.

pg_durable was open-sourced at v0.2.2. Upgrade compatibility impact is tracked for each release starting with v0.2.3.

We never downgrade. Downgrade scripts are not needed.

## Upgrade Guarantees

### Guarantee A: Schema Upgrade Correctness

**Goal:** Verify that `ALTER EXTENSION UPDATE` produces an identical schema to a fresh `CREATE EXTENSION`.

**Contract:** For a not-yet-released version, the fresh-install schema must match what an existing customer gets by installing the immediately previous compatible release and applying the shipped upgrade chain. If fresh install and upgrade differ before release, align the new version's fresh-install DDL with the upgrade path unless there is a deliberate reason to change that contract.

**Method:**
1. Install current `.so` and all upgrade SQL files
2. In a clean test database, run `CREATE EXTENSION pg_durable VERSION '<prev>'` → `ALTER EXTENSION pg_durable UPDATE TO '<current>'`, then capture a schema snapshot
3. In the same clean test database (after dropping the extension) or in a second clean database, run `CREATE EXTENSION pg_durable` and capture a fresh-install snapshot
4. Compare schemas: tables, columns, types, constraints, indexes, RLS policies, grants

**What it catches:**
- Missing DDL in upgrade script (forgotten tables, columns, policies)
- Wrong column types, defaults, or constraint names
- Ordering issues in upgrade SQL

**Versions tested:** The immediately previous release, when that release is at or after v0.2.2. The harness skips this guarantee when the previous release is before `PROVIDER_COMPAT_START_VERSION`. Earlier upgrade scripts are frozen and were tested when they shipped; only the current work-in-progress script can introduce a new schema inconsistency.

### Guarantee B1: Binary Backward Compatibility

**Goal:** Verify that the new `.so` works correctly against **all** previous versions' schemas, not just the immediately previous one. Customers may never run `ALTER EXTENSION UPDATE`, so the new binary must work against any older supported schema.

**Versions tested:** Every previous release in the current major version, starting with v0.2.2. Earlier majors and versions before `PROVIDER_COMPAT_START_VERSION` are outside this guarantee.

**Method:**
1. Install the new `.so`
2. For each previous version in that range, install from the highest checked-in fixture at or below the target, then apply upgrade scripts up to that version. Open-source versions from v0.2.2 upward reconstruct from `sql/pg_durable--0.2.2.sql`. Keep that fixture: without it, reconstruction would chain through `sql/pg_durable--0.1.1.sql`, whose embedded duroxide schema is incompatible with duroxide-pg migration tracking (`_duroxide_migrations`).
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

### Guarantee B2: Data Compatibility After Upgrade

**Goal:** Verify that data created under the previous version remains accessible and functional after `ALTER EXTENSION UPDATE`.

**Versions tested:** The immediately previous release, when that release is at or after v0.2.2. The harness skips this guarantee when the previous release is before `PROVIDER_COMPAT_START_VERSION`.

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

### Real previous-binary lifecycle (N-1 to N)

The default [upgrade harness](../scripts/test-upgrade.sh) also runs
[upgrade_lifecycle.py](../scripts/upgrade_lifecycle.py) against the immediately
previous compatible release. Unlike the reconstructed-schema tests above, this
test builds and runs the tagged **previous binary** to produce real instances,
results and durable histories before installing the candidate.

The same database is retained through three phases:

| Phase | Binary | Extension schema | Assertions |
|-------|--------|------------------|------------|
| Baseline | N-1 | N-1 | For every behavior family, hold two instances at a durable suspension inside the shape; also complete one `seq` instance. Check results, captured variables, owner and side effects. |
| B1 | N | N-1 | Restart with the candidate binary without `ALTER EXTENSION`; revalidate suspended instances, resume each family's first instance, and create both a completed `seq` instance and a suspended `seq-binary-b2` instance. |
| B2 | N | N | Run `ALTER EXTENSION UPDATE`; revalidate, resume each family's second instance and `seq-binary-b2`, and execute a new instance. |

The additional `seq-binary-b2` instance preserves the original lifecycle's
new-binary/old-schema to new-binary/new-schema scenario. Together with the
N-1 family instances, it verifies that histories created both before and after
the binary swap survive the schema upgrade. The final phase validates 18 instances.

#### Behavior-family coverage

Each suspended instance belongs to one behavior family, and every family is
resumed once under B1 and once under B2, so replay is exercised across both
boundaries. The families mirror the nested DSL combinators and the explicit
else and break seeds in the fixed shape corpus
([tests/e2e/shapes](../tests/e2e/shapes/README.md)); `df.sql` is exercised by
every family:

| Family | Suspension point | What replay must preserve |
|--------|------------------|---------------------------|
| `seq` | Between two sequenced markers | Ordered continuation and the captured variable |
| `if-then` | Inside the taken then-branch | Branch selection; the else marker stays unrun |
| `if-else` | Inside the taken else-branch | Explicit else selection; the then marker stays unrun |
| `loop` | During the first iteration | Iteration state; later iterations run exactly once each |
| `break` | During logical iteration 1, before breaking on iteration 3 | Captured iteration state and exactly one marker for each of iterations 1, 2, 3 |
| `join` | One branch done, one suspended | The completed branch is not re-run on resume |
| `race` | Winner suspended, loser on a durably recorded long timer | Race resolution; the loser reaches terminal cancellation and never marks |

Each family records path-tagged marker rows with a `(label, path, occurrence)`
key, and the harness asserts exact per-path counts — including zero-count paths
for unrun branches and cancelled losers — before and after resume. The `break`
family uses a captured logical iteration counter independent of marker counts,
and asserts marker values `[1]` before resume and `[1, 2, 3]` afterward. Duplicating
an effect cannot advance the break condition and hide a missing iteration.
The `race` family checks the exact loser child's current provider execution:
it must be running with a recorded `TimerCreated` before resume, then reach
`failed` with an `OrchestrationFailed` application `Cancelled` error afterward.
An absent marker alone is not evidence of cancellation while the timer sleeps.
The `seq` family additionally records a first SQL result and a
persisted signal subscription before the transition; its continuation must reuse
that captured result and the start-time variable capture even though the live
variables changed. Its first marker must equal `41` both before and after resume,
and its continuation must equal `42`. Both markers resolve `{sys_label}` at
execution time rather than embedding the label during graph construction.
Completed outputs must remain byte-identical across phases.
Checks exercise `df.status`, `df.result`, `df.list_instances` and
`df.instance_info` as an ordinary granted role, and also check provider status
so a stale extension status cannot hide a replay failure.

This is **not** a historical release chain, nor does it transplant the full
shape corpus: it covers one in-flight instance per family through both upgrade
boundaries, not every nested permutation. Guarantee A, the all-supported-schema
B1 matrix and the existing B2 catalog/grant checks remain in place. The new
lifecycle adds real previous-binary evidence for N-1 only; it does not establish
replay compatibility with every older binary.

#### Running and diagnosing the lifecycle

Requires Python 3.11+, the existing cargo-pgrx/PostgreSQL build tools, and the
previous release tag (`git fetch origin --tags` if needed). N-1 is selected by
the existing harness from the upgrade script targeting the current version.
The normal `./scripts/test-upgrade.sh` invocation includes this test whenever
that predecessor is within the supported compatibility boundary. To run only
the lifecycle:

```bash
python3 scripts/upgrade_lifecycle.py \
  --pg-config ~/.pgrx/17.10/pgrx-install/bin/pg_config \
  --previous-version 0.2.8
```

The runner copies PostgreSQL into a private installation, uses a fresh cluster
and ephemeral loopback port, and stops its cluster on success or failure. It
never overwrites the shared PostgreSQL installation. Builds use the committed
lockfiles without dependency updates. A missing tag, build failure, unexpected
version, timeout or assertion failure fails the test; there is no accepted-break
mode. Build logs, PostgreSQL logs and phase snapshots are retained under the
printed `target/upgrade-lifecycle/` directory and uploaded by CI on failure.
`--output-dir` selects a new evidence directory; `--timeout` controls each
readiness/instance-validation deadline (default 60 seconds).

#### Replay sensitivity experiments

On 2026-09-30, four isolated source mutations demonstrated that the real N-1
lifecycle catches replay breaks missed by fresh-execution tests. These are
**historical measurements**, not an automatically maintained mutation suite.
The predecessor was `v0.2.8`, the candidate was `0.2.9` at
[89826bf](https://github.com/microsoft/pg_durable/commit/89826bf41c7628a050e3b636716b6424119d4642)
from [PR #411](https://github.com/microsoft/pg_durable/pull/411), and PostgreSQL
was 17.10. The unmodified candidate passed all lifecycle phases, validating 18
instances. Each mutation separately passed **424 unit tests (16 ignored) and
all 65 E2E tests**, but failed the lifecycle during B1 with
`nondeterministic: schedule mismatch`.

| Mutation | Observed replay rejection |
|----------|---------------------------|
| Rename `pg_durable::activity::execute-sql` to `pg_durable::activity::execute-sql-v2`, changing scheduling and registration together | Scheduled activity name differed from the recorded name |
| Schedule JOIN branches right-to-left, then reverse collected results to preserve fresh output order | `join-b1` scheduled the right child where history recorded the left child |
| Insert an unused `ctx.utc_now().await` before the loop's existing initial clock read | New clock operation appeared where history recorded `update-node-status` |
| Add an ignored `"compat_version": 2` field to the SQL activity input | Scheduled input bytes differed despite backward-compatible deserialization |

The same JOIN mutation also passed all 6 instances in the
[PR #409 lifecycle](https://github.com/microsoft/pg_durable/commit/515908008fe582463f87f6d965d88edd495b7521).
That lifecycle had no suspended JOIN history. Its rejection by #411 demonstrates
the additional value of per-family suspension points, beyond simply testing an
old binary. These results do not imply every future mutation will preserve
fresh execution or that every replay break is covered.

**Reproduction recipe (for those revisions):**

1. Use a disposable checkout of `89826bf41c7628a050e3b636716b6424119d4642`,
   fetch the `v0.2.8` tag, and install the normal pgrx build prerequisites with
   PostgreSQL 17.10. Run the unmodified lifecycle command above first and require
   success.
2. Apply exactly one mutation, leaving the predecessor tag untouched:
   - **Activity name:** change `NAME` in `src/activities/execute_sql.rs`; both
     scheduling and registration use that constant.
   - **JOIN order:** in `src/orchestrations/execute_function_graph.rs`, replace
     `for child_root in &branch_ids` with
     `for child_root in branch_ids.iter().rev()`. Make the result of
     `ctx.join(durable_futures).await` mutable and call `results_vec.reverse()`
     immediately afterward.
   - **Loop clock:** in the same orchestration file, insert
     `let _ = ctx.utc_now().await;` immediately before
     `let iter_started = ctx.utc_now().await.ok();`.
   - **Input bytes:** in the same file, add `"compat_version": 2,` to the SQL
     activity input JSON object alongside `query`, `submitted_by`, and `database`.
3. Run `./scripts/test-unit.sh`, `./scripts/test-e2e-local.sh`, and the lifecycle
   command above. Require fresh-execution tests to pass, the N-1 baseline to
   validate, and B1 to fail with the corresponding mismatch in the table.
   A build failure, timeout, or unrelated replay mismatch is not confirmation.
4. Use a clean checkout for each mutation. To reproduce the JOIN comparison,
   repeat only that mutation and the lifecycle at
   `515908008fe582463f87f6d965d88edd495b7521`; expect the lifecycle to pass.

The ordinary, unmodified lifecycle remains in required PR CI. There is no
scheduled mutation workflow or mutation-based release gate. Repeating these
experiments would check the **test harness's sensitivity**, not establish that
an unmodified release is compatible. Repeat a targeted experiment when
materially changing the lifecycle harness, suspended-history fixtures, or
replay validation (including relevant duroxide updates), rather than on a
calendar. Always establish an unmodified passing baseline first. Adapt the
mutation deliberately when testing newer source; these recipes do not promise
stable source anchors.

#### Upgrade & Migration

This change affects test infrastructure only. It adds no extension DDL,
upgrade-script changes or production runtime detection. B1's supported-schema
contract is unchanged. Test-only provider-schema discovery handles the existing
`duroxide` and `_duroxide` layouts; provider migrations during candidate worker
startup remain part of the real binary-upgrade test.

The experiment record and contributor guidance are documentation only and
require no additional migration changes. Reproduction mutations belong only in
disposable checkouts, never in a release.

### Coverage boundaries and known gaps

The real previous-binary lifecycle provides in-flight replay evidence for a
specific, bounded slice. This section is the canonical statement of what that
evidence does and does **not** establish. Open a focused
issue for any row the project intends to close, and link it here.

| Dimension | Current evidence | Not yet covered |
|-----------|------------------|-----------------|
| Real binary history depth | Immediate predecessor (N-1) only | Real histories created by every supported older binary, and multi-hop upgrade chains |
| Behavior-shape breadth | One suspended instance each for `seq`, both `if` branches, `loop`, `break`, `join`, `race` | Nested permutations and suspension at every durable boundary within a shape |
| Node/activity breadth | `df.sql`, signals and timers are exercised | HTTP, multipart, table sinks, `wait_for_schedule`, retry/failure paths, and other specialized activity payloads |
| Schema breadth | The candidate `.so` is checked against every supported schema (Guarantee B1); real old-binary history is N-1 only | Real old-binary histories replayed against every supported schema |
| Provider-version changes | Provider startup and migrations run during the lifecycle | A deliberate old/new `duroxide-pg` provider-version transition matrix (see #398 findings) |
| Packaging and platforms | Source-built tagged predecessor on the CI PostgreSQL and platform | Published package artifacts, other PostgreSQL majors, and other OS/arch combinations |
| Release binding | Unmodified lifecycle in required PR CI | Publication does not require a successful lifecycle run against the exact release commit |
| Compatibility policy | Fail-closed lifecycle; release notes record individual accepted breaks and drain contracts | A centralized inventory of accepted replay breaks, a versioning strategy, and a stated support window |

Closed [PR #398](https://github.com/microsoft/pg_durable/pull/398) is useful
prior art for the historical-chain approach and a measured-incompatibility
inventory, but a closed PR is not a tracker. Surviving gaps belong in this
matrix with issues attached.

## Backward Compatibility Patterns

When a new `.so` must support both old and new schemas (Guarantee B1), code should detect the schema state at runtime. Approaches:

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

### Per-version checklist

Each PR that changes the extension schema or modifies SQL queries in Rust code should:

1. Add the necessary DDL to the upgrade script (`sql/pg_durable--<prev>--<current>.sql`)
2. Ensure the `.so` is backward compatible with **all** current-major schemas starting with v0.2.2 (Guarantee B1)
3. Keep all new DDL — in the Rust install SQL *and* in any new upgrade script — schema-qualified so it passes the pgspot SQL security gate (`scripts/pgspot-gate.sh`): qualify operators as `OPERATOR(pg_catalog.<op>)`, functions/types/objects by schema (e.g. `pg_catalog.now()`), and qualify references inside anonymous `DO` blocks (they run under the session search_path). New upgrade scripts are gated automatically.
4. Add version-specific notes to this document under "Version-Specific Changes" below
5. Run `scripts/test-upgrade.sh` and `scripts/pgspot-gate.sh`

### Preparing for the next version

While the major version is zero, prepare a patch release (for example, v0.2.8 → v0.2.9). For later major versions, prepare a minor release (for example, v1.0.0 → v1.1.0):

1. Create an empty `sql/pg_durable--<previous>--<next>.sql` upgrade script.
2. Bump the version in `Cargo.toml` to `<next>`.
3. Run `scripts/test-upgrade.sh`. Add an install SQL fixture only if the harness cannot reconstruct a version it must test. Do not delete `sql/pg_durable--0.2.2.sql`; it is the reconstruction base for every supported open-source schema. A new major starts a new B1 range: check in an install fixture for the first version of that major, and do not expect B1 to keep testing the previous major.

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

### v0.2.8 → v0.2.9

The post-tag changes in #379, #388, #389, #390, and #380 belong to the 0.2.9
development cycle, not the published v0.2.8 release. Multi-database installation
identity and HTTP endpoint/secret DDL also belong in this unreleased migration;
the shipped 0.2.7 to 0.2.8 script must remain byte-identical.

#### Multi-database installation

- **Local DDL:** [0.2.8 to 0.2.9](../sql/pg_durable--0.2.8--0.2.9.sql)
  adds `df._installation` (singleton UUID, public read-only access) and
  `df.validate_installation()`, then invokes the validator. No provider DDL
  or engine-ID mapping column is added by this migration.
- **Control first:** create control in `pg_durable.database` and wait for the
  new worker before creating satellites. Satellite install/upgrade checks
  control readiness over SQLx; equal extension versions are not required.
- **Worker-owned initialization:** readiness schema version `2` includes
  `_origins`. Provider migrations remain worker-only `ApplyAll` in control.
  Satellites receive local extension-owned `df` objects, not provider objects.
- **B1:** control IDs bypass `df._installation`, preserving operation against
  every supported old control schema (0.2.2 through shipped 0.2.8), without
  `ALTER EXTENSION UPDATE`. A missing `df.duroxide_schema()` retains the legacy
  `duroxide` fallback. Test a current satellite beside each older control.
- **B2/replay:** public IDs stay eight characters. Satellite engine IDs use
  `pgdf-<databaseOID>-<installationUUID>-<localID>`. Routing derives origin
  from activity context, not new recorded payload fields. Existing control
  histories, child composition and `continue_as_new` inputs remain unchanged.
- **Scenario A:** compare fresh and upgraded control schemas like-for-like;
  verify local identity, grants and absence of provider objects on satellites
  separately. Test upgrades from shipped packages as well as reconstructed
  fixtures. The migration must preserve existing ABIs, OIDs and ACLs.

- **Admission implementation:** short same-connection metadata fences and
  autocommit SQL preflights require no additional upgrade DDL or recorded payload
  changes. Control histories still bypass satellite identity checks. Metadata
  validation/access are atomic with installation DDL; side-effect admission and
  remote dispatch are separate boundaries. Normal DROP no longer retains locks
  across arbitrary activities.
- **Metadata trust hardening:** worker satellite connections pin catalog-first
  name resolution at startup. Catalog-only checks attest relation kind,
  extension membership and installer ownership before and after locking, before
  reading identity or graph data. This requires no new SQL objects, grants,
  ownership migration or replay payload changes. Legacy control paths still
  bypass satellite identity requirements. An installation whose metadata or
  `df` namespace has been reassigned to a different owner now fails admission
  rather than being used under worker credentials.
- **Routing and maintenance corrections:** typed retryable routing failures reuse
  the existing transaction-aware graph retry payload. Prompt maintenance paging,
  SQL-filtered legacy candidates and removed-registration cleanup require no new
  extension/provider tables, indexes or migration DDL. Existing `_origins`
  registrations are reused; no instance IDs, activity inputs or replay decisions
  are rewritten. Old control schemas retain their legacy provider resolution.

See [deferred lifetime guarantees](multi-database-installation.md#release-blockers)
for the separate runtime shutdown and server-side cancellation limitations.

#### Typed HTTP endpoints

- Adds composite type `df.http_endpoint(server text, path text)`,
  `df.endpoint(text, text) RETURNS df.http_endpoint`, and typed destination
  variants of both HTTP constructors. The existing TEXT signatures, wrapper
  symbols, OIDs, ACLs, and dependent views are preserved. No implicit TEXT cast
  is installed; TEXT constructor arguments remain raw URLs.
- Endpoint nodes add a fixed `endpoint` server name and use
  `url` for the path template; only these nodes receive the trusted target
  `database` in activity inputs. Existing raw-URL nodes retain their serialized
  inputs and activity names. Both HTTP activities resolve credentials locally,
  using the same endpoint preparation and validation rules.
- Adds the handler-less `pg_durable_fdw` and
  `df.endpoint_option_validator(text[], oid)` in fresh and upgraded schemas.
  FDW `USAGE` is not granted to `PUBLIC` or by `df.grant_usage`; administrators
  delegate creation with a native FDW grant. The catalog resolver uses only
  native catalogs, verifies extension ownership of the wrapper, and reports
  unavailable endpoint support without changing legacy workflow execution.
- Upgrade snapshots include FDW ownership, handler/validator, extension
  membership and ACLs, the composite type's fields, plus endpoint server and mapping metadata. Mapping
  credential values are excluded. B2 exercises delegated server/mapping DDL
  after upgrade.
- Fresh and upgraded schemas revoke PUBLIC EXECUTE on the typed HTTP functions.
  `CREATE OR REPLACE` updates `df.grant_usage` and `df.revoke_usage` to cover URL
  and endpoint requests while retaining the helper OIDs and grants. Existing
  HTTP grants are not automatically copied to new functions: run
  `df.grant_usage(role, include_http => true)` after upgrade to enable endpoints.
- B1 raw HTTP requests keep checking only existing catalog functions; missing
  endpoint functions fail closed. Activity names, scheduling and existing raw
  request bytes are unchanged. B2 verifies typed construction, helper grant/revoke
  coverage, and preservation of the original HTTP OIDs/ACLs.

#### Add explicit secret bindings

- Adds `df.secret(text, text) RETURNS jsonb` in fresh and upgraded schemas and
  accepts individual `"secret.<key>"` user-mapping options. Only explicitly configured nodes
  gain binding/form fields and trusted target-database metadata. Existing HTTP
  signatures, grants and legacy raw-URL activity inputs remain unchanged.
- Named credential lookup uses native catalogs, checks server `USAGE` and reads
  the authenticated caller's mapping in the control database, independently of
  the SQL target. Endpoint and named-binding reads share one read-only consistent
  snapshot and the existing user-connection budget, released before HTTP I/O.
  No additional DDL, grant changes or replay-visible activity inputs are needed
  for catalog snapshot or connection admission. Missing endpoint schema support or named
  keys fails explicitly, without changing legacy requests on older schemas.
- Named credentials use native `ADD`, `SET` and `DROP`; the B2 catalog test
  verifies that these preserve unrelated named values and endpoint-auth options.
- Servers using `auth_scheme 'none'` may omit `base_url` for named-secret storage;
  HTTP endpoint execution still requires a URL. This validator rule needs no
  additional upgrade DDL and leaves existing server definitions valid. The B2
  probe covers URL-less creation and removal of a URL when switching to `none`.

#### Add `df.with_http_options()`
- **DDL change:** Adds `df.with_http_options(fut text, options jsonb) RETURNS text`. The input must be a single `HTTP` or `HTTP_MULTIPART` node. SQL `NULL` and `{}` preserve input bytes; `secret_bindings` and `form_fields` configure references and literal form data. Other values and unsupported keys raise an error.
- **Upgrade script:** [sql/pg_durable--0.2.8--0.2.9.sql](../sql/pg_durable--0.2.8--0.2.9.sql) adds this helper without replacing the existing HTTP functions. The new helper uses the same schema-access and default PUBLIC `EXECUTE` model as other combinators; it does not grant HTTP access.
- **Released-schema compatibility:** This helper landed after the v0.2.8 tag. The 0.2.7 to 0.2.8 script remains identical to the released version; the new DDL belongs in 0.2.8 to 0.2.9 so already-installed 0.2.8 schemas also receive it.
- **Guarantee A considerations:** The added function matches pgrx-generated fresh-install SQL, including argument names, null handling and the `with_http_options_wrapper` C symbol.
- **Guarantee B1 considerations:** The new helper remains absent until `ALTER EXTENSION UPDATE`. The new `.so` exports `with_http_options_wrapper`; existing HTTP function signatures, C symbols, OIDs and ACLs are unchanged.

#### HTTP body policies and table sinks (#376)

- **Upgrade & Migration:** No additional extension DDL or schema detection is
  needed. Body policies use `df.with_http_options`; destination tables are
  caller-provisioned in the workflow's target database. Existing HTTP defaults,
  signatures, grants, and previously persisted response bodies are unchanged.
- **Binary compatibility:** The new `.so` continues to work with supported older
  extension schemas. Sink writes use native PostgreSQL functionality through a
  caller-authenticated connection, without relying on new extension tables.
- **Replay compatibility:** Only new `response: "sink"` nodes gain trusted
  target-database metadata. Older request configurations preserve their activity
  input bytes. Table writes and attempt-key generation happen inside HTTP
  activities; replay uses the recorded reference without fetching the body.
- **Retention:** A sink write and its durable activity completion are not one
  transaction. Each attempt uses a fresh UUID, so a losing attempt cannot
  overwrite a completed attempt's body. A committed but unrecorded attempt can
  leave a row for the application's retention policy to remove.

#### Startup HTTP security and domains (#374, #375)
- **Runtime change (no DDL):** `pg_durable.http_security` is a superuser-only Postmaster enum: `disabled`, `restricted` (default), or development-only `unrestricted`. It replaces the HTTP Cargo features. `pg_durable.http_allowed_domains` is a Postmaster string GUC that replaces the complete domain allow-list in restricted mode, defaulting to Azure service subdomains and `api.github.com`.
- **Configuration migration:** The default preserves the former Azure/GitHub policy. Installations previously built without HTTP support must explicitly select `disabled` before restarting with the new binary to keep HTTP blocked. Test domains such as `httpbingo.org` require explicit allow-list configuration. An explicit list replaces all defaults; an empty list denies all domains in restricted mode. Malformed domain lists are rejected, including at server startup. See [Upgrade & Migration](http-security.md#upgrade--migration).
- **Guarantee A/B2 considerations:** No upgrade-script DDL, schema changes, or data migration. Existing graphs, activity names, and serialized activity inputs are unchanged.
- **Guarantee B1 considerations:** The new `.so` works against all previous supported schemas without `ALTER EXTENSION UPDATE` or runtime schema detection. The policy is read from the GUC, not extension tables.
- **Replay compatibility:** The policy is evaluated only when an HTTP activity executes, not by orchestration code. Pending requests and retries use the new mode and list after restart; already-recorded activity results replay normally.

#### Shared HTTP client (#379)

- **Runtime change (no DDL):** HTTP and multipart activities reuse one client and
  connection pool per background worker process. Timeouts remain per request.
  Client construction is lazy; construction errors are cached until the worker
  restarts, while request-time failures do not invalidate the client. See
  [Shared connection pool](http-security.md#63-shared-connection-pool).
- **Guarantee B1 considerations:** The change applies when the new binary is
  loaded, including against older supported schemas. It uses the existing HTTP
  configuration and privilege checks; no schema-version detection is needed.
- **Guarantee A/B2 and replay considerations:** No upgrade DDL or persisted-data
  migration is needed. Activity names, serialized inputs, and orchestration
  scheduling are unchanged; the client cache is confined to activity execution.

#### Other post-tag changes

- **Dependencies (#390):** `uuid` 1.26.1 and `reqwest` 0.13.5 are binary updates, not v0.2.8 dependencies. `reqwest` uses `base64` 0.23.1, while pg_durable's direct dependency remains on 0.22.1. The `duroxide`/`duroxide-pg` pair is unchanged.
- **Test and release tooling (#388, #389):** shared E2E HTTP grants are restored
  after lifecycle tests, and release-triggered Docker publication waits for
  package assets. Neither change modifies the installed extension schema.
- **Upgrade considerations:** These changes require no upgrade DDL, persisted
  data migration, or runtime schema detection.

<a id="028"></a>

### v0.2.7 → v0.2.8

#### Loop API and lifetime

- `sql/pg_durable--0.2.7--0.2.8.sql` renames `df.loop(text, text)` to
  `df._loop_legacy(text, text)`, preserving its function OID and dependent
  objects, then creates the single public
  `df.loop(text, text DEFAULT NULL, boolean DEFAULT false)` signature.
  `_loop_legacy` is an internal upgrade-compatibility object, not a user-facing
  alternative.
- For Guarantee B1, the new `.so` retains `loop_fn_wrapper`, so every supported
  schema that has not run `ALTER EXTENSION UPDATE` can continue calling its
  cataloged `df.loop(text, text)` function safely.
- For Guarantee A, fresh installs and upgraded schemas both contain the unified
  public signature and the internal `_loop_legacy` object, so their schema
  snapshots remain equal while upgrade dependencies stay attached to the
  renamed function OID.
- Existing LOOP graphs have no `continue_on_failure` key and remain inline and
  fail-fast. Only newly constructed opted-in loops schedule an iteration child.
- For opted-in conditional loops, a successful body is followed by condition
  evaluation; a consumed typed body activity failure skips the condition and
  starts the next iteration. All errors returned by body SQL, HTTP, and
  multipart activities are consumable. Condition failures, malformed
  graph/protocol data, unrecognized child errors, child-ID collisions, and
  orchestration/runtime failures remain fatal.
- Raises the loop backstop for all loops from 100,000 to 8,388,608 (`2^23`),
  which is about 80 years at five-minute ticks.
- Replay is unchanged before iteration 100,000. At the old boundary, a history
  that recorded the previous terminal-failure path cannot replay under the new
  binary, which continues toward the higher backstop instead. Drain such
  long-running loops before upgrade when continuity is required.

### v0.2.6 → v0.2.7

#### Transaction-aware graph admission
- **Runtime change (no DDL):** New caller-mode starts include the top-level PostgreSQL transaction ID in the root orchestration input. A versioned single-shot activity probes graph visibility and `pg_xact_status()`; the deterministic orchestration waits with capped backoff and periodically `continue_as_new`s to bound replay history.
- **Rollback behavior:** A whole-transaction abort fails the df-less engine record without executing SQL. A committed origin transaction with no visible graph is reported distinctly as a likely savepoint rollback. Transient graph/pool errors return a retry state rather than terminally failing the orchestration.
- **Replay compatibility:** Historical `FunctionInput` payloads deserialize with no origin transaction ID and schedule the original `pg_durable::activity::load-function-graph` activity with the same raw instance-ID input. Existing in-flight history therefore retains its operation name, order, and input bytes. The new activity name and input shape are used only for starts created by the new binary.
- **Guarantee A/B2 considerations:** No extension schema or persisted `df` data changes; no upgrade DDL is required.
- **Guarantee B1 considerations:** The new binary uses PostgreSQL's built-in `pg_current_xact_id()` / `pg_xact_status()` functions and existing `df.instances` / `df.nodes` columns, all available in every schema starting with v0.2.2. New starts work against old extension schemas without runtime schema detection.

### v0.2.5 → v0.2.6

#### Remove `df.ensure_durofut()`
- **DDL change:** Fresh installs no longer create the undocumented `df.ensure_durofut(text)` PL/pgSQL helper. `df.if_then_op()` now stores its condition and then-branch operands as text in the partial marker; `df.if_else_op()` extracts those operands and passes all three directly to the Rust-backed `df.if()`, which already performs Durofut normalization.
- **Upgrade script:** `sql/pg_durable--0.2.5--0.2.6.sql` replaces both operator helpers before dropping `df.ensure_durofut(text)` with `RESTRICT`. The new `df.if_else_op()` uses JSON text extraction, which accepts both new string-valued partial markers and object-valued markers emitted before the upgrade. `RESTRICT` deliberately aborts rather than silently removing a customer-owned object that depends on the undocumented helper.
- **Behavior change:** The operators now classify operands exactly like `df.if()`. In particular, JSON with an unknown `node_type` is treated as plain SQL during composition instead of being rejected by the former PL/pgSQL helper.
- **Guarantee A considerations:** Fresh and upgraded schemas both omit `df.ensure_durofut(text)` and expose byte-equivalent `df.if_then_op()` / `df.if_else_op()` definitions, including their pinned `search_path`.
- **Guarantee B1 considerations:** A binary-only update against any supported pre-0.2.6 schema leaves the cataloged PL/pgSQL helper and old operator bodies intact. They continue calling the unchanged `df.sql()` and `df.if()` C bindings; no binary symbol is removed because `df.ensure_durofut()` was not C-backed. B1 explicitly composes a `?>` / `!>` expression against every supported old schema.
- **Guarantee B2 considerations:** No durable data or graph wire format changes. A partial `?>` value materialized before `ALTER EXTENSION` can still be completed with `!>` afterward. The upgrade can fail only when a customer-owned catalog object depends directly on `df.ensure_durofut(text)`; the operator helpers themselves are replaced before the drop.

### v0.2.4 → v0.2.5

#### Loop and sub-orchestration replay compatibility
- **Runtime change (no DDL):** Non-root `df.loop()` nodes run as child sub-orchestrations, replay-recorded result/variable maps serialize in canonical key order, and root/non-root loops share body/condition policy. A loop is now hosted by the same `execute-subtree` orchestration that runs JOIN/RACE branches. The function graph is loaded from `df.nodes` exactly once per instance and then carried inline through every child input and every `continue_as_new` generation, so no generation re-reads the graph. `status_details` already covers the loop node stamps, so the upgrade script adds no schema object for this change.
- **Replay compatibility:** duroxide matches recorded inputs, explicit child instance ids, and orchestration scheduling by exact equality. Two distinct breaks apply:
  - **Every in-flight JOIN (`&`) or RACE (`|`) branch fails**, unconditionally. A branch scheduled under `<= 0.2.4` recorded an `execute-subtree` input with only `graph`, `node_id`, and `results`; the 0.2.5 envelope also carries `instance_id`, `vars`, `label`, and `iteration`, so the old shape no longer matches. This is not limited to workflows carrying multiple variables or named results.
  - **In-flight root and non-root `df.loop()` instances may fail** with a nondeterminism error, because loop scheduling and recorded inputs both changed.

  Histories with neither a parallel branch nor a loop resume normally.
- **Failure handling:** duroxide fails closed rather than continuing with a changed schedule. The corresponding `df.instances` row may remain `pending` or `running` because replay can abort before pg_durable records its normal failure status.
- **Upgrade choice:** Operators that require in-flight continuity should quiesce and drain before upgrading. Operators that accept recreating affected work can upgrade directly, then inspect and cancel any stale instances.
- **Guarantee B1:** The 0.2.5 `.so` still runs against schemas without `status_details`; the writer detects the absent column and uses the legacy unfenced write. Existing SQL remains valid, but loop-node status is best-effort until the schema upgrade because the writer set is wider.

#### Add `df.http_multipart()` for multipart/form-data uploads
- **DDL change (df schema):** Adds a new node type `HTTP_MULTIPART` and a new `#[pg_extern(schema = "df")]` function `df.http_multipart(text, text, jsonb, jsonb, integer)`. The upgrade script `sql/pg_durable--0.2.4--0.2.5.sql` hand-writes the `CREATE FUNCTION ... LANGUAGE c AS 'MODULE_PATHNAME', 'http_multipart_wrapper'` (pgrx emits it for fresh installs from `src/dsl.rs`), re-adds the `nodes_node_type_chk` / `nodes_structure_chk` constraints and `df.ensure_durofut()` validator with `HTTP_MULTIPART` admitted, and re-emits `df.grant_usage()` / `df.revoke_usage()` so they GRANT/REVOKE `df.http_multipart()` alongside `df.http()`. The signature `df.grant_usage(text, boolean, boolean)` is unchanged.
- **Grant gating:** `df.http_multipart()` rides on the existing `include_http => true` flag (HTTP egress is treated as one privilege). `REVOKE EXECUTE ... FROM PUBLIC` is added for `df.http_multipart()` at install/upgrade time, matching `df.http()`.
- **Guarantee B1 considerations:** The new `.so` adds the `http_multipart_wrapper` C symbol and a new activity `execute_multipart`. Pre-0.2.5 schemas have no catalog entry for `df.http_multipart` and no `HTTP_MULTIPART` rows, so a binary-only swap (no `ALTER EXTENSION UPDATE`) changes nothing for existing workflows — the new function and node type are simply absent until the customer upgrades. No existing symbol is removed or renamed.

#### Add `transaction_mode` to `df.start()`
- **DDL change (df schema):** Replaces `df.start(text, text, text)` with `df.start(text, text, text, text)`, bound to the new C symbol `start_v2_wrapper`. The new trailing `transaction_mode` argument defaults to `'caller'` (join the caller's transaction, the historical behaviour); `'new'` persists and enqueues the durable function on a *separate* PostgreSQL session so it commits independently and survives a rollback of the caller's transaction. This provides the rollback-survival outcome of an Oracle autonomous transaction for asynchronously started work, but the workflow completes later and its execution errors do not propagate through `df.start()`. Nothing about the started function changes; only the commit boundary of the start itself does.
- **Upgrade script:** `sql/pg_durable--0.2.4--0.2.5.sql` runs `DROP FUNCTION IF EXISTS df.start(text, text, text)` followed by `CREATE FUNCTION df.start(...)` with the four-argument signature, copied verbatim from the pgrx-generated fresh-install DDL (same argument list, defaults, `RETURNS TEXT`, `LANGUAGE c`, and wrapper symbol). The drop is required, not cosmetic: both signatures default `label` and `database`, so a three-argument call such as `df.start(fut, label, database)` would match both and PostgreSQL would raise `function ... is not unique`. New `df.*` functions retain PostgreSQL's default PUBLIC `EXECUTE`, gated by `USAGE ON SCHEMA df`, so no explicit `GRANT` is needed.
- **Guarantee A considerations:** A fresh install exposes exactly one `df.start`, the four-argument one — `src/dsl.rs` keeps a three-argument Rust `start()` for binary compatibility but marks it `#[pg_extern(sql = false)]`, so it contributes no DDL. The upgrade script's drop-then-create reaches the same single-overload end state, so the Guarantee A snapshot matches.
- **Guarantee B1 considerations:** The `start_wrapper` symbol is deliberately preserved in the binary by that `sql = false` Rust function, which still takes exactly three arguments and delegates with `transaction_mode = 'caller'`. Pre-0.2.5 schemas (0.2.2, 0.2.3, 0.2.4) declare `df.start(text, text, text)` against `start_wrapper` and keep resolving to it with unchanged behaviour; they simply do not expose `transaction_mode`. Had the four-argument Rust function reused `start_wrapper`, those schemas would have invoked it with a three-argument `FunctionCallInfo`. `transaction_mode => 'new'` reads/writes only columns (`df.instances`, `df.nodes`) that exist in every shipped schema starting with v0.2.2 — and it does so by calling `df.start()` with three positional arguments on the separate session, which resolves on old and new schemas alike, so it inherits whatever legacy-schema handling `df.start()` already performs.
- **Guarantee B2 considerations:** No data migration; instances created before the upgrade are unaffected.

### v0.2.3 → v0.2.4

#### Simplify `df.grant_usage()` — drop the explicit function allowlist
- **DDL change (df schema):** `df.grant_usage()` no longer loops over a hard-coded `func_sigs` array issuing `GRANT EXECUTE` per function. Fresh installs (`src/lib.rs`) and the upgrade script (`sql/pg_durable--0.2.3--0.2.4.sql`) both `CREATE OR REPLACE` the function with a body that grants `USAGE ON SCHEMA df` plus the table privileges, and conditionally grants `df.http()` / the admin helpers. The signature `df.grant_usage(text, boolean, boolean)` is unchanged.
- **DDL change (df schema):** `df.revoke_usage()` is made symmetric with the new `grant_usage()`. It no longer loops over every `df.*` function in `pg_proc` issuing `REVOKE EXECUTE` (which, post-simplification, only produced "no privileges could be revoked" warnings since ordinary functions are never granted per-function EXECUTE). The new body revokes only what `grant_usage()` grants: schema `USAGE`, EXECUTE on the sensitive functions (`df.http`, `df.grant_usage`, `df.revoke_usage`), and the table privileges. The signature `df.revoke_usage(text)` is unchanged.
- **Rationale:** The ordinary `df.*` functions retain PostgreSQL's default PUBLIC `EXECUTE`, so schema `USAGE` is the real access gate; the per-function grants/revokes were redundant. The sensitive functions have PUBLIC `EXECUTE` revoked at install time and were never in the allowlist, so their protection is unchanged.
- **Behavioral note:** A newly added `df.*` function is now callable by any role with schema `USAGE` by default. To keep a future function private, `REVOKE EXECUTE ... FROM PUBLIC` at install time and grant it explicitly in `df.grant_usage()`.
- **Legacy cleanup caveat:** A role that was granted under the *old* `grant_usage()` (explicit per-function EXECUTE) and is later revoked under the new `revoke_usage()` may retain inert EXECUTE entries on ordinary functions. These are harmless — revoking schema `USAGE` fully locks the role out — and clear on the next drop/regrant cycle.
- **Guarantee A considerations:** Signatures are identical on the fresh-install and upgrade paths (only the bodies differ), so the function-signature equivalence contract passes.
- **Guarantee B1/B2 considerations:** No schema/data migration and no new objects. The replaced bodies work against the existing schema and change no privileges already granted.

#### Rename `df.wait_for_completion()` to `df.await_instance()`
- **DDL change (df schema):** Adds `df.await_instance(text, integer)` as the canonical C binding for the helper formerly exposed as `df.wait_for_completion(text, integer)`. The old SQL function remains present and the new `.so` continues exporting `wait_for_completion_wrapper` as a shim, so existing customer scripts keep working.
- **Grant behavior:** No explicit grant migration is required. PostgreSQL grants `EXECUTE` on newly created functions to `PUBLIC` by default, and `df.await_instance` is not a sensitive helper whose default PUBLIC grant is revoked.
- **Guarantee A considerations:** Fresh installs and upgraded schemas must both expose `df.await_instance(text, integer)` and `df.wait_for_completion(text, integer)`.
- **Guarantee B1 considerations:** The new `.so` remains compatible with v0.2.3 schemas that have not run `ALTER EXTENSION UPDATE`: existing catalog entries still bind `df.wait_for_completion` to `wait_for_completion_wrapper`, which is retained as a Rust shim to `df.await_instance`.
- **Guarantee B2 considerations:** No data migration. Existing instances are unaffected; the upgrade only adds a SQL function binding.

#### #110 Remove df.debug_connection() (reclassified non-security cleanup)
- **DDL change (df schema):** The upgrade script `sql/pg_durable--0.2.3--0.2.4.sql` runs `DROP FUNCTION IF EXISTS df.debug_connection();`. Fresh v0.2.4 installs never create the function: its `#[pg_extern]` in `src/dsl.rs` is annotated `#[pg_extern(sql = false)]`, so pgrx emits no `CREATE FUNCTION` for it (the generated schema records `-- Skipped due to #[pgrx(sql = false)]`). The function returned the worker connection string (no credential) and is dropped as surface-reduction, because the worker role is already exposed to any role via native PostgreSQL channels — the world-readable `pg_durable.worker_role` GUC and `pg_stat_activity.usename` (see security-review item I-6); the remaining fields (database, host/port, schema) are connection-topology metadata, not secrets (the host comes from `PGHOST`, defaulting to loopback). Reclassified from security to cleanup; see issue #110.
- **Interaction with the `df.grant_usage()` simplification:** Earlier in this release `df.grant_usage()` carried `'df.debug_connection()'` in its explicit per-function allowlist (`func_sigs`), so dropping the function would have required editing that allowlist. The grant_usage simplification above (#242) removed the allowlist entirely in this same release, so the upgrade no longer needs any `grant_usage` change to account for the removed function — it simply drops `df.debug_connection()`.
- **Guarantee A considerations:** `df.debug_connection()` is absent on both the fresh-install and upgrade paths after this release, keeping the `df` schema shapes equivalent.
- **Guarantee B1 considerations (symbol retention):** Removing `df.debug_connection()` from the SQL surface required care to preserve binary backward compatibility. Pre-0.2.4 schemas (0.2.2, 0.2.3) define the function as `AS 'MODULE_PATHNAME','debug_connection_wrapper'`, and PostgreSQL validates that C symbol at `CREATE FUNCTION` time (`check_function_bodies = on` by default). Fully deleting the `#[pg_extern]` would drop the `debug_connection_wrapper` symbol from the `.so`, so the new binary could no longer instantiate any previously shipped schema — failing Guarantee B1. The fix is `#[pg_extern(sql = false)]`: pgrx still compiles the C wrapper symbol into the binary (verified with `nm`) but emits no SQL, so old schemas keep resolving the symbol while fresh installs omit the function. The retained Rust body still returns the same non-secret connection string, so a binary-only swap (no `ALTER EXTENSION UPDATE`) leaves any pre-existing `df.debug_connection()` working until the customer upgrades. Retain the shim while any supported schema references the symbol.
- **Guarantee B2 considerations:** No data migration. Existing instances, nodes, and vars are untouched. After `ALTER EXTENSION UPDATE`, `df.debug_connection()` no longer exists; the simplified `df.grant_usage()` never references it.
- **Dependent-object note:** The upgrade runs `DROP FUNCTION IF EXISTS df.debug_connection()` with PostgreSQL's default `RESTRICT` behavior. If a customer created their own object that depends on the function (e.g. a view or SQL function that calls it), `ALTER EXTENSION UPDATE` aborts with a dependency error and the customer must drop or repoint that object first. This is intentional for a removed debug helper — the script deliberately does not `CASCADE`, to avoid silently dropping customer-owned objects. The fresh-install (`tests/e2e/sql/18_delegated_grants.sql`) and upgrade (`scripts/test-upgrade.sh` B2 grant test) suites assert the function is absent and that `df.grant_usage()` still works after the drop.

#### #129 Promote df.nodes to a composite primary key (instance_id, id)
- **DDL change (df schema):** `df.nodes` previously had a single-column `PRIMARY KEY (id)` plus a separate composite `UNIQUE (instance_id, id)` (`nodes_instance_node_key`). The single-column key forced the random 8-hex node ID to be globally unique, so it was the sole cross-instance collision guard. Node IDs only need to be unique per instance, so the composite key is promoted to be the primary key and the global single-column key is dropped. Fresh installs (`src/lib.rs`) declare `id`/`instance_id` as `NOT NULL` and create `nodes_pkey PRIMARY KEY (instance_id, id)` directly; the upgrade script (`sql/pg_durable--0.2.3--0.2.4.sql`) restructures the existing keys in place. The three same-instance foreign keys (`nodes_left_node_same_instance_fkey`, `nodes_right_node_same_instance_fkey`, `instances_root_node_same_instance_fkey`) reference the composite key, so the upgrade drops them first, swaps the keys, then recreates them with their original `DEFERRABLE INITIALLY DEFERRED NOT VALID` definition. `nodes_instance_identity_fkey` references `df.instances`, not `df.nodes`, and is left untouched. IDs remain `VARCHAR(8)` HEX.
- **Companion runtime change (#129):** `df.start()` now reserves the instance ID by attempting the insert itself — `INSERT INTO df.instances ... ON CONFLICT (id) DO NOTHING RETURNING id` — and re-rolling the random 8-hex ID when zero rows come back (a collision); there is no separate `SELECT EXISTS` pre-check. Because `ON CONFLICT` arbitration runs against the global `id` index *below* row-level security, this also re-rolls on collisions with another role's instance that the caller cannot `SELECT`. Node inserts use the same pattern against the composite key — `INSERT INTO df.nodes ... ON CONFLICT (instance_id, id) DO NOTHING RETURNING id` — re-rolling on a per-instance collision. `df.start()` pre-generates the root node's ID and reserves the instance with `root_node` set to that value; `insert_nodes` then inserts the root node with the same forced ID. The same-instance FK on `root_node` is `DEFERRABLE INITIALLY DEFERRED`, so it is checked only at commit, by which point the referenced root node row exists — no post-insert `UPDATE` is needed (and `df.grant_usage()` deliberately grants `UPDATE (status, updated_at)` but not `UPDATE (root_node)` on `df.instances`, so an update path would fail for ordinary df roles). The `update-node-status` activity and `df.result()` now scope their `df.nodes` lookups by `instance_id` in addition to `id`, and the activity asserts the scoped `UPDATE` affects exactly one row. `instance_id` is a **required** field of the activity input — node IDs are unique only per instance, so updating by node ID alone could silently write to a *different* instance's node. There is deliberately no node-ID-only fallback.
- **Design note — collision handling for both ID spaces (#129):** Both IDs stay 8-hex `VARCHAR(8)` (the requested minimal change) and re-roll on conflict via `INSERT ... ON CONFLICT DO NOTHING RETURNING id`; the mechanism is symmetric and only the conflict target differs. `df.instances.id` is a *global* identifier with no natural scoping column, so its reserve arbitrates on the single-column primary key (`id`). `df.nodes.id` is always used together with its owning `instance_id`, so promoting the pre-existing `(instance_id, id)` UNIQUE to the primary key lets node inserts arbitrate per instance — the random node ID never has to be globally unique. Using `ON CONFLICT DO NOTHING` rather than a `SELECT EXISTS` pre-check closes a TOCTOU window and, for instances, an RLS blind spot: the pre-check only saw the caller's own rows, whereas `ON CONFLICT` detects a clash with any role's row at the index level. The retry bound (`MAX_ID_ATTEMPTS`) surfaces a hard error on exhaustion rather than returning an unverified ID.
- **In-flight orchestration compatibility (#129 — breaking for in-flight work):** Adding `instance_id` to the `update-node-status` activity input changes the input string that duroxide records in orchestration history. duroxide validates activity inputs by exact equality during replay, so any orchestration that was **in flight across the binary upgrade** (it recorded the old `{node_id, status}` input under 0.2.3) fails deterministic replay under the new `.so` and cannot complete. This is an intentional break of the general "in-flight work completes after the swap" expectation (the Guarantee B1 and B2 "In-flight work" rows above) **for this release**, and follows the same drain-or-recreate precedent as the v0.1.0 → v0.1.1 execution-model change (Guarantee B2, below): **operators must drain in-flight instances to a terminal state before deploying 0.2.4**, or cancel and recreate any that cannot drain. Instances that completed before the upgrade are terminal and unaffected; instances started after the upgrade carry `instance_id` from their first node update and replay normally.
- **Guarantee A considerations:** Fresh-install and upgraded schemas must both end with exactly one identity constraint on `df.nodes`: `nodes_pkey PRIMARY KEY (instance_id, id)` (constraint key order `instance_id, id`), its matching unique index `nodes_pkey ON df.nodes USING btree (instance_id, id)`, and no surviving `nodes_instance_node_key` constraint or index. The recreated foreign keys keep identical names and referencing columns, so the constraint/index snapshot diff is empty.
- **Guarantee B1 considerations:** The schema change is to table constraints only; the new `.so` issues the same column lists against `df.nodes`/`df.instances`, now with `ON CONFLICT ... DO NOTHING RETURNING id`. The instance reserve arbitrates on `id` (the primary key in both old and new schemas) and the node insert arbitrates on `(instance_id, id)` — an index that exists in both the pre-0.2.4 schema (the `nodes_instance_node_key` composite UNIQUE) and the new schema (the composite primary key) — so both statements stay valid against a schema that has not run `ALTER EXTENSION UPDATE`. The pre-generated-`root_id` reserve is also old-schema-safe: `instances_root_node_same_instance_fkey` is `DEFERRABLE INITIALLY DEFERRED` in every shipped schema, so `root_node` is not checked until commit, by which point the forced-ID root node row has been inserted within the same transaction. No `UPDATE df.instances` is issued, so the change relies only on the `INSERT (..., root_node, ...)` privilege every shipped `df.grant_usage()` already grants, not on any `UPDATE (root_node)` grant. One benign residual exists against the *old* schema only: a node ID that is globally duplicated but per-instance-unique would clash with the surviving single-column `nodes_pkey (id)`, which `ON CONFLICT (instance_id, id)` does not arbitrate, so it raises just as it did before this change — astronomically rare, strictly no worse than prior behavior, and eliminated once `ALTER EXTENSION UPDATE` swaps in the composite primary key. This covers **schema** compatibility only — the SQL stays valid against the old table shape. The separate in-flight *replay* break introduced by the changed activity-input shape is documented under "In-flight orchestration compatibility" above and requires draining before upgrade.
- **Guarantee B2 considerations:** `ADD PRIMARY KEY (instance_id, id)` sets `NOT NULL` on both columns and builds a unique index over existing rows. `id` was already the old primary key (implicitly `NOT NULL`). `instance_id` carries a `nodes_instance_id_present_chk CHECK (instance_id IS NOT NULL)` constraint, but it was added `NOT VALID`, so it only guarantees rows written on 0.2.2+; in the unlikely event a database still holds pre-0.2.2 node rows with a NULL `instance_id`, the `ADD PRIMARY KEY` (and the explicit `ALTER COLUMN instance_id SET NOT NULL` that precedes it) will abort and the operator must backfill or remove those rows before retrying the upgrade. On an empty database the restructure is metadata-only; on a populated one PostgreSQL rebuilds the `df.nodes` primary-key index in place. Because `ADD PRIMARY KEY` / `ALTER COLUMN ... SET NOT NULL` take an `ACCESS EXCLUSIVE` lock on `df.nodes` and rebuild the index, on a large `df.nodes` the upgrade blocks concurrent access for a period that scales with the table's size. Consider `SET lock_timeout` for the session so the migration fails fast instead of queuing behind (or stalling in front of) long-running transactions. Combined with the in-flight replay break noted above, the recommended upgrade sequence is: stop new `df.start()` calls, drain or cancel in-flight instances, then run the upgrade.

#### Indexes on df.instances for ordered/paginated listing (issues #167/#87/#146)
- **DDL change (df schema):** `df.list_instances()` lists rows newest-first (`ORDER BY created_at DESC`), optionally filtered by status. The pre-0.2.4 `idx_instances_status(status)` covered only the status equality, so a status-filtered listing still required a sort and an unfiltered listing had no supporting index. Fresh installs (`src/lib.rs`) now create `idx_instances_status(status, created_at DESC, id)`, a new `idx_instances_created_at(created_at DESC, id)`, and a partial `idx_instances_label(label, created_at DESC, id) WHERE label IS NOT NULL` for the label-filtered path (issue #87). The upgrade script `sql/pg_durable--0.2.3--0.2.4.sql` drops any existing copies (`DROP INDEX IF EXISTS`) then recreates all three indexes with the same definitions. The trailing `id` is the keyset tiebreaker for `df.list_instances` (`ORDER BY created_at DESC, id ASC`). At the time these indexes were added `df.list_instances()` did not yet order by `id`; the **label filter, keyset pagination, timestamps** change below realizes that order, and these indexes then serve both the sort and the `after_cursor` range predicate as an index scan.
- **Design note (RLS):** `df.instances` has a row-level-security policy (`instances_user_isolation`) filtering `submitted_by = current_user::regrole`, so a per-user index leading with `submitted_by` would be more selective for an individual session. The `created_at`-leading design is intentional: it is optimal for the admin / external-client global-listing path (#146) that reads across submitters, and it still removes the per-query sort for the common case. A `submitted_by`-leading refinement can be revisited if profiling shows the per-user path dominates.
- **Guarantee A considerations:** The upgrade script recreates the indexes with column lists, partial predicate, and `DESC`/tiebreaker ordering identical to the fresh-install DDL, so `pg_get_indexdef()` for `idx_instances_status`, `idx_instances_created_at`, and `idx_instances_label` is byte-identical on both paths and the Guarantee A snapshot matches.
- **Guarantee B1 considerations:** The new `.so` works against all previous schemas. The `df.list_instances()` queries (`ORDER BY created_at DESC LIMIT`, optionally `WHERE status = $1`) reference only the `created_at`/`status` columns, which exist in every shipped `df.instances` schema; against a schema that has not run `ALTER EXTENSION UPDATE` the queries stay valid and correct — they simply fall back to a sort without the new index until the upgrade is applied. This is a performance-only change with no correctness impact.
- **Guarantee B2 considerations:** No data migration. `DROP INDEX` / `CREATE INDEX` rebuild access-path metadata only; row data is untouched. The `CREATE INDEX` statements take a `SHARE` lock on `df.instances` while they build, so on a large table the upgrade can block concurrent writes until the indexes are built.

#### `df.list_instances()` — label filter, keyset pagination, timestamps (issues #87/#146)
- **DDL change (df schema):** This adds a **new overload** of `df.list_instances` rather than changing the existing one. The prior two-argument function (`df.list_instances(status_filter text, limit_count integer)` → 6 columns) is left in place **unchanged**. A new four-argument overload `df.list_instances(status_filter text, limit_count int, label_filter text, after_cursor text DEFAULT NULL)` is added, returning three extra trailing columns (`created_at`, `completed_at`, `next_cursor`) and backed by a distinct symbol (`list_instances_paged_wrapper`). Only `after_cursor` defaults, giving the overload a minimum arity of 3; the basic function matches calls of arity 0–2 and the paginated one arity 3–4, so the two never overlap and PostgreSQL never reports "function is not unique". The paginated overload orders rows `created_at DESC, id ASC`, served as an index scan by the `(created_at DESC, id)` indexes added in the previous subsection. The upgrade script `sql/pg_durable--0.2.3--0.2.4.sql` adds only the new overload (no `DROP FUNCTION`).
- **Why an overload instead of changing the function (Guarantee B1):** Changing the existing two-argument/6-column function in place would break Guarantee B1. A customer running 0.2.2/0.2.3 who loads the new `.so` but never runs `ALTER EXTENSION UPDATE` still has the old 6-column SQL declaration bound to the `list_instances_wrapper` symbol. If the new `.so` implemented that symbol with a 9-column shape, the returned tuple would not match the catalog declaration and calls would error. Keeping the old function frozen (same 6-column shape, same `list_instances_wrapper` symbol) preserves that contract; the new capability ships as a separate function/symbol. This mirrors the repo's `wait_for_completion`→`await_instance` precedent of keeping both functions rather than mutating one.
- **Design note (cursor):** `after_cursor` is an opaque keyset token. Each page carries `next_cursor` (identical on every row of the page, `NULL` on the final page); the client passes it back as `after_cursor` to fetch the next page. The cursor encodes `(created_at, id)` of the last row, so pagination is deterministic and seek-based (no `OFFSET`). `next_cursor` is computed over `df.instances` (RLS-filtered) independently of the per-row execution-metadata lookup, so it advances correctly even when a row is transiently skipped; a malformed cursor raises an error rather than silently restarting.
- **Guarantee A considerations:** The `CREATE FUNCTION df."list_instances"(...)` block in the upgrade script is the pgrx-generated fresh-install DDL for the new overload (`src/monitoring.rs`) copied verbatim — same argument list, defaults, and `RETURNS TABLE` column list/types. The old two-argument function is unchanged from the 0.2.3 base install. So on both paths the catalog ends with exactly the same two `df.list_instances` overloads, and the Guarantee A snapshot matches a fresh 0.2.4 install.
- **Guarantee B1 considerations:** Both overloads of the new `.so`'s `list_instances` read only columns that exist in every shipped `df.instances` schema (`id`, `label`, `status`, `created_at`, `completed_at`), so they run correctly against a pre-0.2.4 schema that has not run `ALTER EXTENSION UPDATE` — the paginated path simply falls back to a sort without the `(created_at DESC, id)` index. Crucially, the old catalog still binds existing 0/1/2-argument callers to `list_instances_wrapper`, which the new `.so` still exports with the original 6-column shape, so those calls keep working unchanged.
- **Guarantee B2 considerations:** No data migration. The `CREATE FUNCTION` adds catalog metadata only; `df.instances` rows are untouched. The new `created_at`/`completed_at` result columns are read from columns that already exist and are already populated on every prior install.
- **Dependent-object note:** Because the upgrade only adds a function (no `DROP FUNCTION`), no customer-owned object that depends on the existing two-argument `df.list_instances` is affected — there is nothing to drop or repoint.

#### `pg_durable.list_instances_max_limit` GUC — page-size cap is now a loud error (issue #146)
- **DDL change:** None. The cap is enforced entirely in the `.so`: a new `pg_durable.list_instances_max_limit` GUC (`SUSET` context, default `1000`, range `1`–`1000000`) is registered in `_PG_init` (`src/lib.rs`) and read on the `df.list_instances()` query path (`src/monitoring.rs`). There are no SQL function, table, or index changes, so this change adds no upgrade-script DDL and has no Guarantee A snapshot impact.
- **Behavior change:** Both `df.list_instances()` overloads previously truncated `limit_count` silently to a fixed 10000. They now raise an error when `limit_count` exceeds the GUC (default `1000`), so an over-cap request fails fast instead of returning a silently short page. This is a runtime behavior change to a function that shipped in 0.2.2/0.2.3; it is recorded in `CHANGELOG.md` under the unreleased 0.2.4 changeset.
- **Guarantee A considerations:** No schema changes — the `df` schema equivalence contract is unchanged.
- **Guarantee B1 considerations:** The new `.so` works against all previous schemas. The guard runs before any SQL is issued and reads no catalog or table state — it only compares the caller's `limit_count` against an in-memory GUC value — so it is correct against a pre-0.2.4 schema that has not run `ALTER EXTENSION UPDATE`. The only visible difference against an old schema is the intended one: a large `limit_count` now errors instead of being silently capped at 10000.
- **Guarantee B2 considerations:** No data migration. The GUC has no effect on schema shape or existing data.

### v0.2.2 → v0.2.3

#### Rename duroxide provider schema to `_duroxide` for fresh installs
- **DDL change (df schema):** Adds `df.duroxide_schema()`, an `IMMUTABLE`/`PARALLEL SAFE` SQL function that returns the name of the schema holding the duroxide provider objects. Fresh 0.2.3 installs create the function (in `src/lib.rs`) returning `'_duroxide'`; the upgrade script `sql/pg_durable--0.2.2--0.2.3.sql` creates the same function returning `'duroxide'` so pre-existing installs keep using the legacy schema. Both bodies set `search_path = pg_catalog, pg_temp` to satisfy the pgspot gate.
- **DDL change (provider schema):** Fresh installs now run `CREATE SCHEMA _duroxide` (was `CREATE SCHEMA duroxide`). The upgrade script does **not** rename, drop, or move the existing `duroxide` schema — renaming an in-use provider schema would orphan the BGW's durable state. Upgraded installs therefore continue to use `duroxide`.
- **Runtime selection:** Backend sessions resolve the provider schema once per session via `backend_duroxide_schema()` (cached in a `OnceLock`); the BGW resolves it once per epoch via `resolve_duroxide_schema_pool()` (re-resolved after every CREATE EXTENSION so drop+recreate with a different schema version is handled). Both call `df.duroxide_schema()` and fall back to `'duroxide'` (`LEGACY_DUROXIDE_SCHEMA`) when the helper is absent — i.e. a new `.so` deployed against a v0.2.2 schema that has not run `ALTER EXTENSION pg_durable UPDATE`. Presence is detected via a `pg_proc` catalog lookup rather than catching `42883`, so the surrounding (sub)transaction is never aborted.
- **Guarantee A considerations:** Guarantee A covers the `df` schema only and compares function signatures, not bodies. `df.duroxide_schema()` has an identical signature on the fresh-install and upgrade paths (only the returned literal differs), so Guarantee A passes. The provider schema name (`_duroxide` vs `duroxide`) is intentionally excluded from the snapshot diff, as it was for v0.2.0.
- **Guarantee B1 considerations:** The new `.so` works against the v0.2.2 schema: when `df.duroxide_schema()` does not exist, the runtime falls back to `'duroxide'`, which is exactly the schema that release uses.
- **Guarantee B2 considerations:** No data migration. The existing `duroxide` schema and its tables are untouched; the upgrade only adds one `df` function.
