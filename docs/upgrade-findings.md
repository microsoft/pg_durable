# Measured upgrade incompatibilities

These findings come from local tests of 0.2.2 -> 0.2.5 -> 0.2.7 -> candidate
0.2.9, observing binary replacement before each SQL schema update. They describe
the tested workflows and roles, not blanket compatibility of those versions.
The [methodology](upgrade-discovery.md) documents the chain, fixtures, commands
and coverage limits. No runtime incompatibilities are repaired by these tests.

## Evidence

Both runs used Linux, PostgreSQL 17.10 and locally rebuilt tagged sources with
debug `pg17`-only builds, not published release packages:

- September 23, 2026: finite SQL and timer-loop tests, candidate source commit
  `e175a2a9f6b72904ea6b04acce1c968496063775`.
- September 24, 2026: added SQL sequences and permission cohorts, candidate
  source commit `cd2ead8baafee0c9a46718ef86a0612cc9a0d1d0`. Uncommitted
  harness/fixture changes were identified by SHA-256 in the report; runtime
  sources were unchanged.

Expanded local evidence is in `target/replay-expanded-evidence/report.json`,
with immutable per-run reports under its `runs/` directory. Generated evidence
is not checked in. Later documentation edits, final-newline fixes and fixture
role renames do not alter those retained reports. The results below describe the
recorded runs, not a new full-chain run of the current harness.

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
therefore not evidence of progress or successful upgrade continuity.

Listings, instance information, nodes, execution summaries and graph explanations
remained available for all fourteen original finite/loop instances, including
the failed loop. The failed sequences also remained inspectable.

## Permission gaps and delegation failures

**Existing grants did not expand to include new restricted HTTP functions.**
HTTP-inclusive delegation by an unrefreshed administrator also failed after
those functions were added. Intermediate SQL catalog versions were actually
applied and inspected using the destination chain binary.

| Catalog transition | Without re-grant |
|---|---|
| 0.2.2 -> 0.2.3 -> 0.2.4 | No missing privileges relative to a fresh grant at the same catalog. Existing SQL access remained usable. |
| 0.2.4 -> 0.2.5 | New `df.http_multipart(text,text,jsonb,jsonb,integer)` lacks EXECUTE (and admin grant option). HTTP-inclusive `df.grant_usage` delegation errors with `permission denied for function http_multipart`; default SQL-only delegation still succeeds. Pre-existing SQL and plain-URL HTTP EXECUTE remain granted. |
| 0.2.5 -> 0.2.6 -> 0.2.7 -> 0.2.8 | Multipart gap persists; no additional missing privileges in this fixture. |
| 0.2.8 -> candidate 0.2.9 | Both new endpoint overloads (`df.http(df.http_endpoint,...)`, `df.http_multipart(df.http_endpoint,...)`) are also ungranted. Unrefreshed admin delegation now errors on `http`. |

Explicit re-grant checks restored administrator EXECUTE, grant options and
HTTP-inclusive delegation for the multipart function at catalog 0.2.7 and for
the endpoint overloads at candidate catalog 0.2.9.

**Refreshing only the administrator did not grant new capabilities to existing
users.** The explicitly re-granted repair-control user matched fresh user grants
at each re-grant check; the untouched user retained the gaps.

No tested existing SQL privilege was lost. All five roles could construct/start
SQL, execute as their own role, use variables and read monitoring data at all
seven states. Both administrators could delegate default SQL-only usage;
ordinary users could not delegate.

New restricted API gaps are different from losing an existing privilege; the
HTTP-inclusive delegation failure is a regression in an existing operation.
A default `include_http => false` grant intentionally excludes HTTP. No outbound
HTTP calls or endpoint server/user-mapping provisioning were tested, and these
results are not an exhaustive API or privilege-escalation audit.

## Provider upgrade not exercised

**No provider-version upgrade occurred in these runs.** Every selected artifact
pinned `duroxide-pg` 0.1.34 and had the same 21 applied migration records.
`provider_version_transition` was `false`; `duroxide` itself changed from 0.1.29
to 0.1.30 at the first binary boundary. These are the historical dependency
versions, not substitutions made by the test harness.

The observed replay failures are not evidence that a provider migration broke
work. Equally, retaining this unchanged provider state does not establish that
a future provider migration preserves data or running instances.