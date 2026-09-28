# Historical upgrade testing methodology

The local runner in [scripts/upgrade_replay.py](../scripts/upgrade_replay.py)
builds older pg_durable releases and lets them create real graphs, execution
histories, results and grants before upgrading the same database. The purpose
is to test what happens to existing work, not just whether a new binary can
create new work using an old schema. See the [upgrade incompatibility inventory](upgrade-incompatibilities.md)
for documented changes and measured results, and the [upgrade testing plan](upgrade-testing.md) for the
existing suite and contributor workflow.

## What the transitions test

The chain observes two distinct deployment actions:

- **Binary replacement:** stop PostgreSQL, replace the `.so` and packaged SQL
  files, and restart without changing the installed extension catalog. Check
  that the new binary works on the old schema, resumes old work and can read
  retained data. The new worker also applies its embedded duroxide provider migrations.
- **SQL schema update:** with the newer binary already running, apply
  `ALTER EXTENSION UPDATE`. Check that pre-existing data, grants and surviving
  work remain usable after the catalog changes. Apply and inspect each
  intermediate SQL version, with surviving loops and held SQL sequences present.

Old-schema compatibility and old-data compatibility are not interchangeable.
Replay can fail immediately after binary replacement, before any extension SQL
update. Conversely, successful replay does not prove that a later SQL update
preserves grants or dependent objects.

The default upgrade suite uses the candidate binary for both data creation and
validation. It tests schema correctness, all previous compatible schemas, and
data retention across SQL updates. This historical chain supplements those
checks; it does not replace their variables, grants, dependent-object or HTTP
catalog assertions.

## Build environment and chain

PostgreSQL stays fixed throughout one run. The initial supported environment is
Linux with PostgreSQL 17, Python 3.11+, cargo-pgrx 0.16.1 and a Rust toolchain
that can build all selected releases. The runner builds exact tags with their
lockfiles and the working-tree 0.2.9 candidate, using debug builds with only the
`pg17` feature. It refuses builds that change the lockfile. No HTTP feature is
enabled. The release tags must be present locally.

These are locally rebuilt tagged sources, not downloaded release binaries.
Each release uses its own manifest and lockfile, including its historical
dependencies; sources are exported without switching the developer's checkout.
Testing published packages is deferred.

| Step | Action | Binary | Extension catalog |
|---|---|---|---|
| 0 | Baseline | 0.2.2 | 0.2.2 |
| 1 | Binary replacement | 0.2.5 | 0.2.2 |
| 2 | SQL schema update | 0.2.5 | 0.2.5 |
| 3 | Binary replacement | 0.2.7 | 0.2.5 |
| 4 | SQL schema update | 0.2.7 | 0.2.7 |
| 5 | Binary replacement | 0.2.9 candidate | 0.2.7 |
| 6 | SQL schema update | 0.2.9 candidate | 0.2.9 |

## Workflow fixtures

Each step starts two original instances from
[tests/upgrade/replay.sql](../tests/upgrade/replay.sql): one finite SQL insertion
and one root loop that inserts a progress mark and waits on a one-second durable
timer. Loops advance independently; their iteration counts need not match
phases. A bounded observation window checks positive progress for every surviving
loop, rather than accepting a `running` status alone. Finite instances must
complete with the expected result and exactly one insertion, and their results
are rechecked at later steps. This is not an exactly-once guarantee for arbitrary
activities interrupted by maintenance.

Each step also starts four SQL-only sequences: a completed and a held sequence
under each of two non-superuser users. Each graph has 13 SQL leaves and 12
left-associated THEN nodes (25 nodes, depth 12), submitted with two-argument
`df.start()`. The network-free leaves in
[tests/upgrade/sequence.sql](../tests/upgrade/sequence.sql) build an ordered
running total in regular tables. Every step verifies the invoker role; duplicate
committed steps violate a primary key. The held variant commits steps 1-6 and
blocks inside the seventh SQL leaf until the next upgrade has finished. There
are no durable SLEEP, SIGNAL or LOOP nodes in these graphs. The last step
releases all sequences because no further upgrade follows.

Graph links, query payloads, ownership, node count/depth, ordered side effects,
engine and `df` status, owner-readable nodes and the final result (91) are checked
and retained. Ordinary work and timer progress are measured before parking new
SQL leaves, which otherwise occupy worker/user-connection capacity. A held SQL
activity can be retried after maintenance; this fixture detects unexpected
duplicate commits but does not promise exactly-once external side effects.

## Permission fixtures

Permission cohorts start on 0.2.2: a superuser grants each administrator
`include_http => true, with_grant => true`; each administrator grants its user
`include_http => true` with the default `with_grant => false`. One pair is never
refreshed. A second pair tests administrator-only re-grants at selected catalogs,
leaving its original user's grants unchanged. A separate repair-control user is
explicitly re-granted by that administrator. These cases compare retained access
with and without re-grants.

