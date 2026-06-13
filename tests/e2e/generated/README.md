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
| `README.md` | ✅ yes | This file. |
| `sql/` | 🚫 gitignored | Live (clean) E2E tests, regenerated on demand. |
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

## CI

CI regenerates the matrix, runs the live set as a blocking gate, runs the
quarantine set non-blocking (`continue-on-error`), and runs `--check` to enforce
determinism. The depth-2 live budget is sized to stay within the E2E job's
time envelope; deeper profiles are available on demand via `--max-depth`.
