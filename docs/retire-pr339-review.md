---
title: "Review: PR 339 retirement of pre-v0.2.2 compatibility"
type: review
status: retained-for-reference
date: 2026-08-07
---

# Review: PR 339 retirement of pre-v0.2.2 compatibility

> **Retained for reference.** PR #339 was closed on 2026-08-11 after v0.2.1
> installations were found in the field, disproving the premise of the
> retirement this review examined.
>
> F1 and F3-F8 were implemented and verified. **F2's deferral is invalidated:**
> it was deferred on the basis that no known installation started on v0.1.1, and
> `docs/move-duroxide-schema.md` records that the Azure fork shipped v0.1.1 and
> v0.2.1. If that lineage is the source of the surviving installations, the
> ownership conversion must be kept, not removed.

## Decision Tracker

Update **Status** as work progresses and set **Decision** to `Fix` or `Defer`.
Deferred items should record the rationale and follow-up owner in the finding.

| ID | Severity | Status | Decision | Finding |
|---|---|---|---|---|
| F1 | P1 | Decided | Fix | A [below-floor refusal](../src/worker.rs#L452) re-enters the [worker loop](../src/worker.rs#L255-L264) without backoff instead of standing down. |
| F2 | P1 | Decided | Defer | Removing the ownership conversion can permanently strand a v0.1.1-lineage database that the [version-only guard admits](../src/worker.rs#L379-L397) before [`ApplyAll`](../src/worker.rs#L470-L486). Recovery is destructive drop/recreate. |
| F3 | P1 | Decided | Fix | The [below-floor guard](../src/worker.rs#L401-L410) and its before-DDL ordering are tested only through the [pure verdict tests](../src/worker.rs#L992-L1028), not end to end. |
| F4 | P2 | Decided | Fix | A [transient `extversion` query failure](../src/worker.rs#L401-L410) is conflated with a permanent compatibility rejection. |
| F5 | P2 | Decided | Fix | The retained [provider-schema ownership check](../src/worker.rs#L349-L369) has no negative test. |
| F6 | P3 | Decided | Fix | [`parse_semver()`](../src/dsl.rs#L73-L87) and the [guard test](../src/worker.rs#L1022-L1024) admit `0.2.2-rc1` as though it were final. |
| F7 | P3 | Decided | Fix | The [B1 provider-ownership assertion](../scripts/test-upgrade.sh#L794-L813) can pass without proving provider objects exist. |
| F8 | P3 | Decided | Fix | [`resolve_provider_schema()`](../scripts/test-upgrade.sh#L434-L447) does not validate that it returned a non-empty, usable schema. |

## Review Scope

- **PR:** #339, `Retire pre-v0.2.2 compatibility`
- **Base:** `76a36aabb14a1fb8b674c1fd99044ad59e2aba53`
- **Mode:** report-only; no fixes were applied during review
- **Personas:** correctness, testing, security, reliability, adversarial
- **Review posture:** the retirement plan was treated as an unproven hypothesis and checked against the implementation

The mechanical DSL simplification appears consistent. The supported node INSERT
uses nine placeholders and nine arguments per row, the instance INSERT uses five
placeholders and five arguments, and variable operations remain owner-scoped.
The material findings are concentrated in the new background-worker floor guard
and the removal of the provider-object ownership conversion.

## Findings

### F1 — P1: Permanent rejection hot-loops

**Location:** [`initialize_duroxide_runtime()`](../src/worker.rs#L413-L486), its
[floor-refusal branch](../src/worker.rs#L449-L455), and its
[outer-loop caller](../src/worker.rs#L255-L264).

The floor guard logs a refusal and returns `None`. Its caller handles `None` with
`continue`, re-entering the outer worker loop. Because the extension still
exists, [`wait_for_extension_creation()`](../src/worker.rs#L310-L331) returns
immediately and initialization runs again. There is no sleep on this path.

A genuine pre-v0.2.2 schema therefore causes repeated catalog queries, CPU use,
and an unbounded stream of refusal logs. This contradicts the implementation
comment that the worker will "give up rather than loop."

**Suggested fix:** Represent permanent refusal separately from shutdown or
extension removal. Put the worker into an interruptible stand-down state until
the extension is dropped, its version changes, or PostgreSQL shuts down. At a
minimum, add bounded backoff so this path cannot spin.

**Decision notes:**

- **Decision: Fix** together with F4 using the approved worker/backend approach
  below.

#### Approved combined resolution for F1 and F4

The hot-loop fix should also make permanent compatibility rejection visible to
the user. Logs alone are not a sufficient interface for a condition that cannot
recover through retries.

There is a partial user-facing signal today. Engine-dependent functions use
[`with_duroxide_client()`](../src/client.rs#L85-L126), which checks
[`is_worker_ready()`](../src/client.rs#L41-L69) before creating a client. When
the readiness table is absent or stale, [`df.start()` fails and rolls back its
instance rows](../src/dsl.rs#L1162-L1180) with:

> `pg_durable background worker not yet initialized — try again in a moment`

That message is misleading for a compatibility-floor rejection: retrying will
never succeed, and it gives the operator no installed version, required floor,
or recovery path.

Readiness alone is also insufficient as a compatibility guard. The
`_worker_ready` row is persistent and `WORKER_SCHEMA_VERSION` has remained `1`
since readiness was introduced in v0.2.0. A rejected v0.2.0 or v0.2.1 database
can therefore already have a readiness row that satisfies the current binary's
[`is_worker_ready()` check](../src/client.rs#L41-L69). The backend can then
construct a [`VerifyOnly` provider](../src/types.rs#L349-L384) even though the
BGW has refused to start. Depending on provider state, an engine-dependent call
can return a low-level migration error or enqueue work that no BGW will process.

Implement one shared compatibility decision with three outcomes:

1. **Compatible:** proceed with normal initialization.
2. **Transient version-read failure:** log the read error and retry with the
   existing interruptible initialization backoff.
3. **Permanent rejection:** log the actionable compatibility message and enter
   an interruptible stand-down state. Do not return `None` into the outer
   no-backoff `continue` path.

Apply the same permanent-rejection decision in backend sessions **before
trusting `_worker_ready` or constructing a Duroxide client**. Engine-dependent
commands should return an actionable PostgreSQL error naming:

- the installed `pg_durable` version;
- the v0.2.2 provider compatibility floor;
- the retired `duroxide-pg-opt` provider line; and
- recovery through a package that still contains the old upgrade chain or the
  downstream upgrade process.

This applies to [`df.start()`](../src/dsl.rs#L883-L925),
[`df.signal()`](../src/dsl.rs#L622-L653), and
[`df.cancel()`](../src/dsl.rs#L1185-L1218), all of which need the Duroxide
client. Keep read-only monitoring functions such as
[`df.status()` and `df.result()`](../src/dsl.rs#L1226-L1255) available so an
operator can inspect existing instances while the worker is rejected.

Do not add a public `df.worker_status()` function in this PR. That would add SQL
DDL and upgrade-surface work to a compatibility cleanup. An explicit error from
engine-dependent commands, plus the existing logs, is sufficient.

Required regression coverage:

- A below-floor BGW enters bounded stand-down without provider DDL, CPU spin, or
  repeated refusal logs.
- A transient `extversion` read failure retries with interruptible backoff and
  does not emit the permanent compatibility message.
- With `extversion = 0.2.1` and a matching stale `_worker_ready` row,
  `df.start()` returns the floor-specific error and leaves no instance or node
  rows. Extend the existing
  [start fail-fast test](../tests/e2e/sql/25_start_fail_fast.sql#L1-L50) or add a
  focused lifecycle test.
- Read-only monitoring remains available during permanent rejection.
- Update the current retry guidance in the
  [user guide](../USER_GUIDE.md#L82-L84) so it distinguishes temporary startup
  from permanent compatibility rejection.

### F2 — P1: Removed conversion strands an admitted lineage

**Location:** the [version-only verdict](../src/worker.rs#L379-L397), retained
[schema-namespace ownership check](../src/worker.rs#L349-L369), and
[`ApplyAll` provider construction](../src/worker.rs#L470-L486). The removed
object-level ownership probe and conversion are visible in the PR diff rather
than the current file.

The plan explicitly accepts a database that started at v0.1.1, upgraded to a
v0.2.2-or-later extension version, but never completed a background-worker
initialization. Such a database can still have provider objects registered as
members of the `pg_durable` extension.

The new guard checks only [`extversion`](../src/worker.rs#L401-L410), so it
admits this database. `ApplyAll` then attempts to drop or alter extension-owned
provider objects and can fail indefinitely through the
[store-construction retry](../src/worker.rs#L470-L486). The plan justifies
accepting this case because one successful worker start would run the idempotent
conversion, but this PR deletes the code that performs that conversion. The
stated mitigation therefore no longer exists.

**Suggested fix:** Choose one explicitly:

1. Retain the ownership probe and conversion as a lineage-based repair.
2. Retain only the probe and reject this state with an actionable manual-recovery message before `ApplyAll`.
3. Defer with an explicit support decision, documented recovery procedure, and evidence that the affected population is acceptably empty.

**Decision notes:**

- **Decision: Defer.** A v0.1.1-lineage database at a v0.2.2-or-later
  `extversion` that still contains extension-owned provider objects is outside
  the supported compatibility line. The current binary will not preserve or
  repair that provider state.
- **Recovery procedure:** back up any data needed for investigation, then drop
  and recreate the extension:

  ```sql
  DROP EXTENSION pg_durable;
  CREATE EXTENSION pg_durable;
  ```

  Dropping the extension removes extension-owned `df` and provider objects,
  including durable instances, graph nodes, variables, execution history, and
  provider state. This is a clean reinitialization, not an in-place migration or
  data-preserving repair. Application-role grants and other post-install setup
  must be applied again after recreation.
- If PostgreSQL reports dependent objects and the operator chooses
  `DROP EXTENSION pg_durable CASCADE`, that additionally drops those dependent
  objects. Do not recommend `CASCADE` without identifying and accepting that
  wider impact first.
- Publish this support decision and recovery procedure in operator-facing
  release notes. The background-worker/provider error for this lineage should
  point to that procedure rather than imply that retries will repair it.

### F3 — P1: Central safety property lacks an integration test

**Location:** [worker guard tests](../src/worker.rs#L986-L1029) and the
[B1 upgrade-harness entry points](../scripts/test-upgrade.sh#L912-L913).

The new tests call only
[`provider_compat_floor_verdict()`](../src/worker.rs#L379-L397). They do not
exercise the database query in
[`check_provider_compat_floor()`](../src/worker.rs#L401-L410), the
[refusal branch](../src/worker.rs#L449-L455), or the ordering relative to
[`PostgresProvider::new_with_config(... ApplyAll ...)`](../src/worker.rs#L470-L486).

The upgrade harness starts at v0.2.2 and cannot test rejection below the floor.
Consequently, no executable test proves that a below-floor schema is rejected
before provider DDL runs. The test suite would not catch a future reordering of
the guard after `ApplyAll`.

**Suggested fix:** Add a worker-level test that presents a below-floor extension
version and records a provider-state sentinel, then verifies refusal, bounded
worker behavior, no readiness record, and no provider mutation. The test should
exercise the actual initialization path rather than only the pure comparator.

**Decision notes:**

- **Decision: Fix.** Add an end-to-end worker initialization test that proves a
  below-floor schema enters bounded stand-down before provider DDL. The test must
  exercise the real guard/query/initialization path, not only the pure version
  comparator.

### F4 — P2: Transient read errors are treated as incompatibility

**Location:** [`check_provider_compat_floor()`](../src/worker.rs#L401-L410) and
its [single-error-channel caller](../src/worker.rs#L449-L455).

The function returns `Err(String)` both when a successfully read version is
below the floor and when `SELECT extversion` fails. The caller treats both as a
permanent refusal. A connection reset, pool acquisition failure, or statement
timeout therefore enters the same no-backoff path as an incompatible schema and
emits a misleading compatibility message.

Other recoverable initialization failures
[sleep and retry](../src/worker.rs#L457-L486). The new guard should preserve
that distinction.

**Suggested fix:** Return distinct outcomes for query failure, invalid version,
and below-floor version. Retry query failures with interruptible backoff; reserve
stand-down behavior for a version that was read successfully and rejected.

**Decision notes:**

- **Decision: Fix** with F1. Use the three-outcome compatibility decision and
  tests documented under F1.

### F5 — P2: Provider-schema ownership rejection is untested

**Location:** [`check_duroxide_schema_owned()`](../src/worker.rs#L349-L369) and
its [pre-provider call site](../src/worker.rs#L457-L466).

The function is retained and still runs before `ApplyAll`, so the security
control itself was not removed. However, there is no direct negative test for an
attacker-created provider schema that is not owned by the extension. The plan
explicitly required this test if it did not already exist.

**Suggested fix:** Create a provider schema with the expected name but without
the extension dependency, then verify initialization refuses it and does not
construct or migrate the provider.

**Decision notes:**

- **Decision: Fix.** Add a negative test with a correctly named provider schema
  that is not extension-owned and verify the BGW refuses it before provider
  construction or migration.

### F6 — P3: Floor prereleases are admitted

**Location:** [`parse_semver()`](../src/dsl.rs#L73-L87), its existing
[prerelease parsing test](../src/dsl.rs#L1390-L1393), and the worker's
[floor-prerelease admission test](../src/worker.rs#L1022-L1024).

`parse_semver()` discards the prerelease suffix, so `0.2.2-rc1` becomes
`(0, 2, 2)` and passes the floor. SemVer orders `0.2.2-rc1` before `0.2.2`.
The test `admits_a_prerelease_at_the_floor` makes this behavior intentional even
though a floor prerelease could have a schema different from the final release.

No evidence was found that a v0.2.2 prerelease shipped, so the immediate risk is
low. The repository does use prerelease versions, making the boundary worth an
explicit decision.

**Suggested fix:** Reject prereleases whose numeric core equals the floor, or
document evidence that every v0.2.2 prerelease used the final provider schema
and retain the behavior deliberately.

**Decision notes:**

- **Decision: Fix.** Follow SemVer ordering: reject prereleases whose numeric
  core equals the floor, including `0.2.2-rc1`. Continue admitting prereleases
  whose numeric core is above the floor, such as `0.2.4-rc1`.

### F7 — P3: B1 ownership assertion can produce a weak green

**Location:**
[`test_b1_no_extension_owned_duroxide_objects()`](../scripts/test-upgrade.sh#L794-L813)
and its [B1 invocation](../scripts/test-upgrade.sh#L912-L913).

The assertion now checks a fresh-install invariant rather than the removed
conversion path. A count of zero can also pass when expected provider objects
are absent, so the assertion does not independently prove that provider objects
were created and are non-extension-owned.

**Suggested fix:** Pair the zero-membership assertion with a positive assertion
that expected provider objects exist in the resolved provider schema.

**Decision notes:**

- **Decision: Fix.** Strengthen the B1 assertion by first proving expected
  provider objects exist in the resolved schema, then proving none are
  registered as `pg_durable` extension members.

### F8 — P3: Provider-schema resolution lacks a clear guard

**Location:** [`resolve_provider_schema()`](../scripts/test-upgrade.sh#L434-L447)
and [`wait_for_ready()`](../scripts/test-upgrade.sh#L452-L471).

The readiness rewrite fails closed: an incorrect schema eventually times out
rather than falsely passing. However, an empty or unusable result is not checked
directly, so a schema-resolution defect appears as an opaque 30-second readiness
timeout.

**Suggested fix:** Reject empty output immediately and verify that the resolved
schema contains `_worker_ready` once initialization succeeds.

**Decision notes:**

- **Decision: Fix.** Reject empty provider-schema output immediately and verify
  that the resolved schema contains `_worker_ready` after successful
  initialization, producing a direct diagnostic instead of a 30-second timeout.

## Verified Non-Findings

- The [nine-parameter node INSERT](../src/dsl.rs#L698-L723) and its
  [argument vector](../src/dsl.rs#L1012-L1052) remain aligned.
- The [five-parameter instance INSERT](../src/dsl.rs#L1105-L1123) and its
  argument vector remain aligned.
- Owner scoping remains present in [`setvar()`](../src/dsl.rs#L93-L106),
  [`getvar()`](../src/dsl.rs#L111-L117),
  [`unsetvar()`](../src/dsl.rs#L122-L133),
  [`clearvars()`](../src/dsl.rs#L138-L149), and start-time variable capture.
- [`check_duroxide_schema_owned()`](../src/worker.rs#L349-L369) remains before
  [provider construction and `ApplyAll`](../src/worker.rs#L457-L486).
- The [`pgspot-gate.sh`](../scripts/pgspot-gate.sh) change increases coverage of remaining upgrade scripts;
  it does not create an exclusion.
- No supported v0.2.2-or-later SQL install or upgrade file is modified by the PR;
  the SQL changes are the four intended deletions.

## Residual Test Gaps

- No test exercises a transient failure while
  [reading `extversion`](../src/worker.rs#L401-L410).
- No test proves that [permanent incompatibility](../src/worker.rs#L449-L455)
  enters a bounded stand-down
  state rather than a hot loop.
- No test constructs the accepted v0.1.1-lineage state with extension-owned
  provider objects at a v0.2.2-or-later `extversion`.
- The [1,002-node E2E assertion](../tests/e2e/sql/09_graph_and_validation.sql#L333-L334)
  proves the batch count but does not independently assert every persisted
  column across the batch boundary.

## Current Verdict

**Decisions complete; implementation not ready to merge.** Implement and verify
F1 and F3 through F8 before merge. F1 and F4 are one combined worker/backend
compatibility-error change. F2 is intentionally deferred under the explicit
unsupported-lineage decision and destructive drop/recreate recovery procedure
above; publish that decision and procedure in operator-facing release notes.