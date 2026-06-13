// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Renders a [`Shape`] into a pg_durable DSL expression and the exact per-path
//! execution counts the resulting durable instance must produce.
//!
//! Every marker leaf is a `df.sql` node that appends one row to the shared
//! `df_gen_trace` table, tagged with its node path. The renderer walks the tree
//! once, emitting the DSL string and, in lockstep, the ground-truth count each
//! path is expected to reach. Those counts are what the generated SQL test (and
//! the committed manifest) assert against.
//!
//! Rendering conventions that make the expected counts deterministic:
//! - **loop**: `df.loop(seq(body, counter), 'COUNT(counter) < K')` → the body runs
//!   exactly `K` times (do-while). Each enclosing loop multiplies child counts by `K`.
//! - **if**: the condition is a constant (`SELECT true`/`SELECT false`); the untaken
//!   branch is reachable=false → its markers are expected 0 (and stay pending).
//! - **race**: the left child wins deterministically; the right child is wrapped in
//!   `df.sleep(RACE_LOSER_DELAY_SECS)` and is abandoned (races are
//!   complete-on-winner) → its markers are expected 0.

use crate::shape::{Cond, Shape};
use std::collections::BTreeMap;

/// Seconds the losing race branch sleeps so the winner finishes first. Because
/// duroxide races are complete-on-winner (`execute_race_node` → `select2`), only
/// the dropped loser future waits this long — it adds no latency to a passing
/// test. The value must exceed the winner's runtime; it is safe at depth 2 where
/// every winner is a single `INSERT`.
const RACE_LOSER_DELAY_SECS: u64 = 2;

/// A rendered shape: the DSL expression plus its ground-truth per-path counts.
pub struct Rendered {
    pub dsl: String,
    /// Map of node path → number of times that marker is expected to execute.
    /// Unreachable markers are present with an expected count of 0.
    pub expected: BTreeMap<String, u64>,
}

/// Renders `shape` to DSL + expected counts, using `loop_iters` (K) iterations
/// for every generated loop. Every trace row is tagged with `shape_id` so
/// concurrent instances (e.g. a zombie left by a hung shape) cannot pollute
/// another shape's path counts — the marker INSERT, the loop-termination
/// condition, and the break condition all filter on `shape_id`.
pub fn render(shape: &Shape, loop_iters: u64, shape_id: &str) -> Rendered {
    let mut expected = BTreeMap::new();
    let dsl = build(shape, "r", true, 1, loop_iters, shape_id, &mut expected);
    Rendered { dsl, expected }
}

/// The `df.sql` marker node for `path`: appends one trace row whose `iteration`
/// is the next ordinal for that `(shape_id, path)` pair.
///
/// The `MAX(iteration) + 1` subquery and the INSERT are not one atomic
/// statement, but concurrent join/race branches always write *distinct*
/// `node_path`s (`.0`/`.1`/`.w`/`.l`/…), so two writers never contend for the
/// same `(shape_id, path)` ordinal; sequential re-entry inside a loop body is
/// single-threaded. The test's real correctness check is the per-path `COUNT(*)`
/// assertion, not the exact `iteration` value, so no UNIQUE constraint is needed
/// (and one could only cause spurious failures).
fn marker_sql(path: &str, shape_id: &str) -> String {
    format!(
        "df.sql($mk$INSERT INTO df_gen_trace (shape_id, node_path, iteration, wall_clock) \
VALUES ('{shape_id}', '{path}', (SELECT COALESCE(MAX(iteration), 0) + 1 FROM df_gen_trace \
WHERE shape_id = '{shape_id}' AND node_path = '{path}'), clock_timestamp())$mk$)"
    )
}

fn record(expected: &mut BTreeMap<String, u64>, path: &str, count: u64) {
    *expected.entry(path.to_string()).or_insert(0) += count;
}

