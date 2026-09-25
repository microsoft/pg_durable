# Semantic versioning and compatibility plan

**Status: compatibility discovery in progress; guarantees remain proposals.**
Prepared on 2026-09-15 and updated on 2026-09-24. The released-binary
B1/B2 discovery harness has been exercised against the 0.2.9 development tree.
Its finite SQL, timer-loop, SQL-sequence and permission cases do not certify
general replay or provider-migration compatibility. This work
does not bump the version, repair runtime incompatibilities, choose a 1.0
baseline, or implement the future release gates described below.

## Recommendation

First establish a reproducible inventory of which workflows survive which
upgrade paths, and document the failures. Finish the discovery harness and
initial findings in this PR; expand small diagnostic workflows and sanitized
downstream pipeline examples incrementally. Keep the full historical chain
opt-in while retaining automatic catalog and harness-unit checks.

Decide the release number, supported replay baseline and mandatory compatibility
gates after reviewing that evidence. A future 1.0 remains an option, not a
decision made by this PR. Do not publish 1.0 merely by changing the version number.

Evaluate separate baselines for separate contracts. These are candidate policy
choices, not guarantees established by the initial experiment:

| Contract | Proposed source set |
|---|---|
| Binary against old extension catalogs | Every released `df` schema from 0.2.2 onward, explicitly carried across the 1.0 major boundary |
| Existing durable execution | Histories produced by v0.2.8, including old-input compatibility paths that v0.2.8 supports; subsequently, every released 1.x runtime protocol |
| Public API and behavior | Inventory and freeze the supported 1.0 surface, preserving the documented v0.2.8 surface during adoption |
| Provider state | Existing `duroxide-pg` state and migration lineage, in either `duroxide` or `_duroxide`; not the pre-0.2.2 `duroxide-pg-opt` lineage |

Keep earlier runtime fixtures where useful, especially v0.2.5, v0.2.6, and
v0.2.7. They establish which earlier instances can also upgrade safely; a passing
v0.2.8 fixture alone must not be advertised as certifying every 0.2.x history.

The user's skipped-version concern is correct: replacing a 0.2.3 binary directly
with a later binary encounters any incompatible history protocol changes in
between. Applying intermediate extension SQL scripts cannot repair a replay
mismatch. A 1.0 label communicates a new contract, but does not recover already
incompatible histories. Older upgrade sources need an explicit drain/recreate
runbook or separately implemented legacy support.

SemVer itself permits instability anywhere in `0.y.z`; the current changelog's
"minor releases may include breaking changes" wording is narrower than that.
Neither wording is a substitute for telling operators which upgrades require
action. After 1.0, a patch or minor upgrade must not require draining or recreating
supported work solely because pg_durable changed.

## Historical upgrade impact

Read "running" as non-terminal durable work, including pending starts, signal and
timer waits, child instances, and loop continuations. Replay normally reconstructs
the current execution's earlier decisions, not just its currently parked node.
A changed operation already present in retained history can therefore matter
after that node appears to have finished.

The table below contains source/documentation findings, not measured outcomes
for every transition. The separate initial experiment is summarized below it.
Published release notes and tagged code take precedence over an unshipped
changelog section. A replay failure can leave `df.instances` reporting
`pending`/`running` if the engine fails before pg_durable's status-finalization
activity; checking only `df.status()` is insufficient.