Snapshots compare function, schema and table-column privileges/grant options
against freshly granted reference roles at the same catalog version. Actual
non-superuser connections test construction, submission, SQL invoker identity,
variables, monitoring and delegation with both default and HTTP-inclusive grants.
HTTP privilege checks do not execute outbound requests or provision endpoint
servers/user mappings.

## Observations and diagnostics

Every step inspects engine and `df` status, results, instance listings, nodes,
execution summaries and `df.explain()`. The first failure is attributed to its
observed transition. Failed instances remain inspectable and are reported as
`previously_failed` at later steps, not as passing continuity checks. A new
inspection failure on an already-failed instance still fails the run.

Binary replacement starts the new worker over retained duroxide provider state before
any extension SQL update. Startup failure, stalled/replay-failed old work, lost
results and broken monitoring can therefore fail this harness even if
`ALTER EXTENSION UPDATE` has not run. The report captures locked
`duroxide`/`duroxide-pg` versions and the duroxide provider's `_duroxide_migrations`
ledger at every state, alongside histories and worker logs. A failure at binary
replacement alone does not prove a duroxide provider migration caused it.

## Running and retaining evidence

The default command continues to run the original upgrade suite. The chain is a
separate mode, not an additional test appended to that invocation. It always
stops its private cluster; `--keep` is not supported:

```bash
./scripts/test-upgrade.sh --pg-version 17
./scripts/test-upgrade.sh --pg-version 17 \
  --replay-chain "$PWD/target/replay-evidence" --allow-known-replay-breaks
```

Use a dedicated output directory, outside tracked source paths. It holds build
logs, source exports, lockfiles, package/source hashes, commit IDs, toolchain and
PostgreSQL versions, the latest `report.json`, and per-run reports/database/log/history
evidence. Cached packages are reused only when their recorded source, toolchain
and file hashes match; changed sources or incomplete builds require a new output
directory. Do not run two chains concurrently with the same output directory.
The data directory is retained for diagnosis but is not a portable replay fixture
or a supported downgrade mechanism. Evidence may contain workflow payloads; use
only synthetic or sanitized test data.

Exit codes are `0` for accepted results, `1` for compatibility-check failures,
and `2` for setup errors or incomplete phase coverage. Strict mode (omit
`--allow-known-replay-breaks`) fails on any observed break. The opt-in exception
accepts only the documented baseline loop/held-sequence `update-node-status`
schedule mismatches at the 0.2.2 to 0.2.5 binary replacement and the exact missing
HTTP grants and delegation errors in the [measured findings](upgrade-incompatibilities.md#evidence).
Despite the legacy flag name, this also covers those permission findings. It does not accept timeouts,
unrelated engine errors, damaged graphs, incorrect committed step values, lost
existing privileges or diagnostic failures. A green exception-enabled run does
not mean every workflow survived or every role has current-version capabilities.

For longer observation or different timeouts, invoke the Python runner directly:

```bash
python3 scripts/upgrade_replay.py --pg-config /path/to/pg17/bin/pg_config \
  --output-dir "$PWD/target/replay-evidence" \
  --observe-seconds 10 --timeout 60 --allow-known-breaks
```

CI runs the harness unit tests and original upgrade suite automatically. Full
historical execution is local-only, using the commands above; reports, provenance
and diagnostics remain in the output directory. CI integration is deferred.
Run this discovery mode before releases and when adding fixtures.

## Coverage limits

The chain tests selected graph shapes on one staged path, not whole features or
arbitrary histories. An instance that failed at an earlier step cannot establish
live compatibility with later binaries. The chain does not test direct
source-to-candidate jumps, all deferred-schema combinations, fresh `_duroxide`
lineage, PG18, release-profile/HTTP builds, abrupt crashes, or the exact
intermediate release that introduced a mismatch.

The sequence fixture tests one SQL graph shape and its authorization, not an
entire application. Pending starts before the first activity remain untested.
Permission fixtures use direct grants; they do not establish coverage of
inherited/group-role access, arbitrary custom grants or comprehensive cross-user
isolation. Removed/renamed functions are not classified as ACL loss.

Retained duroxide provider state alone does not establish duroxide provider upgrade coverage.
That requires a real old/new duroxide provider pair through compatible pg_durable
binaries, with scenarios exercising the changed duroxide provider features. See the
[measured duroxide provider limitation](upgrade-incompatibilities.md#duroxide-provider-upgrade-not-exercised).

Expand the fixture set incrementally: additional sequences, captures/substitution,
conditionals, JOIN/RACE, nested loops, signals and external activity behavior.
Add focused transition tests where an earlier failure masks a later boundary.
Add synthetic workflows with source versions, required
tables/configuration, typical waiting states, expected outputs/side effects and
local substitutes for external services. Report untested paths separately from
passed, failed and blocked-by-earlier-failure observations.

## Upgrade & Migration

The harness changes no runtime behavior, dependency versions or extension DDL.
No product upgrade script or runtime schema detection is needed. Existing
old-schema compatibility checks remain unchanged; the local chain adds
observations using data and histories produced by older binaries.