/// Recursively renders `shape` at `path`.
///
/// * `reachable` — whether this subtree actually executes (false under an untaken
///   `if` branch or a losing `race` branch). Controls expected counts only; the
///   DSL node is always emitted so the graph still contains it.
/// * `mult` — execution multiplier from enclosing loops (root = 1).
/// * `k` — loop iteration count.
fn build(
    shape: &Shape,
    path: &str,
    reachable: bool,
    mult: u64,
    k: u64,
    shape_id: &str,
    expected: &mut BTreeMap<String, u64>,
) -> String {
    match shape {
        Shape::Marker => {
            record(expected, path, if reachable { mult } else { 0 });
            marker_sql(path, shape_id)
        }
        Shape::Seq(a, b) => {
            let sa = build(
                a,
                &format!("{path}.0"),
                reachable,
                mult,
                k,
                shape_id,
                expected,
            );
            let sb = build(
                b,
                &format!("{path}.1"),
                reachable,
                mult,
                k,
                shape_id,
                expected,
            );
            format!("df.seq({sa}, {sb})")
        }
        Shape::If {
            then_b,
            else_b,
            cond,
        } => {
            let then_reach = reachable && *cond == Cond::True;
            let else_reach = reachable && *cond == Cond::False;
            let st = build(
                then_b,
                &format!("{path}.t"),
                then_reach,
                mult,
                k,
                shape_id,
                expected,
            );
            let se = build(
                else_b,
                &format!("{path}.e"),
                else_reach,
                mult,
                k,
                shape_id,
                expected,
            );
            format!("df.if($c${}$c$, {st}, {se})", cond.sql())
        }
        Shape::Loop(body) => {
            let cpath = format!("{path}.c");
            let inner = mult.saturating_mul(k);
            let sb = build(
                body,
                &format!("{path}.b"),
                reachable,
                inner,
                k,
                shape_id,
                expected,
            );
            record(expected, &cpath, if reachable { inner } else { 0 });
            let counter = marker_sql(&cpath, shape_id);
            let cond = format!(
                "SELECT COUNT(*) < {k} FROM df_gen_trace \
WHERE shape_id = '{shape_id}' AND node_path = '{cpath}'"
            );
            format!("df.loop(df.seq({sb}, {counter}), $c${cond}$c$)")
        }
        Shape::Join(a, b) => {
            let sa = build(
                a,
                &format!("{path}.0"),
                reachable,
                mult,
                k,
                shape_id,
                expected,
            );
            let sb = build(
                b,
                &format!("{path}.1"),
                reachable,
                mult,
                k,
                shape_id,
                expected,
            );
            format!("df.join({sa}, {sb})")
        }
        Shape::Join3(a, b, c) => {
            let sa = build(
                a,
                &format!("{path}.0"),
                reachable,
                mult,
                k,
                shape_id,
                expected,
            );
            let sb = build(
                b,
                &format!("{path}.1"),
                reachable,
                mult,
                k,
                shape_id,
                expected,
            );
            let sc = build(
                c,
                &format!("{path}.2"),
                reachable,
                mult,
                k,
                shape_id,
                expected,
            );
            format!("df.join3({sa}, {sb}, {sc})")
        }
        Shape::Race(a, b) => {
            // `execute_race_node` uses duroxide `select2` (complete-on-winner):
            // the parent proceeds the instant either branch finishes and the
            // loser future is dropped. The left branch is a marker that completes
            // immediately, so it wins deterministically; the right branch is
            // delayed by `RACE_LOSER_DELAY_SECS` so it is still pending at the
            // finish and its markers stay expected=0 (reachable=false below).
            let sw = build(
                a,
                &format!("{path}.w"),
                reachable,
                mult,
                k,
                shape_id,
                expected,
            );
            let sl = build(b, &format!("{path}.l"), false, mult, k, shape_id, expected);
            format!("df.race({sw}, df.seq(df.sleep({RACE_LOSER_DELAY_SECS}), {sl}))")
        }
        Shape::LoopBreak { n } => {
            let mpath = format!("{path}.0");
            record(
                expected,
                &mpath,
                if reachable {
                    (*n as u64).saturating_mul(mult)
                } else {
                    0
                },
            );
            let marker = marker_sql(&mpath, shape_id);
            let break_cond = format!(
                "SELECT (SELECT COUNT(*) FROM df_gen_trace \
WHERE shape_id = '{shape_id}' AND node_path = '{mpath}') >= {n}"
            );
            format!(
                "df.loop(df.seq({marker}, df.if($c${break_cond}$c$, df.break(), $c$SELECT 1$c$)), \
$c$SELECT true$c$)"
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m() -> Box<Shape> {
        Box::new(Shape::Marker)
    }

    #[test]
    fn single_marker_runs_once() {
        let r = render(&Shape::Marker, 2, "gen-0001");
        assert_eq!(r.expected.get("r"), Some(&1));
        assert!(r.dsl.starts_with("df.sql("));
    }

    #[test]
    fn seq_runs_both_children_once() {
        let r = render(&Shape::Seq(m(), m()), 2, "gen-0001");
        assert_eq!(r.expected.get("r.0"), Some(&1));
        assert_eq!(r.expected.get("r.1"), Some(&1));
        assert!(r.dsl.starts_with("df.seq("));
    }

    #[test]
    fn if_true_takes_then_else_zero() {
        let r = render(
            &Shape::If {
                then_b: m(),
                else_b: m(),
                cond: Cond::True,
            },
            2,
            "gen-0001",
        );
        assert_eq!(r.expected.get("r.t"), Some(&1));
        assert_eq!(r.expected.get("r.e"), Some(&0));
    }

    #[test]
    fn if_false_takes_else_then_zero() {
        let r = render(
            &Shape::If {
                then_b: m(),
                else_b: m(),
                cond: Cond::False,
            },
            2,
            "gen-0001",
        );
        assert_eq!(r.expected.get("r.t"), Some(&0));
        assert_eq!(r.expected.get("r.e"), Some(&1));
    }

    #[test]
    fn loop_runs_body_k_times() {
        let r = render(&Shape::Loop(m()), 2, "gen-0001");
        assert_eq!(r.expected.get("r.b"), Some(&2));
        assert_eq!(r.expected.get("r.c"), Some(&2)); // counter marker
    }

    #[test]
    fn nested_loops_multiply() {
        let r = render(&Shape::Loop(Box::new(Shape::Loop(m()))), 2, "gen-0001");
        // inner body runs 2 (outer) * 2 (inner) = 4 times.
        assert_eq!(r.expected.get("r.b.b"), Some(&4));
        // inner counter runs 4 times; outer counter runs 2 times.
        assert_eq!(r.expected.get("r.b.c"), Some(&4));
        assert_eq!(r.expected.get("r.c"), Some(&2));
    }

    #[test]
    fn race_winner_runs_loser_zero() {
        let r = render(&Shape::Race(m(), m()), 2, "gen-0001");
        assert_eq!(r.expected.get("r.w"), Some(&1));
        assert_eq!(r.expected.get("r.l"), Some(&0));
        assert!(r.dsl.contains("df.sleep(2)"));
    }

    #[test]
    fn join_in_loop_covers_230() {
        // L(J(M,M)) — the #230 join-inside-loop bug pattern.
        let r = render(&Shape::Loop(Box::new(Shape::Join(m(), m()))), 2, "gen-0001");
        assert_eq!(r.expected.get("r.b.0"), Some(&2));
        assert_eq!(r.expected.get("r.b.1"), Some(&2));
    }

    #[test]
    fn loop_break_runs_n_times() {
        let r = render(&Shape::LoopBreak { n: 3 }, 2, "gen-0001");
        assert_eq!(r.expected.get("r.0"), Some(&3));
        assert!(r.dsl.contains("df.break()"));
    }

    #[test]
    fn marker_sql_has_no_unbalanced_quotes() {
        let r = render(&Shape::Seq(m(), m()), 2, "gen-0001");
        // Dollar-quoted marker/condition tags must be balanced.
        assert_eq!(r.dsl.matches("$mk$").count() % 2, 0);
    }

    #[test]
    fn shape_id_scopes_every_trace_predicate() {
        // The shape_id must appear in the INSERT, the iteration subquery, and the
        // loop-termination condition so foreign instances cannot pollute counts.
        let r = render(&Shape::Loop(m()), 2, "gen-0042");
        assert!(r.dsl.contains("shape_id, node_path, iteration, wall_clock"));
        assert!(r.dsl.contains("VALUES ('gen-0042'"));
        assert!(r.dsl.contains("WHERE shape_id = 'gen-0042' AND node_path"));
    }
}