| Upgrade | Expected running-work impact | Mechanism and other compatibility effects |
|---|---|---|
| 0.2.1 -> 0.2.2 | **No supported in-place continuity across this provider boundary.** Treat all old durable work as requiring an explicit migration/recreation strategy, not just loop instances. | `duroxide-pg-opt` is replaced by `duroxide-pg` with different provider state/schema. This is stronger than a local orchestration replay change; existing terminal engine data is not certified either. JOIN results also change from double-encoded strings to objects; SQL result decoding, composite captures, branch state and signal behavior change. |
| 0.2.2 -> 0.2.3 | **No blanket drain boundary documented. Narrow, high-confidence inferred risk for IF/conditional-loop histories that took the old true path after an empty SQL condition.** | Empty-result conditions now evaluate false instead of true. If the old true branch or loop continuation already recorded follow-on actions, replay can diverge. This does not implicate every IF/loop or the separate IF_ROWS path. Provider-schema rename is fresh-install-only; upgraded databases retain `duroxide`. `df.break()` has a legacy-envelope fallback. The default worker role also changes from `azuresu` to `postgres`. |
| 0.2.3 -> 0.2.4 | **General replay break: drain all in-flight work as the operational rule.** Precisely, histories that already recorded the old node-status activity input cannot replay. | The `update-node-status` input acquires instance/execution identity fields, changing recorded bytes. WAIT_SCHEDULE independently adds a recorded clock decision before its timer. Terminal instances do not normally replay. Schema changes remain separately binary-compatible, but key/index rebuilds can block; listing limits, retention, privileges and removed helpers also change behavior. |
| 0.2.4 -> 0.2.5 | **All old recorded JOIN/RACE branch schedules break; root and nested loops may break.** Not a claim that every sequential function fails. | `execute-subtree` input changes unconditionally, and loop hosting, child IDs, graph carrying and continuation inputs change. Checking only currently active branches is too narrow when a completed branch's schedule remains in the current execution history. The `df.start()` SQL signature replacement can also block `ALTER EXTENSION UPDATE` on customer dependencies. |
| 0.2.5 -> 0.2.6 | **Narrow, high-confidence inferred replay risk for formerly re-expanded placeholders, even in a simple sequence. No blanket loop/parallel drain boundary.** | Single-pass variable substitution deliberately stops rescanning placeholder-like replacement text. If replay reconstructs a different already-recorded activity input, that history can mismatch. Graph-materialization changes are separately documented as preserving persisted `df.nodes` and in-flight work, but the transient Durofut envelope changes. Removing `df.ensure_durofut()` can block schema upgrade on customer-owned dependencies. |
| 0.2.6 -> 0.2.7 | **No general replay break documented. Pending or retried HTTP work can fail under the tightened policy.** | Restricted builds now require HTTPS and use one canonical parsed URL for authorization and transport. Already recorded HTTP results are not re-fetched on replay. This is an activity behavior/security-policy boundary, not an orchestration scheduling boundary. |
| 0.2.7 -> 0.2.8 | **Narrow documented loop-history exception, not "all loops break."** | The backstop increases from 100,000 to 8,388,608 iterations. A history that recorded the old terminal-failure path at the old limit is incompatible; ordinary loops below that boundary retain their path. Opted-in failure-isolated loops use new graph configuration; existing graphs stay inline/fail-fast. Transaction-aware graph admission preserves the historical loading activity for inputs without an origin transaction ID. |
| 0.2.8 -> development 0.2.9 | **No replay break declared by the currently documented changes. Not yet a released or cross-binary-tested guarantee.** | HTTP options are additive and require schema update. HTTP client reuse is activity-local; allowed-domain configuration affects requests when they execute, while defaults are preserved. Dependency and release-tooling changes still need the proposed gates. |

There is no single useful "last breaking version": **0.2.2 is the provider
boundary, 0.2.4 the broad replay boundary, 0.2.5 the broad loop/parallel boundary,
and 0.2.8 the latest explicitly documented narrow replay exception.** The
substitution fix in 0.2.6 is another reason not to use 0.2.5 as an unqualified
continuity baseline. v0.2.8 is therefore a candidate replay baseline to evaluate
for 1.0, not an approved guarantee or a reason to drop old-schema support.

### Initial measured evidence

