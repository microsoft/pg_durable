# Fixed DSL shape and semantic corpus

This test-only corpus exercises nested sequences, conditionals, loops, joins,
and races using existing public DSL functions. It contains 154 fixed cases,
including all 26 loop nestings previously quarantined in
[#234](https://github.com/microsoft/pg_durable/pull/234). Every case is blocking.

In addition, 24 curated semantic cases exercise named results and variables,
and seven fixed metamorphic pairs compare equivalent marker effects. The
154 topology cases carry 225 explicit causal-order edges across 88 shapes.

The topology corpus, causal edges, and metamorphic relations originated with
Prashant Chinnam (@crprashant)'s work in #234 and
the proposal in [#232](https://github.com/microsoft/pg_durable/issues/232).
No shape generator is required or included. The committed manifest and runner
are sufficient to execute the suite, including from a squash-merged checkout.

## Fixed manifest and runner

- [manifest.json](manifest.json) is the version-2 source of truth. `shapes`
  retains the original IDs, signatures, depths, DSL, and marker counts, adding
  `order` edges. `semantic_cases` and `relations` contain complete programs and
  explicit expectations; each family has a checked count.
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

# Select result/variable cases or fixed metamorphic pairs
./scripts/test-e2e-local.sh --include-shapes sem-
./scripts/test-e2e-local.sh --include-shapes meta-0001

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
work. The additional oracles below cover selected ordering and value contracts,
not arbitrary SQL semantics or old-history replay compatibility. Definitions
and expectations still require review; schema validation cannot establish their
semantic correctness.

## Additional fixed oracles

### Causal order (`gen-*`)

Each `order` entry is `[earlier_path, earlier_iteration, later_path, later_iteration]`.
The runner checks positive iterations against the committed path counts, then
requires exactly one trace row at each endpoint and a lower `event_id` at the
earlier endpoint. Missing, duplicate, or NULL endpoints fail closed. An empty
edge list is valid for a single marker, unreachable work, or concurrent siblings.
No order is imposed between JOIN siblings.

The fixture adds a monotonically allocated `event_id` with sequence cache 1.
Cross-session sequence caching must not reserve out-of-order blocks. Ordinals
are not commit timestamps and need not be contiguous; only the committed
required edges are checked. This observes marker execution order, not activity
completion or a proof that independent operations ran concurrently.

The 225 edges were imported as fixed data from #234 at
`a3f589d2a7891a1e5235dd5bca215d23a2dfa2b1`. All 154 IDs, signatures, and count
maps matched #410. Its corrected modulo loop conditions realize those intended
counts, including re-entered inner-loop iterations. No reference interpreter or
edge derivation code is shipped.

### Exact observations (`sem-*`)

`public.df_gen_observe(shape_id, path, value)` records a `jsonb` observation and
returns the per-path iteration. It shares the marker table, schema-qualified
references, invoker privileges, and fixed search path with the count helper.
Each record declares `vars`, `post_start_vars`, terminal `status`, and an
`expected` array of `{path, iteration, value}` observations. Optional `result`
asserts the entire `df.result()` JSON payload. Expected values are compared as
JSONB: object key order is irrelevant, but array order, JSON types, missing
rows, SQL NULL, and JSON null remain significant.

Every observed event must be declared. Missing, duplicate, and unexpected rows
fail, including a forbidden downstream observation after an intentional error.
Failed cases require both their expected error substring and a prefix
observation, so an unrelated setup or execution failure cannot satisfy them.

| Cases | Contract |
|---|---|
| `sem-0001`–`sem-0002` | Scalar/final result, dot access, quoting, typed/structured values |
| `sem-0003`–`sem-0008` | Empty/NULL null-safe forms and strict failures |
| `sem-0009`–`sem-0010` | Multi-column row-set expansion and empty row sets |
| `sem-0011`–`sem-0012`, `sem-0022` | Named results across JOIN, loop, and RACE boundaries |
| `sem-0013`–`sem-0017` | Raw variable fragments, captured snapshot, branch/loop propagation |
| `sem-0018` | Actual instance ID/label and system-variable precedence |
| `sem-0019`–`sem-0021` | Non-recursive substitution and braced-before-result pass ordering |
| `sem-0023`–`sem-0024` | Result-name boundaries/reuse and a named conditional result |

The wrapper clears variables before setup and again after start/mutations,
before waiting or asserting. An optional `release_signal` then unblocks the
snapshot case; the named signal result must report `timed_out = false`. This
ensures consumption follows the mutation/clear without relying on sleeps.
These fixtures use only the dedicated E2E role's variables, which are disposable.
Start uses the default caller transaction in autocommit; separate-transaction
visibility and cross-user RLS remain covered by the handwritten suite.

Braced substitutions insert raw SQL fragments, not auto-quoted values. They
are single-pass within the braced phase, followed by named-result substitution;
the two-pass behavior is intentional. Result-value replacement is not rescanned.
The corpus does not change these production semantics.

### Metamorphic pairs (`meta-*`)

Each record stores `dsl_a`, `dsl_b`, a rationale, and a non-empty expected
multiset. Tags `<id>-a` and `<id>-b` isolate the two instances. Stable leaf labels
`r.a`, `r.b`, and `r.c` denote the same logical effect in both programs rather
than structural positions.

The seven relations are sequence associativity, constant-true/false IF
reduction, JOIN commutativity, fast RACE winner reduction, one-iteration
do-while, and immediate-break loop reduction. Both instances must complete.
The runner compares A and B in both directions, then independently requires
each side to match committed counts and rejects unknown/NULL labels.
Identically wrong programs therefore cannot pass by agreeing with each other.

Equivalence is only of marker multisets: JOIN output arrays, loop return
values, and scheduler order are not asserted equal. Sequence causal ordering
is covered independently by `gen-*` edges. The race relation retains the
30-second scheduling assumption below.

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

Edit the manifest directly to add or correct cases. For topology cases, supply a unique ID,
descriptive signature, DSL using existing public APIs and the test marker helper,
an explicit expected count for every marker (including unreachable markers), and
`"oracle": "exact-marker-counts"`, and explicit `order` edges (possibly empty).
Use `"oracle": "exact-observations"` for semantic records and
`"oracle": "equivalent-marker-counts"` for relation records. Update the respective
family count and document the reason. Version 1 is rejected explicitly; do not
silently run an older manifest without its new assertions.

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

Each family is reported as one E2E case; a relation starts two instances and
waits up to 60 seconds for each. Persistent diagnostic trace rows are retained
after assertions and deleted before reusing their case tags. Fixture columns
are added idempotently for databases left running with #410's older table.

The race assertions assume the intended winner finishes within the loser's
30-second delay. This is not a deterministic scheduling guarantee under load.
Concurrent batching and property-based exploration remain separate follow-ups.
No generator, reference interpreter, random/shrinking dependency, or production
structural-invariant SQL API is introduced.

## Upgrade & Migration

No production Rust, extension SQL API, version, dependencies, or schema changes
are needed. The B1 supported-schema contract is unchanged; no upgrade DDL or
runtime schema detection is required.

These tests start fresh instances. Curated, predecessor-compatible shapes in
[#409](https://github.com/microsoft/pg_durable/pull/409)'s real
N-1/B1/B2 upgrade lifecycle remain separate work.
