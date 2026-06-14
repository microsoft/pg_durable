# Phase 2 — combinator-nesting test matrix

Part of the DSL automated-testing roadmap ([#232](https://github.com/microsoft/pg_durable/issues/232)).

A deterministic generator enumerates every combinator-**nesting** shape up to a
bounded depth, renders each to a self-contained pg_durable DSL E2E test with
marker leaves, runs them live, and asserts both the Phase 1 structural-invariant
oracle (`df.assert_structural_invariants`) **and** generator-known per-path
execution counts. The goal is broad, automatic coverage of *how combinators
compose* — the corner of the grammar humans rarely test exhaustively by hand.

## Layout

| Path | Committed? | What it is |
|---|---|---|
| `generator/` | ✅ yes | The standalone generator crate (std-only Rust, no pgrx dep). |
| `manifest.json` | ✅ yes | Golden regression baseline: every shape's id, signature, class, reason, DSL, and expected per-path counts. The `--check` determinism guard diffs against this. |
| `meta-manifest.json` | ✅ yes | Golden baseline for the **Phase 4** metamorphic relations (see below): every relation's id, name, rationale, both DSL programs, and expected observable. The same `--check` guard diffs against this. |
| `README.md` | ✅ yes | This file. |
| `sql/` | 🚫 gitignored | Live (clean) E2E tests, regenerated on demand. Holds both the Phase 2 `gen-*.sql` matrix and the Phase 4 `meta-*.sql` relations. |
| `quarantine/` | 🚫 gitignored | Known-failing E2E tests for documented product bugs, regenerated on demand. |

The `.sql` files are **derived artifacts** — they are never committed; CI
regenerates them from the generator crate. `manifest.json` is the only
generated output under version control, and it is what makes generation
auditable and deterministic.

## Regenerating

```bash
# default: --max-depth 2, combinators seq,if,loop,join,race, seeds included
make generate-matrix
# equivalently:
cargo run --manifest-path tests/e2e/generated/generator/Cargo.toml
```

This (re)writes `sql/*.sql` + `quarantine/*.sql` and refreshes `manifest.json`.

Useful flags (`--help` for the full list):

| Flag | Default | Purpose |
|---|---|---|
| `--max-depth N` | `2` | Maximum combinator-nesting depth. Depth-2 is the live CI budget. |
| `--combinators LIST` | `seq,if,loop,join,race` | Comma list; subset of `seq,if,loop,join,join3,race`. |
| `--full` | — | Shortcut for the full set including `join3`. |
| `--loop-iters K` | `2` | Iterations each generated loop runs (≥2 is what trips the loop bugs). |
| `--max-shapes N` | none | Cap (≥1) on the sorted shape list, applied **after** enumeration; bounds output size, not enumeration cost at high depth. |
| `--no-seeds` | — | Exclude the hand-written else/break seed shapes. |
| `--wait-timeout N` | `60` | Seconds each **live** test waits for completion. |
| `--quarantine-timeout N` | `10` | Seconds each **quarantined** test waits (they hang, so keep this short). |
| `--check` | — | Regenerate the manifest in memory and diff vs the committed copy. Non-zero exit on drift. |

### Determinism

Generation is a pure function of the CLI inputs — no clocks, no RNG, no
filesystem order. `cargo run … -- --check` regenerates the manifest and diffs it
against the committed `manifest.json`; any drift fails. Run it after touching the
generator and commit the refreshed `manifest.json` in the same change.

## Each shape, end to end

1. **Enumerate** — `shape.rs` builds the deduped set of nesting shapes for the
   requested depth and combinator set, plus a few hand-written seed shapes that
   exercise `else`/`break`.
2. **Render** — `render.rs` turns a shape into a DSL string. Every leaf is a
   `df.sql` marker that `INSERT`s into a shared `df_gen_trace(shape_id,
   node_path, iteration, wall_clock)` table. Each leaf knows its **node path**
   (e.g. `r.t.e` = root → then → else) and the renderer computes the **expected
   iteration count** for every path. `if` conditions are rendered to take a
   deterministic branch; `race` is rendered so the fast branch deterministically
   wins (slow branch sleeps); loops get a generated bounded-iteration condition.
3. **Isolate** — every trace row is tagged with the shape's unique `shape_id`,
   and every per-path count query is `shape_id`-scoped. This keeps shapes from
   contaminating each other's marker counts when the harness runs them in the
   same database (it runs sequentially, but isolation makes a shape's assertions
   independent of execution order and of earlier residue).
4. **Emit** — `emit.rs` writes a self-contained `.sql` test (truncate this
   shape's trace → `df.start` → `wait_for_completion` → assert
   `df.assert_structural_invariants` all pass → assert per-path counts match the
   generator's expectation → `TEST PASSED`) and a `manifest.json` entry.
5. **Run** — the E2E harness picks the files up (see below).

### Node path scheme

Every marker leaf carries a **node path** string (the `node_path` column in
`df_gen_trace`) built by walking from the root and appending one suffix per
combinator edge. The renderer computes the expected execution count per path;
the generated test asserts `COUNT(*)` per path matches. The suffixes
(`generator/src/render.rs`):

| Suffix | Combinator | Meaning |
|---|---|---|
| `r` | — | Root of the shape (the starting path). |
| `.0` / `.1` | `seq` | First step / second step. |
| `.0` / `.1` | `join` | First branch / second branch. |
| `.0` / `.1` / `.2` | `join3` | First / second / third branch. |
| `.t` / `.e` | `if` | `then` branch / `else` branch. |
| `.c` | `loop` | Loop **counter** marker (drives the bounded termination condition). |
| `.b` | `loop` | Loop **body** subtree (executes once per iteration). |
| `.w` / `.l` | `race` | **W**inner (fast) branch / **l**oser (slow) branch. |
| `.0` | `break` | The break node's marker (runs each iteration until the bound). |

Paths nest, so e.g. `r.t.b.0` = root → `if` then-branch → `loop` body → first
`seq` step. A losing `race` branch or an untaken `if` branch still gets a path,
but its expected count is `0` (the DSL node is emitted; it just never executes).

## Running the matrix

```bash
# Live (blocking) matrix — only tests/e2e/generated/sql/*.sql
./scripts/test-e2e-local.sh --include-generated

# Known-failing (non-blocking) matrix — only tests/e2e/generated/quarantine/*.sql
./scripts/test-e2e-local.sh --include-generated-quarantine
```

`--include-generated` globs **only** `sql/`, so quarantined shapes never block a
clean run. Both flags require the files to exist first (`make generate-matrix`).

## The loop bug, quarantine, and the xfail policy

Generating the depth-2 matrix surfaced a family of **pre-existing product
defects** in how loops behave when nested inside other combinators. Rather than
delete those shapes (losing coverage) or let them turn CI red (blocking
unrelated work), the generator **classifies** each shape and **splits** the
output:

- **live → `sql/`** — shapes expected to pass today. These are **blocking** in CI.
- **quarantine → `quarantine/`** — shapes that hit a known, filed product bug.
  Their generated test asserts the **correct** expected behavior, so it *fails*
  today. These run **non-blocking** (xfail) so the bug stays continuously
  documented and measured without gating merges.

At `--max-depth 2` the split is **128 live / 26 quarantined** (154 total).

### Quarantine reasons (depth-2)

| `reason` | Count | Shape family | Tracking |
|---|---|---|---|
| `loop-in-join` | 11 | a `loop` inside a `join`/`join3` branch | [#233](https://github.com/microsoft/pg_durable/issues/233) |
| `loop-in-race-winner` | 6 | a `loop` in a `race`'s winning branch | [#233](https://github.com/microsoft/pg_durable/issues/233) |
| `loop-in-seq-tail` | 6 | a `loop` after a sibling in a `seq` (not the first step) | [#227](https://github.com/microsoft/pg_durable/issues/227) |
| `loop-body-combinator` | 3 | a `loop` whose body is itself a combinator | [#230](https://github.com/microsoft/pg_durable/issues/230) |

**Common root cause:** `continue_as_new` (used by the loop node on every
continuing iteration) restarts *whichever orchestration is currently executing,
from its root*. That is only correct when the loop **is** the root. Nested under
another combinator, it restarts the wrong host orchestration (or reuses a
completed child id), so the second iteration fails terminally or silently
re-runs siblings. See the issues above; a single host-aware fix likely resolves
all three.

The classifier lives in `generator/src/shape.rs` (`is_problematic` /
`classify_for_quarantine`). Its output is pinned by the `EMPIRICAL_FAILS` table —
the 26 shape signatures observed to fail live at depth 2 — and the contract test
`is_problematic_matches_empirical_depth2_failset` asserts the classifier flags
*exactly* that set (the **128 live / 26 quarantined** split). So the split can't
silently drift: any classifier change that re-balances it fails that test until
`EMPIRICAL_FAILS` is updated in the same commit.

### Promotion path (xfail → live)

When a product bug is fixed:

1. Re-run `make generate-matrix`. The now-correct shapes still classify as
   quarantine (the classifier is intentionally conservative).
2. Confirm they pass: `./scripts/test-e2e-local.sh --include-generated-quarantine`
   should report the affected shapes green.
3. Remove the corresponding arm from the classifier in `shape.rs` and drop those
   signatures from `EMPIRICAL_FAILS`, updating the
   `is_problematic_matches_empirical_depth2_failset` contract test in the same
   commit, so those shapes generate into `sql/` and become **blocking**.
4. Regenerate, re-run `--check`, commit the refreshed `manifest.json`.

## Phase 4 — metamorphic relations

Part of the same roadmap ([#232](https://github.com/microsoft/pg_durable/issues/232)),
living in the **same generator crate** (`generator/src/meta.rs`). Where Phase 2
asks *"does this one program execute the way we computed?"*, Phase 4 asks *"do
two programs the runtime is **supposed to treat as equivalent** actually produce
the same observable result?"* — a metamorphic relation. We build a pair
`(program_a, program_b)` plus an equivalence predicate, run **both**, and assert
they agree.

### Labels, not paths

Phase 2 tags each marker by its **structural** `node_path` (`r`, `r.t`, `r.b.0`,
…). That works when comparing a program against *itself*, but two
structurally-different-yet-equivalent programs have **different** paths for the
*same logical leaf* — `seq(a, seq(b,c))` vs `seq(seq(a,b), c)` put leaf `b` at
different paths. So Phase 4 tags markers by a **stable leaf label** (`a`, `b`,
`c`): the same logical leaf gets the same label in **both** sides of the pair.

The **observable** of a run is the multiset `{label -> completed-count}` — the
`GROUP BY node_path` count over that run's trace rows. The **equivalence
predicate** is multiset equality. A leaf that never executes (an untaken `if`
branch, an abandoned `race` loser) writes no trace rows and so contributes `0`
automatically — e.g. `if(true, a, b) ≡ a` yields `{a:1}` on both sides.

### The registry

`registry()` returns the relations below; each asserts `observable(A) ==
observable(B)`. All seven hold under both the *correct* and the *current*
runtime.

| id | name | A | B | observable |
|---|---|---|---|---|
| `meta-0001` | seq-assoc | `seq(a, seq(b,c))` | `seq(seq(a,b), c)` | `{a:1, b:1, c:1}` |
| `meta-0002` | if-true | `if(T, a, b)` | `a` | `{a:1}` |
| `meta-0003` | if-false | `if(F, a, b)` | `b` | `{b:1}` |
| `meta-0004` | join-comm | `join(a, b)` | `join(b, a)` | `{a:1, b:1}` |
| `meta-0005` | race-winner | `race(a, sleep(N))` | `a` | `{a:1}` |
| `meta-0006` | do-while-once | `loop(a, COUNT(a) < 1)` | `a` | `{a:1}` |
| `meta-0007` | loop-break-once | `loop(seq(a, if(COUNT(a) >= 1, break)))` | `a` | `{a:1}` |

### Each relation's test, end to end

`meta.rs` renders one `sql/meta-NNNN.sql` per relation. It reuses Phase 2's exact
marker / `if` / `loop` / `race` / `break` DSL, so the leaf semantics are
identical. Both programs run in the **same** `df_gen_trace`, tagged
`meta-NNNN-a` / `meta-NNNN-b` for isolation. The test:

1. `df.start` **both** programs, then `wait_for_completion` and assert **both**
   reach `completed`.
2. Assert `df.assert_structural_invariants` passes for **both** instances (the
   Phase 1 oracle — each side must be internally well-formed).
3. **Headline:** `observable(A) == observable(B)` via an `EXCEPT`-based multiset
   symmetric difference over `(SELECT node_path, COUNT(*) … GROUP BY node_path)`;
   assert the diff is empty.
4. **Backstop:** assert each side's per-label counts equal the generator-computed
   expected multiset, plus a `NOT IN (<labels>)` guard that no **unexpected**
   label appears.

The backstop matters because the Phase 1 invariants are **pure-state** (they
never count executions), so the headline `A == B` check alone would pass if
*both* sides symmetrically **over-executed** (e.g. `{a:2}` on both). The backstop
pins each side to absolute ground truth and closes that blind spot.

### Why loops don't pollute the observable

A naive bounded loop needs a counter leaf, which would add a spurious label. So
the loop relations instead make the termination condition count an **existing
body leaf** (the anchor): `loop(a, COUNT(a) < 1)` runs the body once (loops are
do-while — body first, then condition — see `docs/dsl-semantics.md`), re-checks,
finds `COUNT(a) = 1`, and stops. No synthetic counter; the observable stays
exactly `{a:1}`.

### Why `race(a, sleep(N))` is sound

The race loser is a bare `df.sleep(N)` that contributes nothing: when the marker
wins, duroxide abandons the sleep the instant the winner completes (no added
latency). The oracle accepts this — its `race` invariant only requires **≥1**
completed branch and its reachability check ignores abandoned losers
(`src/invariants.rs`) — so the winner-only program validates cleanly.

### Live-only, v1

Every relation holds under the **current** runtime because none nests a loop in a
non-root / `join` / `race` position — the [#227](https://github.com/microsoft/pg_durable/issues/227)
/ [#230](https://github.com/microsoft/pg_durable/issues/230) /
[#233](https://github.com/microsoft/pg_durable/issues/233) bug zone. So Phase 4
needs no quarantine split: `meta-*.sql` are all **live / blocking**. A natural
future extension is **bug-seeding** metamorphic relations — e.g. a loop-at-root
program paired with an equivalent loop-nested-non-root one — which would *fail*
until those loop bugs are fixed; deferred until the relations above are confirmed
live in CI.

### Running / regenerating

`make generate-matrix` (or the bare `cargo run …`) writes `sql/meta-*.sql`
alongside `gen-*.sql` and refreshes `meta-manifest.json`. The live harness picks
them up with the **same** flag — no new flag needed:

```bash
# runs gen-*.sql AND meta-*.sql (both live in sql/)
./scripts/test-e2e-local.sh --include-generated
```

`cargo run … -- --check` diffs **both** `manifest.json` and `meta-manifest.json`,
so metamorphic-relation drift fails CI exactly like Phase 2 shape drift.

## Phase 3 — property-based testing (proptest)

Phase 2 enumerates a *fixed, exhaustive* depth-2 matrix; Phase 4 pins *seven
hand-written* equivalences. Phase 3 generalizes both: a recursive
[`proptest`](https://proptest-rs.github.io/proptest/) `Strategy<Meta>`
(`generator/src/prop.rs`) emits **thousands of random labeled-leaf trees per
run** and asserts algebraic + structural properties over them — and, when a
property fails, proptest **shrinks** the random tree down to a *minimal*
counterexample.

### Why the model, not live PostgreSQL

Phase 3's headline value-add over Phase 2 (per the issue) is **shrinking**, and
shrinking only works when the property executes **in-process**: proptest drives
the reduction loop by re-running the predicate on progressively smaller inputs.
A property that round-trips through a live `df.start()` cannot shrink. So the
properties run over the same pure reference model Phase 4 already trusts — the
`Meta` interpreter (`eval`/`observable`) and the renderer (`render_prog`) — which
is the std-only analogue of the issue's `FunctionGraph`. This is not a coverage
downgrade: exhaustive depth-2 **live** oracle coverage already exists (Phases
2+4), and because Phase 4's live ground-truth is *computed by `eval`*, every
property that hardens `eval` strengthens the live suite transitively.

### What it checks

`proptest! { … }` runs 12 properties over `Meta` trees (each shrinking-enabled,
`PROPTEST_CASES` random trees apiece); the same block also runs Phase 5's 6
causal-order properties over `Shape` trees — see [Phase 5](#phase-5--reference-interpreter--causal-order-oracle):

| # | Property | Catches |
|---|----------|---------|
| 1 | `eval` is deterministic | hidden state / ordering bugs |
| 2 | **differential**: `eval` vs an independent functional `ref_observable` over the whole random space | interpreter logic errors (anti-circular; a Phase-5 bridge) |
| 3–8 | metamorphic **algebra** on random subtrees: seq-assoc, join-comm, join-assoc, seq≡join multiset, if-true/false selection, race→winner | generalizes Phase 4's 7 hand cases to thousands |
| 9 | loop multiplier scales body counts (DoWhile `k` / LoopBreak `n`, 1..=4) | off-by-one / saturating-mul bugs |
| 10 | total completed-count is conserved across equivalent forms | silent over/under-execution |
| 11 | `render_prog` is deterministic | non-reproducible SQL |
| 12 | rendered SQL is **well-formed**: balanced parens (ignoring `$mk$`/`$c$` dollar-quoted spans), even dollar-quote counts, no leaked `df.start`, `df.race(`/`df.sleep(` and `df.loop(`/`df.break()` arity matches the tree, every label present | renderer corruption |

Four helper unit tests (`mod helper_tests`) cross-check the *independent oracles*
themselves (`ref_observable`, `first_executing_label`, `node_counts`, the
paren-balancer) against hand cases, so a bug in the test scaffolding can't mask a
bug in the model.

### The strategy

`arb_meta()` is a `prop_recursive(4, 48, 3, …)` over weighted `prop_oneof!`
knobs (seq=3, join=2, if=2, race=1, dowhile=1, loopbreak=1) with labels from a
small alphabet (`a`–`e`). Loop anchors are chosen via `first_executing_label`
(the first leaf the body actually executes), so every generated loop terminates
and counts a real leaf — keeping the observable pure, exactly like Phase 4. The
strategy can emit `loop`-in-`join`/`race` shapes (the
[#227](https://github.com/microsoft/pg_durable/issues/227)/[#230](https://github.com/microsoft/pg_durable/issues/230)/[#233](https://github.com/microsoft/pg_durable/issues/233)
defect zone), so a future live harness inherits corpus coverage there.

### Failure corpus

When a property fails, proptest writes the minimal seed to
`generator/proptest-regressions/prop.txt` and **replays it first on every
subsequent run**. That file is committed (LF-normalized via `.gitattributes`) so
a counterexample becomes a permanent, shared regression guard. It is empty today
because no property has failed.

### Isolation — goldens stay byte-identical

`proptest` is a **`[dev-dependencies]`** entry only. The generation binary
(`cargo run` / `--check`) never links it, so `manifest.json` (187896 B) and
`meta-manifest.json` (7730 B) stay byte-for-byte identical, and `prop.rs` is
`#[cfg(test)] mod prop;` — it compiles only under `cargo test`.

### Running

```bash
# committed corpus + 1024 fresh random trees per property (override the budget):
make proptest
PROPTEST_CASES=8192 make proptest

# or directly — the default in-code budget is 256 cases:
cargo test --manifest-path tests/e2e/generated/generator/Cargo.toml
```

## Phase 5 — reference interpreter & causal-order oracle

Phases 2 and 4 differential-test **counts** and **multisets** against the live
duroxide runtime (via `df_gen_trace`). Neither checks **order**: that two events
on the same path happened in iteration order, that a `seq` ran its left side
*before* its right, or that two `join` branches were genuinely *unordered*.
Phase 5 adds that missing dimension with a **reference interpreter**
(`generator/src/refinterp.rs`) — a synchronous, single-threaded tree-walker over
`Shape` that produces, per program, a **pomset** (partially-ordered multiset):

- **events** — a deterministic linearization of `(node_path, iteration)` rows,
  exactly the columns the live marker writes into `df_gen_trace`; and
- **edges** — the happens-before (`≺`) relation as forward index pairs
  `(earlier, later)`.

It implements the [`docs/dsl-semantics.md`](../../../docs/dsl-semantics.md)
ordering contract *directly* (§4 Seq: all-of-`a` ≺ all-of-`b`; §6 do-while loop:
body ≺ counter and iteration `i` ≺ `i+1`; §7 Join/Join3: branches **concurrent**,
no edge; §7 Race: winner-only; §5 If: taken branch only). Concurrent siblings get
**no** edge, so the relation is a DAG by construction (`all_edges_point_forward`).

### A third, independent interpreter

The renderer (`render`) computes per-path counts in **closed form** (arithmetic
`mult`). The interpreter computes them by **step-by-step simulation**. They are
written independently, so agreement is strong evidence both are correct —
`counts_match_render(shape, k)` projects the pomset to per-path counts and
asserts equality with `render(shape, k, …).expected` (filtered to the reachable
paths the interpreter emits). The headline unit test runs that differential over
the **entire depth-2 matrix** (`shapes_up_to(&ALL_COMBS, 2)` + seeds) × every
`k ∈ {1, 2, 3}`. This is a *third* interpreter alongside Phase 4's `eval` and
Phase 3's `ref_observable` — three implementations of the same semantics, each
guarding the others.

### Causal-order properties (proptest)

The same `proptest! { … }` block adds **6 properties over random `Shape` trees**
(`arb_shape()`, the node-path-tagged analogue of `arb_meta()`), each shrinking-
enabled:

| # | Property | Catches |
|---|----------|---------|
| 13 | **differential**: interpreter counts == `render`'s closed-form `expected`, for every tree and every `k ∈ 1..=3` | divergence between simulation and arithmetic |
| 14 | interpreter is deterministic (identical events **and** edges) | hidden ordering / state bugs |
| 15 | every happens-before edge points strictly forward (`u < v`) | cyclic / self-contradictory order |
| 16 | per path, iterations are the dense range `1..=count` | gaps / duplicate iteration numbers |
| 17 | **causal-order law (Seq)**: `Seq(a,b)` preserves each child's edge set exactly and adds only forward `a ≺ b` cross edges — non-empty iff both sides execute | sequencing that drops, reorders, or fails to impose happens-before |
| 18 | **causal-order law (Join)**: `Join(a,b)`'s edge set is **exactly** `a`'s edges ∪ `b`'s (shifted) — no cross edge either way | spurious ordering between parallel branches |

Properties 17–18 are the order-level analogues of Phase 4's count laws and are
Phase 5's unique value-add: 17 proves `seq` *introduces* happens-before, 18 proves
`join` *introduces none* — the two facts a live wall-clock assertion would rely
on. 14 further unit tests (`refinterp::tests`) pin each combinator against the
§4–§7 contract by hand.

### Staged scope

This slice is **Step 1**: the model-level interpreter, its differential, and the
causal-order properties — all of which run in-process and need no live PostgreSQL.
`refinterp.rs` is `#[cfg(test)] mod refinterp;` and `emit.rs` is untouched, so the
generation binary never links it and **both goldens stay byte-identical**
(`manifest.json` 187896 B, `meta-manifest.json` 7730 B).

**Step 2** (deliberately *not* in this slice) would close the loop to the live
runtime: emit a causal-order assertion block into each **clean** (non-quarantined)
Phase 2 `.sql` test — for every `≺` edge, assert `u.wall_clock < v.wall_clock`,
leaving concurrent pairs unconstrained so there is no flakiness. Because the
live loop already pauses `LOOP_MIN_ITER_DURATION` (≥1s) between iterations, cross-
iteration margins are robust. Step 2 regenerates `manifest.json` and requires a
live-PG matrix run, so it is gated behind an explicit decision rather than folded
in here. `Pomset::ordered_pairs()` already exposes exactly the edge list that
block would consume.

### Running

```bash
# the interpreter's unit tests + the 6 causal-order properties run with the suite:
cargo test --manifest-path tests/e2e/generated/generator/Cargo.toml
PROPTEST_CASES=8192 make proptest   # widen the random Shape budget too
```

## CI

CI regenerates the matrix, runs the live set as a blocking gate, runs the
quarantine set non-blocking (`continue-on-error`), and runs `--check` to enforce
determinism. The live set and the determinism guard both cover the Phase 4
`meta-*.sql` relations and `meta-manifest.json` automatically — the same generate
step emits them, `--include-generated` runs them, and `--check` diffs their
golden. The generator's unit tests (run as their own blocking gate) include the
Phase 4 interpreter and registry tests. The depth-2 live budget is sized to stay
within the E2E job's time envelope; deeper profiles are available on demand via
`--max-depth`.

The same `Generated Matrix` job also gates Phase 3: a `cargo clippy --all-targets
-D warnings` step lints the `#[cfg(test)]` proptest module, and the existing
`cargo test` step runs the properties — replaying the committed
`proptest-regressions/` corpus first, then exploring `PROPTEST_CASES` (256 on
PRs) fresh random trees per property. A **nightly / on-demand** step widens that
budget with a fresh seed to hunt for new counterexamples; it is non-blocking
(mirroring the quarantine nightly) and surfaces any minimal counterexample it
writes for a human to commit as a permanent regression seed.
