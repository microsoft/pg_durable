# Fixed DSL shape matrix

This test-only corpus exercises nested sequences, conditionals, loops, joins,
and races using existing public DSL functions. It contains 154 fixed cases,
including all 26 loop nestings previously quarantined in
[#234](https://github.com/microsoft/pg_durable/pull/234). Every case is blocking.

The corpus originated with Prashant Chinnam (@crprashant)'s work in #234 and
the proposal in [#232](https://github.com/microsoft/pg_durable/issues/232).
No shape generator is required or included. The committed manifest and runner
are sufficient to execute the suite, including from a squash-merged checkout.

## Fixed manifest and runner

- [manifest.json](manifest.json) is the source of truth: each record contains a
  shape ID, signature, depth, complete DSL expression, and expected marker counts.
- [runner.py](runner.py) validates the corpus and wraps those stored definitions
  in setup, start, wait, assertion, and cleanup SQL. It neither enumerates shapes
  nor recalculates expectations, and never writes the manifest.
- The [local E2E harness](../../../scripts/test-e2e-local.sh) prepares wrappers in
  a private temporary directory, runs each through its existing SQL execution
  path, and removes the directory on exit, including with `--keep`.

The manifest is now an executable test corpus, not a golden snapshot checked
against regenerated functions. Its original generation metadata is retained as
provenance, not as runner configuration. Changing `max_depth` or `loop_iters` in
the header does not change the stored definitions or their expected counts.

Python 3.9+ is required, with no third-party packages.

```bash
# Validate the corpus and run runner unit/CLI tests without PostgreSQL
python3 tests/e2e/shapes/runner.py --check
python3 -m unittest discover -s tests/e2e/shapes -p 'test_*.py'

# Execute all 154 cases, or select one using the existing filename filter
./scripts/test-e2e-local.sh --include-shapes gen-
./scripts/test-e2e-local.sh --include-shapes gen-0076

# Include the corpus alongside the handwritten E2E suite
./scripts/test-e2e-local.sh --include-shapes
```

Each case retains separate PASS/FAIL reporting. A failure does not prevent the
remaining cases from running; any failure makes the suite fail. Runs are
sequential, with a 60-second completion timeout per case. CI validates the
manifest, tests the runner, and executes the corpus with the existing E2E suite.

For wrapper diagnostics without starting PostgreSQL:

```bash
out=$(mktemp -d)
python3 tests/e2e/shapes/runner.py --out "$out"
# Inspect the per-case SQL in "$out"; remove those files and the directory afterward.
```

The runner rejects malformed manifests, duplicate IDs or JSON keys, invalid
paths/counts, unsupported oracle types, and nonempty output directories. The
DSL is trusted, repository-reviewed executable SQL, not untrusted input.

## What the assertions measure

Each marker is an ordinary SQL node calling
`public.df_gen_mark(shape_id, node_path)`. This test-fixture helper inserts one
row into `public.df_gen_trace`, tagged with `shape_id` and `node_path`, and assigns
`iteration = COALESCE(MAX(iteration), 0) + 1` for that shape/path pair.
After successful instance completion, the wrapper compares `COUNT(*)` for each
path with its stored expectation, including zero counts, and rejects unexpected
or NULL paths.
It does not obtain counts from `df.instance_info()` or production tables.

Paths describe locations in the shape, not runtime node IDs:

| Suffix | Meaning |
|---|---|
| `r` | root |
| `.0`, `.1` | sequence or two-way join child |
| `.t`, `.e` | then and else branch |
| `.b`, `.c` | loop body and its counter marker |
| `.w`, `.l` | intended race winner and loser |

For `L(L(M))` with two iterations per loop, `r.b.b` and `r.b.c` each have four
rows, and `r.c` has two. A marker's `iteration` column is diagnostic; assertions
check row counts, not ordinal values. Loop counter rows also drive termination.

Each standalone wrapper creates the persistent table and creates or replaces
the helper before starting its instance. Under the harness's psql autocommit,
the fixture is committed before worker connections need it; do not wrap the
test in a single transaction. Both objects belong to `df_e2e_user` in the test
database, not to the extension. They remain available for inspection and reuse.
The helper uses invoker privileges, a fixed `pg_catalog` search path, and an
explicit `public.df_gen_trace` reference. All corpus calls and trace reads are
schema-qualified, so activity connections do not depend on the caller's search
path. No session-local function or production SQL API is introduced.

The helper returns the inserted ordinal as an integer. Unlike the original
INSERT without RETURNING, its SELECT produces one result row. The live runner
test checks that the activity records this result correctly. Trace effects and
expected counts are preserved, but activity inputs/outputs are not byte-identical
to the earlier corpus; this is not an in-flight replay compatibility claim.

The count oracle detects missing, duplicate, and incorrectly selected marker
work. It does not prove causal order, returned values, arbitrary SQL semantics,
or old-history replay compatibility. Definitions and expectations still require
review; schema validation cannot establish their semantic correctness.

## How the current corpus was produced

The corpus was originally generated using the algorithm below, adapted from
#234, then reviewed and corrected. The generator is not shipped, and maintenance
does not rely on retrieving intermediate PR commits: squash merges do not
preserve them as ancestors of the merged commit.

The fixed corpus uses depth 2, two iterations per ordinary loop, and the
combinators `seq,if,loop,join,race`. Its 552 marker calls use the shared fixture
helper instead of repeating the INSERT, and trace-table references are
schema-qualified. The construction algorithm is:

1. Define `M` as a marker of depth 0. For depth `d > 0`, include `M`, then
   apply each combinator to every ordered tuple of children from depth `d - 1`.
   Loop is unary; sequence, conditional, join, and race are binary. Canonical
   conditionals select the then branch.
2. This produces 151 shapes at depth 2. Add three seeds: an else-taken
   conditional, that conditional followed by a marker, and a loop breaking
   after three iterations.
3. Deduplicate and sort by signatures (`M`, `S(a,b)`, `I(a,b)`, `L(a)`, `J(a,b)`,
   `R(a,b)`, plus `Ielse(a,b)` and `LB3` for seeds). Assign `gen-NNNN` IDs in
   that order. The current IDs are fixed; preserve them when adding cases.
4. Render each marker as a `public.df_gen_mark(shape_id, path)` call at its
   structural path. Sequence and join traverse both children. Conditionals
   traverse only the chosen branch
   for expected counts. Loop bodies and counter markers multiply their
   enclosing execution count by two. Unreachable markers have expectation zero.
5. Loop conditions use cumulative `COUNT(*) % 2 <> 0`, so they run twice on
   every entry without deleting trace evidence. The break seed stops when its
   count is a multiple of three. Race losers start with a 30-second sleep, and
   their markers have expectation zero.

The modulo predicate corrected an earlier generator bug: cumulative
`COUNT(*) < 2` made a re-entered inner loop stop too soon. The expectations were
not weakened. The corrected corpus passed all 154 PG17 cases; additional
historical checks through depth 3 with bounds 1, 2, and 3 produced deepest-body
counts of 1, 8, and 27. Those additional cases are not part of the fixed corpus.

## Maintaining the corpus

Edit the manifest directly to add or correct cases. Supply a unique ID,
descriptive signature, DSL using existing public APIs and the test marker helper,
an explicit expected count for every marker (including unreachable markers), and
`"oracle": "exact-marker-counts"`. Update `shape_count` and document the reason.

For a larger expansion, implement the algorithm above in a separate maintenance
task to produce candidate entries; no historical generator checkout is required.
Review the SQL and expectations independently before committing them. Merely
updating provenance metadata does not expand coverage. Do not adjust expectations from observed
results or quarantine failures just to make tests pass.

Run the runner tests and affected live cases, then the full corpus. The optional
live runner regression tests also verify that incorrect counts, unexpected
paths, and failed instances actually fail, and that helper ordinals, schema
resolution, invoker mode, and activity results are correct:

```bash
./scripts/test-e2e-local.sh --include-shapes gen- --keep
MATRIX_TEST_PSQL="$HOME/.pgrx/17.10/pgrx-install/bin/psql" PGPORT=28817 \
  python3 -m unittest discover -s tests/e2e/shapes -p 'test_*.py'
./scripts/pg-stop.sh
```

Use the installed PostgreSQL binary/version and matching port for your system.

## Isolation and timing limitations

The same manifest always supplies the same definitions and expectations.
Runtime instance IDs and scheduling are not repeatable. Each case deletes old
fixture rows for its shape before starting. This isolates different shapes,
not concurrent or still-running repeats of the same shape: do not run two
copies against one database.

The race assertions assume the intended winner finishes within the loser's
30-second delay. This is not a deterministic scheduling guarantee under load.
Concurrent batching, richer ordering assertions, and property-based exploration
remain separate follow-ups.

## Upgrade & Migration

No production Rust, extension SQL API, version, dependencies, or schema changes
are needed. The B1 supported-schema contract is unchanged; no upgrade DDL or
runtime schema detection is required.

These tests start fresh instances. Curated, predecessor-compatible shapes in
[#409](https://github.com/microsoft/pg_durable/pull/409)'s real
N-1/B1/B2 upgrade lifecycle remain separate work.
