# Upgrade Incompatibilities

pg_durable's pre-1.0 releases introduced incompatible changes, including between
patch releases within 0.2.x. Version numbers alone therefore do not establish
compatibility of existing applications, permissions, or running workflows.
[SemVer's major-zero rule](https://semver.org/spec/v2.0.0.html#spec-item-4)
allows instability before 1.0; the warning here is about actual upgrade behavior,
not a claim that breaking changes in 0.x violate SemVer.

This inventory starts at 0.2.2, the beginning of the current duroxide provider
compatibility line, and includes the unreleased 0.2.9 candidate. It combines
release documentation with historical upgrade measurements. It is not an
exhaustive compatibility guarantee. The [methodology](upgrade-discovery.md)
describes the tested chain, fixtures and coverage limits; the
[upgrade testing plan](upgrade-testing.md) describes the existing suite.

## Reading the inventory

- **Documented:** attributed to a release by its changelog or upgrade notes;
  not necessarily exercised by the historical tests.
- **Tested:** observed in the recorded historical runs, only for the stated
  source/destination versions and fixtures.
- **Inferred:** a consequence identified from released code or upgrade SQL,
  without a reproducing historical test.

Rows identify the version introducing a documented change. An observed upgrade
destination is not automatically the introducing version: the tested
0.2.2 -> 0.2.5 replay failure spans intermediate releases. Persistent problems
are listed once, not presented as newly introduced in every later version.
Read all intervening rows when skipping releases.

The binary column includes runtime behavior, configuration, durable replay and
duroxide provider migrations applied at worker startup. These can change before
`ALTER EXTENSION UPDATE`. The SQL column covers that command's changes to the
extension catalog, data access and grants. New functions needing explicit grants
are distinguished from regressions in existing operations.

## Version inventory

| Version | Binary replacement: runtime and replay | SQL schema update: API, data and permissions |
|---|---|---|
| 0.2.2 | **Baseline:** first version with `duroxide-pg` as the duroxide provider. | |
| 0.2.3 | **Documented:** empty conditions now evaluate false; graph limits, connection timeout, result/error behavior and default worker role change. These paths were not isolated by historical binary tests. [Details](#023) | **Documented:** upgraded databases retain their existing duroxide provider schema; the fresh-install namespace change is not an upgrade break. [Details](#023) |
| 0.2.4 | **Documented:** node-status and schedule changes break affected in-flight histories; listing/expansion limits, retention and completion-wait behavior change. **Tested:** node-status mismatch observed over 0.2.2 -> 0.2.5, not an isolated 0.2.4 test. [Details](#024) | **Documented:** removes `df.debug_connection()`; dependencies or invalid legacy node rows can block the upgrade; node-key/index rebuilds require locks. [Details](#024) |
| 0.2.5 | **Documented:** existing JOIN/RACE branches fail replay; loops may fail. These are distinct from the node-status mismatch measured across the wider 0.2.2 -> 0.2.5 transition. [Details](#025) | **Tested:** multipart access is not added to existing HTTP grants, and HTTP-inclusive delegation fails. **Inferred:** replacing the three-argument `df.start()` can block upgrades with dependent objects. [Details](#025) |
| 0.2.6 | **Documented:** substitution no longer rescans inserted values; transient graph envelopes change; independent-start concurrency is capped. Replay consequences of substitution changes were not tested. [Details](#026) | **Documented:** removes `df.ensure_durofut()`; dependencies can block the upgrade. [Details](#026) |
| 0.2.7 | **Documented:** restricted HTTP requests now require HTTPS; corrected URL parsing can reject previously accepted URLs. Outbound HTTP was not tested. [Details](#027) | **Tested:** administrator-only re-grants do not repair existing delegated users' grants. [Details](#permission-gaps-and-delegation-failures) |
| 0.2.8 | **Documented:** histories recording the old loop-limit terminal failure cannot replay. This boundary was not exercised. [Details](#028) | **Documented:** legacy loop function OID/dependencies are retained; the signature change alone is not a demonstrated break. [Details](#028) |
| 0.2.9 (unreleased) | **Documented:** HTTP build features are replaced by startup configuration; preserve the intended policy explicitly. This later change is outside the recorded candidate run. [Details](#029-unreleased) | **Tested:** new endpoint overloads are not added to existing HTTP grants; HTTP-inclusive delegation fails until re-granted. Existing SQL access remained usable. [Details](#permission-gaps-and-delegation-failures) |

## Version details and actions

### 0.2.2

**Documented**, for installations or applications originating before 0.2.2:

- The duroxide provider changes to crates.io `duroxide-pg`. Earlier duroxide provider state is
  outside this upgrade line; extension SQL alone does not establish a state
  migration path. Plan any such migration separately.
- JOIN results become arrays of objects instead of double-encoded JSON strings;
  remove the extra JSON-unescaping step in consumers. SQL results preserve richer
  column types instead of treating every value as a string. Review result
  decoders and status comparisons, including the `cancelled` spelling.
- Variable setup helpers are rejected in workflow composition. Move session
  variable setup outside graph construction.

Source: [0.2.2 release notes](../CHANGELOG.md#022---2026-05-28).
The historical tests create baseline state on 0.2.2; they do not test any
pre-0.2.2 upgrade or prove continuity across the duroxide provider boundary.

### 0.2.3

**Documented**, for applications using 0.2.2 behavior: zero-row IF/LOOP conditions
now evaluate false; graphs deeper than 256 levels or larger than 10,000 nodes
are rejected; user connections time out after 30 seconds. Non-finite SQL floats
become JSON `null` rather than failing, and execution-history lookup errors are
surfaced rather than hidden. The default worker role changes to `postgres`.
Review branching, graph sizes, result/error handling and explicitly configure
the intended worker role. These are behavior changes, not measured replay
failures in the historical chain.

**Documented:** `_duroxide` is the namespace for fresh installs, while upgrades
retain `duroxide` and old schemas remain usable through runtime fallback. Do not
rename the existing duroxide provider schema as part of an upgrade.

Sources: [0.2.3 release notes](../CHANGELOG.md#023---2026-06-17) and
[upgrade notes](upgrade-testing.md). The 0.2.3 catalog was inspected using the
destination chain binary; the 0.2.3 binary was not a separate test state.

### 0.2.4

**Documented**, for histories created under 0.2.3 or earlier: adding
`instance_id` to `update-node-status` changes recorded activity inputs, and
moving schedule-time calculation into the orchestration changes the history
sequence for pending `wait_for_schedule` timers. Quiesce new starts and drain
affected work before replacing the binary, or plan to cancel and recreate it.
The [measured node-status failure](#replay-failure-after-binary-replacement)
supports the risk but does not isolate the first breaking binary.

**Documented runtime changes:** listing requests above the configured cap now
error (default 1,000 rather than silent truncation at 10,000); `$name.*`
expansion gains a 10,000-row cap; loops gain a finite iteration guard. Retention
and hard-cap pruning can remove terminal instances. Review pagination,
expansion size, loop lifetime and retention settings before replacement.

**Documented SQL changes:** removing `df.debug_connection()` breaks subsequent
calls and can block the upgrade when dependent objects exist. Replace those
dependencies first. The node primary-key migration can fail on legacy rows with
NULL `instance_id`; inspect and repair such rows before upgrading. Key and index
rebuilds take locks, so schedule the SQL update with appropriate maintenance
and lock-timeout limits. These migration prerequisites are not data-loss
observations from the historical run.

**Inferred from released code:** `df.wait_for_completion()` remains a deprecated
alias, not a removed API. Its call to `df.await_instance()` rejects use inside a
workflow, so replace that pattern with durable signal coordination. The
[v0.2.4 implementation](https://github.com/microsoft/pg_durable/blob/v0.2.4/src/dsl.rs)
and [upgrade SQL](../sql/pg_durable--0.2.3--0.2.4.sql) retain the old binding.
Likewise, the upgrade SQL preserves existing PUBLIC access to `df.metrics()`;
the stricter fresh-install grant policy is not an observed upgrade privilege loss.

Sources: [0.2.4 release notes](../CHANGELOG.md#024---2026-07-02) and
[upgrade notes](upgrade-testing.md). Neither the alias behavior nor the
schedule, pruning and limit paths were exercised by the historical fixtures.

### 0.2.5

**Documented**, independently of the earlier node-status change: JOIN/RACE
branches scheduled under 0.2.4 or earlier have different `execute-subtree`
inputs from the new binary and fail replay. Changed loop scheduling and inputs
can also fail replay. Drain affected work before replacement or plan to recreate
it; inspect engine status because the `df` status mirror can remain stale.
The historical SQL sequences do not test JOIN/RACE, and the baseline timer loop
fails first on node-status replay, so it does not isolate the loop-specific break.

**Tested SQL update effect:** new multipart rights are absent from existing
HTTP grants. This is a new-capability gap; failure of an existing administrator's
HTTP-inclusive delegation is a separate existing-operation regression. Re-grant
the administrator with grant option and explicitly re-grant intended users;
an administrator re-grant does not propagate to them. See the
[permission measurements](#permission-gaps-and-delegation-failures).

**Inferred SQL update risk:** the
[upgrade script](../sql/pg_durable--0.2.4--0.2.5.sql) drops the three-argument
`df.start()` before creating its four-argument replacement. Default arguments
preserve ordinary calls, and the binary retains the old wrapper for old schemas,
but catalog objects depending on the old function OID can block the drop.
Inspect and recreate such dependencies; custom dependency/ACL preservation for
this replacement was not established by the historical fixtures.

Sources: [0.2.5 release notes](../CHANGELOG.md#025---2026-07-30) and
[upgrade notes](upgrade-testing.md).

### 0.2.6

**Documented runtime changes:** variable substitution becomes single-pass;
placeholder-like text inside inserted values is no longer rescanned. Review
queries relying on recursive expansion. Whether this changes an already-recorded
activity input depends on its values and history; that replay path was not tested.
Transient Durofut envelopes change shape, while persisted nodes are documented
as unaffected; do not assume saved intermediate composition values are portable.
Independent starts default to two concurrent launches; excess starts can time out.
Review launch concurrency and configure the admission limits as needed.

**Documented SQL update effect:** `df.ensure_durofut(text)` is removed with
`RESTRICT`. Replace direct calls and remove or repoint dependent objects before
upgrading. Built-in operators are updated first, and old cataloged helpers
continue to work before the SQL update.

Sources: [0.2.6 release notes](../CHANGELOG.md#026---2026-08-23),
[upgrade SQL](../sql/pg_durable--0.2.5--0.2.6.sql) and
[upgrade notes](upgrade-testing.md). The 0.2.6 binary was not tested separately.

### 0.2.7

**Documented**, for HTTP-enabled restricted builds: requests must use HTTPS,
and URL validation and transport now use the same parsed URL. Plaintext requests
and URLs relying on the former validation discrepancy can stop working at
binary replacement without a SQL update. Switch to HTTPS and review destination
URLs. This corrects security behavior but still changes accepted requests.

Source: [0.2.7 release notes](../CHANGELOG.md#027---2026-08-31).
The historical run checked HTTP privileges, not outbound request execution;
it provides no measurement of these transport paths.

### 0.2.8

**Documented**, for loops that recorded the old terminal-failure path at
iteration 100,000: the new 8,388,608-iteration backstop changes the replay path.
Drain before reaching the old boundary when continuity is required, or plan to
recreate affected work. The ordinary timer-loop fixture does not reach that
boundary and cannot validate it.

**Documented SQL preservation:** the old `df.loop(text,text)` function is renamed
internally while keeping its OID and dependencies; a new public signature adds
an optional argument. Existing graphs remain fail-fast by default. Do not label
the signature change itself as a demonstrated break.

Sources: [0.2.8 release notes](../CHANGELOG.md#028---2026-09-11),
[upgrade SQL](../sql/pg_durable--0.2.7--0.2.8.sql) and
[upgrade notes](upgrade-testing.md). The 0.2.8 catalog was inspected, but its
binary was not a separate historical test state.

### 0.2.9 (unreleased)

**Documented configuration migration:** HTTP Cargo features are replaced by the
restart-required `pg_durable.http_security` setting, defaulting to `restricted`.
Previously HTTP-disabled installations must explicitly select `disabled` before
restart to retain that policy. Review custom/test allow-lists and build flags;
an explicit domain list replaces defaults, and invalid configuration can prevent
startup. Pending HTTP activities and retries use the new policy; recorded
activity results replay without making another request. This runtime change
needs no extension SQL update and was added after the recorded candidate tests.

**Tested SQL update effect in the earlier candidate:** new endpoint overloads
require explicit grants, and HTTP-inclusive delegation can fail until those
rights are re-granted. Existing raw-URL APIs are retained. Re-grant the intended
administrators and users as described in the
[permission measurements](#permission-gaps-and-delegation-failures); new
endpoint provisioning is not covered by those measurements.

Sources: [unreleased notes](../CHANGELOG.md#029---unreleased),
[HTTP configuration migration](http-security.md#upgrade--migration) and
[upgrade notes](upgrade-testing.md). Candidate behavior can still change before
release; the recorded runs do not validate later runtime or dependency changes.

## Evidence

Historical runs followed 0.2.2 -> 0.2.5 -> 0.2.7 -> candidate 0.2.9, observing
binary replacement before each SQL schema update. Intermediate catalogs were
applied and inspected using the destination binary, not each intermediate
release's binary. No runtime incompatibilities are repaired by these tests.

Both runs used Linux, PostgreSQL 17.10 and locally rebuilt tagged sources with
debug `pg17`-only builds, not published release packages:

- September 23, 2026: finite SQL and timer-loop tests, candidate source commit
  `e175a2a9f6b72904ea6b04acce1c968496063775`.
- September 24, 2026: added SQL sequences and permission cohorts, candidate
  source commit `cd2ead8baafee0c9a46718ef86a0612cc9a0d1d0`. Uncommitted
  harness/fixture changes were identified by SHA-256 in the report; runtime
  sources were unchanged within that expansion.

Expanded local evidence is in `target/replay-expanded-evidence/report.json`,
with immutable per-run reports under its `runs/` directory. Generated evidence
is not checked in. Later documentation edits, final-newline fixes, fixture
role renames and rebasing onto newer runtime sources do not alter those retained
reports. The results below describe the recorded runs, not a new full-chain run
of the current harness or candidate binary.

## Replay failure after binary replacement

**Work created on 0.2.2 failed when the binary was replaced with 0.2.5, while
the extension catalog was still 0.2.2.** The affected cases were the baseline
timer loop and both partially executed 13-leaf SQL sequences. This happened
before `ALTER EXTENSION UPDATE`, not because of a SQL schema migration.

The engine error was `nondeterministic: schedule mismatch` for
`pg_durable::activity::update-node-status`. New activity input included
`instance_id` and `execution_id`, while the recorded input contained only
`node_id` and `status`. The test brackets the break between 0.2.2 and 0.2.5;
it does not experimentally identify the first breaking intermediate release.
The documented introduction of `instance_id` belongs to [0.2.4](#024);
the wider test also spans other changes and is not a separate reproduction of
each replay break documented for 0.2.4 and 0.2.5.

The failed sequences retained six or seven committed steps, depending on
shutdown/recovery timing, and never produced the successful final result.
Their grants and graph inspection still worked, distinguishing replay failure
from permission loss. Already-failed cases provide no evidence of live
continuity at later steps.

The controls limit the scope of this finding:

- All seven finite SQL cases completed with the expected result and a single
  insertion; retained results remained readable at every later step.
- The six later timer loops progressed at creation and every subsequent
  observation through the candidate SQL schema update.
- All 14 ordinary sequences completed and retained their results, 25-node
  graphs, owner access and ordered side effects.
- All ten sequences held in the five intermediate states completed after
  their next binary replacement or SQL schema update. The two final-state
  controls completed without a further transition: 26 of 28 sequences completed
  overall, with only the two baseline sequences failing.

## Status mirror does not report the replay failure

**The engine reported failure while `df.status()` still reported `running`**
for the baseline loop and both failed sequences. A `running` status alone is
therefore not evidence of progress or successful upgrade continuity. This is an
observed diagnostic limitation, not a separately established introduction in
0.2.5. Check engine status and actual progress before treating work as healthy.

Listings, instance information, nodes, execution summaries and graph explanations
remained available for all fourteen original finite/loop instances, including
the failed loop. The failed sequences also remained inspectable.

## Permission gaps and delegation failures

**Existing grants did not expand to include new restricted HTTP functions.**
HTTP-inclusive delegation by an unrefreshed administrator also failed after
those functions were added. Intermediate SQL catalog versions were actually
applied and inspected using the destination chain binary.

- At catalog 0.2.5, new `df.http_multipart(text,text,jsonb,jsonb,integer)` lacks
  EXECUTE for existing users and grant option for existing administrators.
  HTTP-inclusive `df.grant_usage` delegation errors with
  `permission denied for function http_multipart`; default SQL-only delegation
  still succeeds. Pre-existing SQL and plain-URL HTTP EXECUTE remain granted.
- At candidate catalog 0.2.9, both new endpoint overloads
  (`df.http(df.http_endpoint,...)`, `df.http_multipart(df.http_endpoint,...)`)
  are also ungranted. Unrefreshed administrator delegation now errors on `http`.
- No additional missing privileges were identified at intermediate catalogs
  0.2.3, 0.2.4, 0.2.6, 0.2.7 or 0.2.8. The multipart gap persisted without
  re-grants; this does not establish compatibility of every API at those versions.

Explicit re-grant checks restored administrator EXECUTE, grant options and
HTTP-inclusive delegation for the multipart function at catalog 0.2.7 and for
the endpoint overloads at candidate catalog 0.2.9.

**Refreshing only the administrator did not grant new capabilities to existing
users.** The explicitly re-granted repair-control user matched fresh user grants
at each re-grant check; the untouched user retained the gaps. To add the new
HTTP capabilities, a sufficiently privileged role must re-grant the
administrator with `include_http => true, with_grant => true`, and that
administrator must explicitly re-grant each intended user with
`include_http => true`.

No tested existing SQL privilege was lost. All five roles could construct/start
SQL, execute as their own role, use variables and read monitoring data at all
seven states. Both administrators could delegate default SQL-only usage;
ordinary users could not delegate.

New restricted API gaps are different from losing an existing privilege; the
HTTP-inclusive delegation failure is a regression in an existing operation.
A default `include_http => false` grant intentionally excludes HTTP. No outbound
HTTP calls or endpoint server/user-mapping provisioning were tested, and these
results are not an exhaustive API or privilege-escalation audit.

## Duroxide provider upgrade not exercised

**No duroxide provider version upgrade occurred in these runs.** Every selected artifact
pinned `duroxide-pg` 0.1.34 and had the same 21 applied migration records.
`provider_version_transition` was `false`; `duroxide` itself changed from 0.1.29
to 0.1.30 at the first binary boundary. These are the historical dependency
versions, not substitutions made by the test harness.

The observed replay failures are not evidence that a duroxide provider migration broke
work. Equally, retaining this unchanged duroxide provider state does not establish that
a future duroxide provider migration preserves data or running instances.