The [released-binary B1/B2 chain](upgrade-testing.md#released-binary-b1b2-discovery-chain)
ran 0.2.2 -> 0.2.5 -> 0.2.7 -> candidate 0.2.9 on PostgreSQL 17.10, with a
binary-only observation followed by a SQL-update observation at each upgrade.
At each of seven steps it created a finite SQL insertion and a timer-paced root
loop. Iteration counts were independent of the upgrade phases.

All seven finite instances completed and retained their results. The 0.2.2 loop
failed at the 0.2.5 binary replacement with an `update-node-status` schedule
mismatch, while the `df` status mirror still said `running`. Loops created in
the six subsequent steps progressed through all their later observations. All
fourteen instances remained inspectable. Exact candidate identity, build scope
and limitations are recorded in the upgrade-testing document and run evidence.

The September 24 expansion added 28 SQL-only sequences with 13 leaves, 25 total
nodes and depth 12, under two delegated non-superuser users. Completed sequences
survived; both sequences held on 0.2.2 failed at the 0.2.5 binary swap with the
same node-status mismatch. Later held sequences crossed their next upgrade and
completed. Permission probes found missing grants for new multipart (0.2.5)
and endpoint-overload (candidate 0.2.9) functions, plus broken HTTP-inclusive
delegation by unrefreshed admins. Refreshing only the admin restored delegation,
not the original user's new-function grants; tested SQL access remained usable.
See the [expanded report](upgrade-testing.md#expanded-measured-results).

The recorded provider dependency stayed at `duroxide-pg` 0.1.34 with the same
21 migration records. The harness observes startup migrations and post-restart
behavior, but these runs did not exercise a provider-version transition.

This is evidence for those graph shapes on that path only. It does not locate
the first breaking intermediate release, prove direct jumps, certify v0.2.8 as
a replay source, or show live survival of the already-failed 0.2.2 loop. Keep
observed success, confirmed failure, source-inferred risk, untested behavior and
paths blocked by earlier failures distinct in future compatibility tables.

### Source-derived risks and historical precision

For the 0.2.3 condition fix, the old result `{"rows":[],"row_count":0}` was treated
as a truthy nonempty object; the new helper explicitly returns false. An old
recorded empty result followed by true-branch actions can therefore mismatch
on replay. If no divergent follow-on action has been recorded, behavior changes
but a nondeterminism error is not inevitable. See the
[tagged helper](https://github.com/microsoft/pg_durable/blob/v0.2.3/src/types.rs#L381-L400)
and [implementing change](https://github.com/microsoft/pg_durable/commit/1d45ce33b5d8f12b8468929ad368c420df5446cb).

For 0.2.6, a deterministic example independent of HashMap iteration order is a
template `SELECT '{sys_label}'`, a label `{name}`, and a variable `name = Ada`.
The old system-then-user passes produce `SELECT 'Ada'`; the new single pass
produces `SELECT '{name}'`. Because substitution runs inside the orchestration
before scheduling SQL, replay of the old recorded input can fail. This is a
source-confirmed behavior change and a high-confidence replay inference, not a
cross-version test result. See
[old substitution](https://github.com/microsoft/pg_durable/blob/v0.2.5/src/types.rs#L858-L885),
[new substitution](https://github.com/microsoft/pg_durable/blob/v0.2.6/src/types.rs#L898-L962),
and the [activity replay matcher](https://github.com/microsoft/duroxide/blob/v0.1.30/src/runtime/replay_engine.rs#L1839-L1855).

For 0.2.8, an already-terminal loop failure is not automatically replayed on
upgrade. The documented exception concerns a replayed execution that has
recorded the old limit's failure path, not every loop approaching iteration
100,000. See the
[tagged warning](https://github.com/microsoft/pg_durable/blob/v0.2.8/docs/upgrade-testing.md#L229-L234).

Completed executions, reusable SQL definitions and saved internal graph strings
are different things. The replay warnings do not erase all completed results or
invalidate every SQL definition that constructs a new graph. Conversely, the
0.2.6 warning against persisting transient Durofut strings and the SQL
dependency/privilege changes require separate checks even if replay succeeds.

The pinned dependency history also separates provider changes from application
replay changes: v0.2.1 uses duroxide 0.1.28 and duroxide-pg-opt 0.1.26;
v0.2.2-v0.2.4 use duroxide 0.1.29 and duroxide-pg 0.1.34;
v0.2.5-v0.2.8 use duroxide 0.1.30 and the same provider 0.1.34.
The 0.2.4/0.2.5 application-input breaks are not evidence of a provider-family
reset in either release.

### Documentation corrections to carry into the implementation

- The 0.2.4 changelog's unqualified "breaking rename" claim is inaccurate:
  [released SQL](https://github.com/microsoft/pg_durable/blob/v0.2.4/sql/pg_durable--0.2.3--0.2.4.sql#L168-L183)
  and [Rust](https://github.com/microsoft/pg_durable/blob/v0.2.4/src/dsl.rs#L1252-L1264)
  retain `df.wait_for_completion()` and its C wrapper as a deprecated alias.
  Ordinary callers still resolve. Unsafe invocation inside a workflow is
  rejected; that is the narrower behavior change.
- Transaction-aware admission first ships in v0.2.8:
  [implementation](https://github.com/microsoft/pg_durable/commit/d5c694346ddd254cf2615dade2051219e9d18e8d).
  Its placement under 0.2.6 -> 0.2.7 in the upgrade document is incorrect.
- The 0.2.5 upgrade narrative understates the old child envelope: v0.2.4 already
  included `vars` and `label`. The new required `instance_id` and serialized
  `iteration`, among other serialization changes, suffice to break old inputs.
  See [v0.2.4 scheduling](https://github.com/microsoft/pg_durable/blob/v0.2.4/src/orchestrations/execute_function_graph.rs#L926-L949)
  and [v0.2.5 input](https://github.com/microsoft/pg_durable/blob/v0.2.5/src/orchestrations/execute_function_graph.rs#L72-L87).
  Also, the inspected engine child matcher compares name/input, not explicit
  child-ID equality; timers match by position, not exact fire time. Keep child
  identity and timer semantics in our contract, but do not overstate what the
  current [engine matcher](https://github.com/microsoft/duroxide/blob/v0.1.30/src/runtime/replay_engine.rs#L1857-L1879)
  actually checks.
- The default B1/B2 suite builds only the current binary. Only the opt-in
   released-binary mode produces historical replay evidence; do not conflate
   the two kinds of coverage.
- Keep published upgrade SQL immutable. Correct prose openly and put any
  required DDL repair in the next upgrade script, not a shipped script.

Sources: [changelog](../CHANGELOG.md), [upgrade testing](upgrade-testing.md),
GitHub releases [v0.2.2](https://github.com/microsoft/pg_durable/releases/tag/v0.2.2),
[v0.2.3](https://github.com/microsoft/pg_durable/releases/tag/v0.2.3),
[v0.2.4](https://github.com/microsoft/pg_durable/releases/tag/v0.2.4),
[v0.2.5](https://github.com/microsoft/pg_durable/releases/tag/v0.2.5),
[v0.2.6](https://github.com/microsoft/pg_durable/releases/tag/v0.2.6),
[v0.2.7](https://github.com/microsoft/pg_durable/releases/tag/v0.2.7), and
[v0.2.8](https://github.com/microsoft/pg_durable/releases/tag/v0.2.8).

## Proposed 1.x guarantees

For every supported source release, upgrading directly to a newer 1.x binary
must preserve the following, whether or not the administrator immediately updates
the extension schema.

| Surface | Guarantee |
|---|---|
| SQL API | Existing documented names, aliases, signatures, argument names/defaults, operator resolution, result columns/types, JSON field meanings, status meanings and valid-input semantics continue to work. Additions must not make old overloads ambiguous. |
| Customer database objects | Dependent views/functions and customized owners/grants survive schema update. Preserve object identity where dependencies require it; do not use drop/recreate or `CASCADE` as an apparent compatibility fix. |
| Old extension schemas / C bindings | The new library retains every required cataloged C symbol with the matching calling convention and return shape. Queries use old-schema-compatible paths or explicit capability detection. Newly added features may require `ALTER EXTENSION UPDATE`; existing features may not. |
| Persisted application state | Existing graphs, variables, named results, typed control/error envelopes and retained instance results remain usable. Internal formats need not be a public interchange API, but their migration/decoding is our responsibility. |
| Durable history | Old supported executions replay without changed recorded operations, operation names, order, inputs, timer decisions, child identity, control flow or outputs. A deterministic refactor is not automatically a replay-compatible refactor. |
| Future work in existing instances | Pending activities, signals, timers, cancellations, child completion and successive loop generations remain functional under the supported contract. Compatibility must extend beyond the first successful replay after restart. |
| Provider state | Automatic background-worker migrations preserve queues, history, locks/leases, events and instance lineage. Changing the provider dependency does not exempt the product from compatibility requirements. |
| Configuration and access | Supported configuration names, accepted values and documented defaults remain compatible. An upgrade does not silently broaden grants or require new privileges for existing authorized use. Pending activities still honor deliberate administrator revocations and current security policy. |
| Operational scope | A documented maintenance restart is allowed. Compatibility does not mean zero downtime, no DDL locks, identical latency, no external failures, or transactional/exactly-once guarantees for arbitrary SQL/HTTP side effects beyond the existing execution contract. |

Completed results remain available **within the configured retention and capacity
policy**, not forever. Loop continuity is subject to the existing documented
iteration bound, not a promise of unlimited execution. Compatible replay reuses
recorded outcomes; an activity interrupted before its outcome is durably recorded
can still require retry/idempotency handling.

Internal provider tables, Rust internals, raw transient Durofut JSON, exact log
wording and debug-only helpers are not automatically public APIs. Audit existing
documentation before classifying a surface as private; do not retroactively
exclude an advertised capability merely to permit a breaking change.

For `continue_on_failure`, currently described as experimental, the recommended
1.0 choice is to stabilize its existing documented syntax and behavior. If it
remains experimental, list the exact opt-in surface and limitations explicitly;
even then, do not silently abandon persisted running work created through it.

### Version-number rules

| Release kind | Allowed changes |
|---|---|
| Patch | Backward-compatible fixes and maintenance. Internal orchestration versions may change if old executions and public behavior remain supported. A fix for newly executed work must still replay old recorded decisions safely. |
| Minor | Compatible API/features and deprecations, with the patch guarantees intact. New required schema objects gate only new capabilities. |
| Major | Intentional incompatible public behavior or withdrawal of a previously promised upgrade/runtime path. Requires a specific migration and continuity plan, not just a major number. |

Supporting older minor branches would add new maintenance-patch releases, not
modify published tags or SQL. Preserve fixtures from the original releases and
add the patched sources and supported upgrade paths to the matrix. A patch that
only changes newly created workflows does not repair already-recorded history;
the destination may need legacy replay support. Any required intermediate patch
must be an explicit operator constraint, not an assumed upgrade step.

The pg_durable package version, extension catalog version, orchestration handler
version, history/replay-engine version and provider migration version are
different identifiers. No one of them proves compatibility of the others.

Document security fixes precisely. Fixing behavior outside the documented
authorization contract can be a compatible fix. Breaking a documented valid use
does not become SemVer-compatible merely because the change is security-related:
use a compatible mitigation, an explicit migration, or a major release.

Support is forward-only within a stated PostgreSQL major, OS/architecture and
build-feature tier. PostgreSQL major upgrades, binary downgrades, provider-family
switches and mixed-old/new-worker rolling deployments require separate support
policies; they are not implied by this initial contract. Publish the supported
platform matrix instead of inferring it from Cargo feature names.

Do not silently expire old handlers/schemas during 1.x because no instance in CI
currently uses them. Customers may have long signal waits, dormant instances or
deferred schema updates. Any future support-window policy must be explicit and
must not retroactively weaken the announced 1.x direct-upgrade guarantee.

## Runtime versioning design requirements

The pinned duroxide 0.1.30 already supports orchestration versioning.
`src/registry.rs` currently registers the root and subtree handlers with ordinary
`register()`, which registers handler version **1.0.0**; this is unrelated to
pg_durable's current package version.

Preserve those names and their legacy handlers. A replay-changing implementation
gets a separately registered handler version, plus the input/output codecs and
transitive helpers required to preserve the legacy behavior. Merely copying the
top-level async function while changing its shared helpers is not sufficient.
Activities do not have equivalent independent version registration in this
pinned runtime: use a new activity name for an incompatible activity contract,
retaining the old decoder and handler for old queued/retried work.

**Important trap:** duroxide's default `Latest` policy applies to unversioned
new starts and `continue_as_new`; unversioned child scheduling also uses registry
policy. Keeping the old root registered does not by itself keep an existing loop
or a later-spawned child on compatible code.

Before adding a second handler version:

1. Capture the exact default-version behavior from v0.2.8. Prove that changing
   registration organization alone does not change old history.
2. Define an execution-protocol family spanning root, subtree, activities,
   serialization, substitution and continuations. Persist new routing decisions
   in new inputs, not mutable GUCs, wall-clock state or the installed extension
   version.
3. Explicitly choose versions for new code's child schedules and continuations.
   Either pin a compatible family or provide a tested migration at a fresh
   execution boundary. Do not accidentally inherit `Latest`.
4. Handle legacy unversioned children and continuations during bootstrap. Simply
   replacing their calls with versioned variants can itself change recorded
   actions. Preserve the old path; prove any boundary adapter accepts the old
   emitted input and maintains its contract.
5. Test mixed handler versions, outstanding children, cancellation, all error
   envelopes, and several post-upgrade continuation generations.

`#[serde(default)]` can make old input readable; it does not establish that newly
serialized activity/child inputs remain byte-identical. Canonical serialization
also cannot retroactively make old noncanonical recorded bytes canonical.
Keep shared authorization protections current without accidentally changing
legacy replay decisions.

The pre-1.0 releases reused the same default handler version. Registering a
handler called "0.2.5" now would not make old instances select it automatically.
Where legacy histories cannot be distinguished safely, do not guess from the
schema version or current binary. Preserve the supported baseline's behavior,
record explicit protocol provenance for new work, and document older sources
that require draining before the upgrade.

References at the pinned runtime:
[registry](https://github.com/microsoft/duroxide/blob/v0.1.30/src/runtime/registry.rs),
[context APIs](https://github.com/microsoft/duroxide/blob/v0.1.30/src/lib.rs),
[versioning guide](https://github.com/microsoft/duroxide/blob/v0.1.30/docs/versioning-best-practices.md).

## Upgrade & Migration

The current discovery implementation changes no extension DDL, runtime queries
or worker migration behavior. It therefore needs no upgrade script or runtime
schema detection. B1 coverage remains in the default suite, and the optional
chain observes the existing binary/schema boundaries. The guards and protocol
changes below are future proposals with separate compatibility obligations.

### Separate requirement: guarded schema upgrades with safe refusal

**Contract:** Replacing the binary preserves supported existing work without
requiring a schema update. `ALTER EXTENSION pg_durable UPDATE` must either
preserve that work or refuse before making incompatible changes, leaving the
existing installation operational.

The guard is a final safety gate, not a substitute for binary compatibility.
Maintenance can deploy the new binary before the customer requests a schema
update. By then, orchestration replay and the worker's automatic provider
`ApplyAll` migrations may already have run. They must preserve old schemas,
histories, queued activities and worker progress independently of this guard.
Refusing to start, indefinitely blocking, or exiting the worker because supported
old work exists is an outage, not a successful compatibility check. A genuinely
incompatible binary requires a separately controlled deployment/migration path.

Each migration must declare the capabilities or representations it removes or
changes and the execution protocols that remain supported. Persist sufficient
protocol/capability identity for new executions to make those requirements
checkable. Do not infer provenance from `pg_extension.extversion`, the current
binary, or only the currently executing node. Check dependencies of the whole
remaining execution, including future children and loop continuations. Existing
pre-1.0 histories without distinguishable provenance need conservative handling,
not guessed version assignments.

An additive migration that preserves every supported path should pass with live
work present. A migration that would remove a capability still needed by
non-terminal work must retain that capability, migrate it safely, or refuse.
When safety depends on information that cannot be established, refuse with an
explicit uncertainty diagnostic rather than treating unknown state as safe.
This is a declared compatibility check, not a claim that arbitrary SQL or Rust
changes can be automatically proven safe.

The implementation must define a race-free coordination protocol:

1. Establish a bounded migration barrier covering relevant admissions and worker
   operations. Account for caller-owned transactions, independently committed
   starts, child creation and continue-as-new; a count followed by DDL is unsafe.
2. Inspect authoritative durable state, including pending starts, outstanding
   children and work items, and reconcile uncertainty with the `df` control
   plane. Neither a stale `df.instances.status` mirror nor the updating user's
   RLS-filtered view may be used to conclude that no affected work exists.
3. Reject incompatible or unknown dependencies with actionable diagnostics
   identifying the target migration, required capability and affected work,
   without exposing workflow payloads or bypassing diagnostic access controls.
4. Otherwise apply the transactional migration and keep coordination valid
   through commit. Specify cleanup on error, cancellation, transaction rollback
   and rollback to a savepoint, including calls inside explicit transactions.

Do not wait for functions to finish while holding the barrier: they may need
blocked worker operations or an external signal to progress. Refuse promptly and
ensure failure cleanup lets existing work continue. A read-only operator
preflight can explain blockers, but cannot authorize a later update: the update
must repeat the authoritative check under coordination. The guard must work
against the supported old catalogs without first requiring the schema objects
whose installation it is guarding.

**Acceptance coverage (Scenario D: refused upgrade):** Starting from genuine
old-binary checkpoints, exercise known incompatible and unknown-state cases
using isolated test-only migration fixtures where necessary. Assert that refusal
leaves the extension version, schema and protected persisted state unchanged by
the attempted migration; the worker remains healthy; and the same pre-existing
instances can resume, including signal waits and subsequent loop generations.
Permit normal concurrent workflow progress rather than demanding byte-identical
database contents. Exercise concurrent starts/children/continuations, inspection
errors, barrier timeouts, cancellation, transaction/savepoint rollback, and a
successful retry after blockers are safely resolved. Test admission/worker
liveness as well as absence of corruption. Released-binary B1/B2 must separately prove that the
binary swap and provider migrations have not already broken work before the
guard runs, and that compatible schema updates succeed with live work present.

**SemVer constraint:** Gracefully refusing an incompatible upgrade does not make
it compatible. Patch/minor releases must not require draining otherwise
supported functions. Refusal is a safeguard for explicit major migrations,
unsupported legacy states and unexpected compatibility conditions, not a way to
weaken the 1.x guarantee.

### Existing infrastructure: keep it, but do not overclaim it

The default `scripts/test-upgrade.sh` mode installs the candidate binary once, then reconstructs
older catalogs from install fixtures and upgrade chains. B1 exercises new work
on those old catalogs. B2 creates its "pre-upgrade" instances using that same
candidate binary and then applies SQL. Neither creates history with the previous
released binary. Its two-second sleep is not a verified old-binary checkpoint.

Scenario A covers substantial `df` schema metadata, but must not substitute for
an API/binding/dependency comparison or provider migration testing. Normalize
intentional differences such as the selected provider-schema name explicitly.
Keep A/B1/B2 as complementary layers.

At 1.0, the current harness needs structural changes: source discovery filters
on the current major, and a current-major install fixture is required. A version
bump alone can therefore fail setup or skip all 0.x B1 sources. Introduce an
explicit supported-source manifest rather than advancing
`PROVIDER_COMPAT_START_VERSION` or deleting old fixtures to make CI green.

### Extend B1/B2 with actual old-binary state and replay

The initial opt-in implementation is the staged discovery chain documented in
[upgrade testing](upgrade-testing.md#released-binary-b1b2-discovery-chain).
It retains one database across alternating B1/B2 steps, starts live and finite
work at each step, observes independent timer-paced progress and records the
first failure. It does not implement the full coverage below. Historical replay
is an extension of B1/B2, not a separate Scenario C.

Future direct-path certification should satisfy these additional requirements:

Use immutable released packages where suitable, otherwise build exact pinned
tags with their own lockfiles in separate source directories and install roots.
Do not switch the developer's active checkout back and forth. Record source
commit, artifact hash, PostgreSQL major, features and dependency versions.
Use isolated test clusters, ports and controlled HTTP endpoints, never a user's
running database or external production services.

1. Install and run the **old binary and its matching SQL**. Let that binary
   initialize the provider and create actual test state, graphs and histories.
2. Run workflows to asserted durable checkpoints. Verify engine history records,
   operation/version identities and application side effects. Use signals,
   controlled responses and durable barriers, not arbitrary short sleeps.
3. Stop the cluster safely while retaining its complete data directory and
   outstanding work. Snapshot it while stopped, with normal PostgreSQL backup/
   restore constraints. Replace the binary and packaged extension files;
   restart PostgreSQL so both preloaded code and worker processes are new.
4. **B1: binary-only path.** Leave `pg_extension.extversion` unchanged. Verify
   provider migrations/readiness, resume old work, check old results/vars,
   run new work on the old schema, and drive loops through multiple generations.
5. **B2: binary plus SQL path.** Restore an independent copy of the same old
   checkpoint, load the candidate, apply `ALTER EXTENSION UPDATE` while selected
   work is still parked, and then resume it. Also cover a delayed SQL update
   after some work has progressed under B1 conditions.
6. Assert engine and `df` states agree, no replay errors or lost signals/children
   occur, intended results/control flow match, and already-recorded successful
   activities are not repeated merely because of replay. Include interrupted
   activity retry cases without claiming external exactly-once execution.

Both B1 and B2 are necessary: B1 covers deferred schema upgrades; B2 covers SQL
migration/dependency/privilege interactions with real historical state. Do not
complete all workflows in B1 and then call B2 an in-flight migration test.
Exercise an ordinary maintenance stop first, then targeted abrupt-stop recovery
in isolated clusters.

The operator runbook must distinguish engine state from the `df` status mirror,
report unsupported/unknown history rather than declaring it safe, and preserve
diagnostics when replay fails. Audit the existing terminal-state reconciliation
gap described in [loop rework problems](loop_rework_problems.md) and add
failure-injection coverage; do not expand this into an unrelated cleanup of all
items in that review. Back up before binary replacement: automatic provider
migrations may already have run before a deferred extension SQL update, so
putting the old library back is not a supported rollback procedure.

### Coverage and release matrix

**Current scope:** finite SQL, timer loops, completed/partially executed 13-leaf
SQL sequences, and retained/refreshed permission cohorts; opt-in historical
execution, automatic harness unit tests, and unchanged default A/B1/B2 coverage.
Provider versions and applied migrations are recorded, but a provider-version
transition has not yet been exercised. The full chain is
useful for characterization and pre-release investigation, but rerunning its
immutable historical prefix on every PR is not yet a requirement. Reusing a
versioned pre-candidate checkpoint may later reduce cost, subject to PostgreSQL
backup/restore and provenance constraints; no checkpoint-distribution system is
part of this PR.

Grow the corpus incrementally, including sanitized real pipelines from downstream
consumers. Request their source versions and upgrade paths, required setup,
typical in-flight states, expected outputs and side effects (including duplicate
tolerance), and local external-service substitutes. Retain provenance without
credentials or customer data. Add intermediate releases or targeted transition
tests when an early failure masks the boundary being investigated.

**Future target, before advertising broad guarantees:** cover sequences before/after recorded SQL, IF/IF_ROWS and
both branch outcomes, named results and placeholder-like values, JOIN/RACE
(including completed children retained in parent history), root/nested/parallel
loops, conditions and break propagation, continue-as-new state, timers and cron,
signals in root/children, SQL/HTTP/multipart success and failure, pending retries,
cancellation, status finalization and caller/new-transaction admission.
Include completed/failed/cancelled instances and custom dependent objects/grants.

Exercise rare boundaries using genuine old-handler-produced fixtures or focused
legacy-handler tests: loop iteration limits, transaction-admission compaction,
typed errors and serialization. A hand-authored history or a current-binary
fixture must not be mislabeled as a released-binary fixture.

Once the support policy is approved, proposed gates for every supported
PostgreSQL major are:

- PR gates: A/B1/B2 for the supported catalog set, released-binary B1/B2 from the oldest promised
  replay baseline and the latest release, and frozen protocol/history fixtures
  from every distinct released protocol family. Include Scenario D safe-refusal
  and concurrency coverage for guarded migrations and coordination changes.
- Release gates: direct source-to-candidate B1/B2 coverage for every promised
  released source (or a documented, justified equivalence grouping), including
  previous binaries that created work on a still-older supported `df` schema.
  Every source must appear as covered, not silently skipped.
- Negative controls: known pre-baseline replay-breaking transitions or deliberate
  test mutations must fail. This proves the harness detects the class of failure
  the old tests missed.

Retain all distinct released histories and expected results. Testing only the
baseline never exercises formats introduced in later minors; testing only the
previous release does not prove skipped-version upgrades.

## Implementation sequence and acceptance criteria

The current milestone is the discovery harness, initial measured results,
opt-in execution and regression validation of the original suite. The sequence
below is a future enforcement proposal, conditional on the evidence and policy
decisions; it is not the acceptance checklist for merging this foundation.

| Step | Work and primary files | Done when |
|---|---|---|
| 1. Approve contract and scope | Turn this proposal into a concise public compatibility policy; inventory the SQL/API/config/platform/experimental surface. Resolve historical documentation discrepancies. | The 1.0 adoption baseline, 1.x support promise and exclusions are explicit; no version number has been used to hide an unsupported path. |
| 2. Capture immutable baselines | Add a supported-source/protocol manifest and old-runtime fixture producers under upgrade-test infrastructure; pin v0.2.8 artifacts and earlier diagnostic sources. | Fixtures are demonstrably produced by the declared released binaries, with checkpoint and expected-output provenance. |
| 3. Implement certification coverage | Expand released-binary B1/B2 to the approved direct-upgrade source set; strengthen catalog coverage and remove major-only source-selection assumptions. | Old-catalog support still runs across the adoption major boundary; every promised source resumes representative and boundary workflows with and without SQL update. Negative controls fail as expected. |
| 4. Establish runtime versioning | Update `src/registry.rs`, orchestration organization, input codecs, relevant activities and shared helpers. Bootstrap without changing legacy history. | Old and new handler families coexist; child/CAN routing cannot accidentally upgrade a legacy execution; replay-neutral changes are demonstrated, not assumed. |
| 5. Guard schema upgrades and prove safe refusal | Define migration capability requirements, persisted execution identity and a bounded admission/worker coordination protocol; add the guard to new upgrade scripts and Scenario D to upgrade tests. | Compatible updates pass with live work; unsafe or unclassifiable updates refuse without changing protected state or stranding work. Concurrent admissions, inspection errors and transaction cleanup are covered. Released-binary B1/B2 prove binary and provider compatibility independently. |
| 6. Add contributor and automated gates | Update `.github/copilot-instructions.md`, `CONTRIBUTING.md`, a PR template and CI. Require compatibility classification for runtime/helper/schema/dependency/API/config changes; compare API/C bindings and released SQL against frozen baselines. | Every relevant PR supplies legacy/new-path evidence. Published SQL/fixtures cannot change silently. Catalog/handler source sets cannot shrink without explicit reviewed policy. |
| 7. Enforce release decisions | Update `prompts/pg_durable-release.md`, package/release workflows and required checks. Tie compatibility evidence and version classification to the exact release commit/artifacts. | New features cannot ship as patches; incompatible 1.x changes are blocked. Every advertised PG major is blocking, or explicitly unsupported. Missing/empty/skipped compatibility matrices fail the release gate. |
| 8. Prepare and publish 1.0 | Update Cargo package/lock metadata, target upgrade script, generated metadata/fixtures, changelog, user/API docs and release notes. | All gates pass on the exact candidate; supported old sources have an actionable runbook; version and package metadata agree. Tag/publish only after separate approval. |

Steps 1-3 precede claims of continuity; step 4 must itself pass step 3. Step 5
builds on that independently verified continuity, not the reverse. Steps 6-7 make
the policy durable beyond this work. If a runtime regression is discovered during
preparation, fix it with compatibility dispatch/versioning instead of moving the
baseline forward to excuse the regression.

The current CI makes PG18 test failures non-blocking, even though packages are
published for PG17 and PG18. Either make PG18 a required compatibility gate
before promising it in 1.0 or clearly narrow the support statement. Repository
ruleset/branch-protection changes need maintainer approval in addition to adding
workflow YAML.

AI/contributor guidance must require: an explicit upgrade-impact section;
legacy input and serialized-output fixtures; review of transitive orchestration
helpers; versioned changes when durable decisions differ; retained old activity
handlers/C wrappers; immutable shipped DDL; and real provider/replay testing for
`duroxide`/`duroxide-pg` dependency updates. A human reviewer remains responsible
for compatibility classification; static diffs and SemVer parsers cannot prove
arbitrary workflow semantics.

For 1.0, the current unshipped 0.2.9 additions can become the 0.2.8 -> 1.0.0
upgrade. If 0.2.9 ships first, freeze that release, retain its upgrade script, add
0.2.9 -> 1.0.0, and test both runtime sources. Do not rewrite an already shipped
0.2.8 -> 0.2.9 script. Supporting old extension schemas still requires capability
detection; runtime-handler version selection must not use `extversion` as a
proxy for the binary that produced history.

Communicate the outcome as "1.0 establishes stable API and durable-upgrade
guarantees," with a short supported-upgrades table and operational instructions.
Keep historical warnings discoverable without making a retrospective apology the
headline. Preserve real deployment/security caveats, including the evaluation-only
Docker configuration: a 1.0 number is not an SLA or a claim that every packaging
default is production-safe.

SemVer reference: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).
