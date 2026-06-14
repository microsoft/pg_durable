// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Phase 5 (#232): a synchronous, single-threaded tree-walking REFERENCE
//! INTERPRETER over [`Shape`] — the roadmap's strongest single oracle.
//!
//! # What it adds over Phases 2 and 4
//!
//! Phases 2 and 4 already differential-test the live duroxide runtime, but only
//! along the COUNT/MULTISET dimension: they assert *how many times* each marker
//! executed (`render::Rendered::expected`, `meta::observable`). They say nothing
//! about ORDER. Phase 5 adds the missing causal dimension: this interpreter
//! computes, for any program, the trace the runtime *should* produce as a
//! **pomset** — a partially-ordered multiset of `(node_path, iteration)` events
//! plus the happens-before (`≺`) relation — implementing the intended semantics
//! from `docs/dsl-semantics.md` directly:
//!
//! * **Seq** (§4): `a` fully precedes `b` (`all-of-a ≺ all-of-b`).
//! * **If** (§5): the condition is a `$c$…$c$` predicate, not a marker, so it
//!   emits no event; only the taken branch contributes.
//! * **Loop** (§6, do-while): each iteration runs `body` then the counter marker
//!   (`body ≺ counter`), and iteration `i` fully precedes iteration `i+1`.
//! * **Join / Join3** (§7): branches are CONCURRENT — no ordering edge between
//!   them (so a live assertion derived from this oracle never flakes on them).
//! * **Race** (§7): the winner runs; the loser is abandoned and emits nothing.
//! * **LoopBreak** (seed): the marker fires `n` times in sequence.
//!
//! # Why a second implementation is a real oracle
//!
//! `render::build` derives per-path counts in *closed form* (a single structural
//! pass multiplying by the loop factor `mult`). This interpreter instead derives
//! them by *simulating execution* step by step. Two independent implementations
//! of the same semantics agreeing (see [`counts_match_render`]) is a strong
//! correctness signal — and the projection of the pomset to per-path counts is
//! exactly the ground truth Phases 2/4 assert live, so this interpreter is the
//! bridge the issue asks Phase 5 to be.
//!
//! The live runtime records `(node_path, iteration)` (plus a `wall_clock`
//! column) into `df_gen_trace`, so the event set here is directly comparable to
//! the live trace, and each `≺` edge is directly checkable as
//! `earlier.wall_clock < later.wall_clock`. Emitting those order assertions into
//! the generated live tests is the gated Step 2 of this phase.

use crate::render::render;
use crate::shape::{Cond, Shape};
use std::collections::{BTreeMap, BTreeSet};

/// One observable trace event: the completion of a marker leaf at `node_path` on
/// its `iteration`-th execution (1-based), exactly as the live runtime records
/// it into `df_gen_trace(node_path, iteration, …)`.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(crate) struct Event {
    pub node_path: String,
    pub iteration: u64,
}

/// A pomset (partially-ordered multiset) of trace events: the causal trace the
/// runtime *should* produce for a program.
///
/// `events` is a deterministic linearization — a valid topological order in
/// which the markers fire — and `edges` is the happens-before (`≺`) relation as
/// `(earlier, later)` index pairs into `events`. By construction every edge
/// points forward (`u < v`), so the relation is trivially acyclic. CONCURRENT
/// events (e.g. sibling `join` branches) have NO connecting edge.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Pomset {
    pub events: Vec<Event>,
    pub edges: BTreeSet<(usize, usize)>,
}

impl Pomset {
    /// The order-erased projection: per-path execution counts. This is the
    /// multiset the COUNT-based oracles check (`render::Rendered::expected` in
    /// Phase 2, `meta::observable` in Phase 4); Phase 5 additionally pins the
    /// order via [`Pomset::ordered_pairs`].
    pub fn path_counts(&self) -> BTreeMap<String, u64> {
        let mut m = BTreeMap::new();
        for e in &self.events {
            *m.entry(e.node_path.clone()).or_insert(0) += 1;
        }
        m
    }

    /// The happens-before edges resolved to concrete `(earlier, later)` event
    /// pairs. Step 2 (live differential) emits, for each pair, an assertion that
    /// the earlier event's `wall_clock` precedes the later's in `df_gen_trace`.
    /// Concurrent siblings produce no pair, so such assertions never flake.
    pub fn ordered_pairs(&self) -> Vec<(Event, Event)> {
        self.edges
            .iter()
            .map(|&(u, v)| (self.events[u].clone(), self.events[v].clone()))
            .collect()
    }
}

/// A fragment of the trace under construction: the indices of a subtree's
/// minimal (`first`) and maximal (`last`) events within the shared event vector.
/// An unreachable or marker-free subtree returns an empty fragment.
struct Frag {
    first: Vec<usize>,
    last: Vec<usize>,
}

impl Frag {
    fn empty() -> Self {
        Frag {
            first: Vec::new(),
            last: Vec::new(),
        }
    }

    fn is_empty(&self) -> bool {
        // `first` empty iff `last` empty — a fragment either has events or not.
        self.first.is_empty()
    }
}

/// The interpreter state: the accumulating event list, the happens-before
/// edges, and a per-path execution counter that mirrors the live marker's
/// `(SELECT MAX(iteration) + 1 … WHERE node_path = …)`.
struct Interp {
    events: Vec<Event>,
    edges: BTreeSet<(usize, usize)>,
    counters: BTreeMap<String, u64>,
}

impl Interp {
    fn new() -> Self {
        Interp {
            events: Vec::new(),
            edges: BTreeSet::new(),
            counters: BTreeMap::new(),
        }
    }

    /// Emits a single marker event at `path`, assigning the next iteration
    /// number for that path (matching the live `MAX(iteration) + 1`).
    fn emit(&mut self, path: &str) -> Frag {
        let counter = self.counters.entry(path.to_string()).or_insert(0);
        *counter += 1;
        let iteration = *counter;
        let idx = self.events.len();
        self.events.push(Event {
            node_path: path.to_string(),
            iteration,
        });
        Frag {
            first: vec![idx],
            last: vec![idx],
        }
    }

    /// Records `a ≺ b`: every maximal event of `a` happens before every minimal
    /// event of `b`. Both fragments were emitted earlier than nothing they
    /// connect to, so each recorded edge points forward in `events`.
    fn order(&mut self, a: &Frag, b: &Frag) {
        for &u in &a.last {
            for &v in &b.first {
                self.edges.insert((u, v));
            }
        }
    }

    /// Sequential composition `a ; b`.
    fn seq_frag(&mut self, a: Frag, b: Frag) -> Frag {
        self.order(&a, &b);
        let first = if a.is_empty() {
            b.first.clone()
        } else {
            a.first
        };
        let last = if b.is_empty() { a.last } else { b.last };
        Frag { first, last }
    }

    /// Concurrent composition: the union frontier, with NO cross edges.
    fn par_frag(frags: Vec<Frag>) -> Frag {
        let mut first = Vec::new();
        let mut last = Vec::new();
        for f in frags {
            first.extend(f.first);
            last.extend(f.last);
        }
        Frag { first, last }
    }

    /// Recursively interprets `shape` at `path`. Mirrors `render::build`'s path
    /// scheme exactly so the produced events line up with `df_gen_trace` rows.
    /// `k` is the loop iteration count (the same `K` `render` uses).
    fn go(&mut self, shape: &Shape, path: &str, reachable: bool, k: u64) -> Frag {
        // An unreachable subtree never executes, so it contributes no event —
        // the live counterpart leaves its markers pending (expected count 0).
        if !reachable {
            return Frag::empty();
        }
        match shape {
            Shape::Marker => self.emit(path),

            Shape::Seq(a, b) => {
                let fa = self.go(a, &format!("{path}.0"), true, k);
                let fb = self.go(b, &format!("{path}.1"), true, k);
                self.seq_frag(fa, fb)
            }

            Shape::If {
                then_b,
                else_b,
                cond,
            } => {
                // The condition renders to a `$c$…$c$` predicate, not a marker,
                // so it emits no event; exactly one branch is reachable.
                let take_then = *cond == Cond::True;
                let ft = self.go(then_b, &format!("{path}.t"), take_then, k);
                let fe = self.go(else_b, &format!("{path}.e"), !take_then, k);
                if take_then {
                    ft
                } else {
                    fe
                }
            }

            Shape::Loop(body) => {
                // do-while: `K` iterations of `seq(body, counter)`, each
                // iteration fully preceding the next. The counter marker lives
                // at `{path}.c`; the body at `{path}.b`.
                let bpath = format!("{path}.b");
                let cpath = format!("{path}.c");
                let mut acc: Option<Frag> = None;
                for _ in 0..k {
                    let fb = self.go(body, &bpath, true, k);
                    let fc = self.emit(&cpath);
                    let iter_frag = self.seq_frag(fb, fc); // body ≺ counter
                    acc = Some(match acc {
                        None => iter_frag,
                        Some(prev) => self.seq_frag(prev, iter_frag), // iter i ≺ i+1
                    });
                }
                acc.unwrap_or_else(Frag::empty)
            }

            Shape::Join(a, b) => {
                let fa = self.go(a, &format!("{path}.0"), true, k);
                let fb = self.go(b, &format!("{path}.1"), true, k);
                Self::par_frag(vec![fa, fb]) // concurrent: no ordering between branches
            }

            Shape::Join3(a, b, c) => {
                let fa = self.go(a, &format!("{path}.0"), true, k);
                let fb = self.go(b, &format!("{path}.1"), true, k);
                let fc = self.go(c, &format!("{path}.2"), true, k);
                Self::par_frag(vec![fa, fb, fc])
            }

            Shape::Race(a, b) => {
                // The left branch wins deterministically; the right (loser) is
                // abandoned and emits nothing (rendered as reachable=false).
                let fw = self.go(a, &format!("{path}.w"), true, k);
                let _loser = self.go(b, &format!("{path}.l"), false, k);
                fw
            }

            Shape::LoopBreak { n } => {
                // The marker fires `n` times in sequence at `{path}.0`, then the
                // break condition trips. No separate counter marker.
                let mpath = format!("{path}.0");
                let mut acc: Option<Frag> = None;
                for _ in 0..*n {
                    let f = self.emit(&mpath);
                    acc = Some(match acc {
                        None => f,
                        Some(prev) => self.seq_frag(prev, f),
                    });
                }
                acc.unwrap_or_else(Frag::empty)
            }
        }
    }
}

/// Interprets `shape` with `k` loop iterations, returning the expected causal
/// trace as a [`Pomset`]. The root path is `"r"`, matching `render`.
pub(crate) fn interpret(shape: &Shape, k: u64) -> Pomset {
    let mut interp = Interp::new();
    interp.go(shape, "r", true, k);
    Pomset {
        events: interp.events,
        edges: interp.edges,
    }
}

/// The Phase 5 model-level DIFFERENTIAL: the interpreter's order-erased
/// projection must equal the renderer's independently-derived ground truth
/// (after dropping `render`'s unreachable 0-count entries — this interpreter
/// simply omits paths that never execute). Closed-form count arithmetic
/// (`render::build`) and step-by-step execution simulation (this interpreter)
/// are two independent implementations of the same semantics; their agreement
/// is the oracle.
pub(crate) fn counts_match_render(shape: &Shape, k: u64) -> bool {
    let pomset = interpret(shape, k);
    let rendered = render(shape, k, "diff");
    let expected: BTreeMap<String, u64> = rendered
        .expected
        .into_iter()
        .filter(|(_, count)| *count > 0)
        .collect();
    pomset.path_counts() == expected
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shape::{seed_shapes, shapes_up_to, Comb};

    const ALL_COMBS: [Comb; 6] = [
        Comb::Seq,
        Comb::If,
        Comb::Loop,
        Comb::Join,
        Comb::Join3,
        Comb::Race,
    ];

    fn ev(path: &str, iter: u64) -> Event {
        Event {
            node_path: path.to_string(),
            iteration: iter,
        }
    }

    fn marker() -> Shape {
        Shape::Marker
    }

    fn boxed(s: Shape) -> Box<Shape> {
        Box::new(s)
    }

    #[test]
    fn marker_emits_one_event_no_edges() {
        let p = interpret(&marker(), 2);
        assert_eq!(p.events, vec![ev("r", 1)]);
        assert!(p.edges.is_empty());
        assert!(p.ordered_pairs().is_empty());
    }

    #[test]
    fn seq_imposes_total_order() {
        // S(M, M): r.0 ≺ r.1
        let s = Shape::Seq(boxed(marker()), boxed(marker()));
        let p = interpret(&s, 2);
        assert_eq!(p.events, vec![ev("r.0", 1), ev("r.1", 1)]);
        assert_eq!(p.ordered_pairs(), vec![(ev("r.0", 1), ev("r.1", 1))]);
    }

    #[test]
    fn if_true_takes_then_only() {
        let s = Shape::If {
            then_b: boxed(marker()),
            else_b: boxed(marker()),
            cond: Cond::True,
        };
        let p = interpret(&s, 2);
        assert_eq!(p.events, vec![ev("r.t", 1)]);
    }

    #[test]
    fn if_false_takes_else_only() {
        let s = Shape::If {
            then_b: boxed(marker()),
            else_b: boxed(marker()),
            cond: Cond::False,
        };
        let p = interpret(&s, 2);
        assert_eq!(p.events, vec![ev("r.e", 1)]);
    }

    #[test]
    fn join_branches_are_concurrent() {
        // J(M, M): both run, NO ordering edge between them.
        let s = Shape::Join(boxed(marker()), boxed(marker()));
        let p = interpret(&s, 2);
        assert_eq!(
            p.path_counts(),
            BTreeMap::from([("r.0".into(), 1), ("r.1".into(), 1)])
        );
        assert!(p.edges.is_empty(), "join siblings must not be ordered");
        assert!(p.ordered_pairs().is_empty());
    }

    #[test]
    fn join3_branches_are_concurrent() {
        let s = Shape::Join3(boxed(marker()), boxed(marker()), boxed(marker()));
        let p = interpret(&s, 2);
        assert_eq!(
            p.path_counts(),
            BTreeMap::from([("r.0".into(), 1), ("r.1".into(), 1), ("r.2".into(), 1)])
        );
        assert!(p.edges.is_empty());
    }

    #[test]
    fn seq_after_join_orders_every_branch_before_tail() {
        // S(J(M, M), M): both join siblings ≺ the trailing marker, but NOT each
        // other. Exercises the union frontier.
        let s = Shape::Seq(
            boxed(Shape::Join(boxed(marker()), boxed(marker()))),
            boxed(marker()),
        );
        let p = interpret(&s, 2);
        // Events: r.0.0, r.0.1 (concurrent), then r.1.
        assert_eq!(p.events, vec![ev("r.0.0", 1), ev("r.0.1", 1), ev("r.1", 1)]);
        let pairs = p.ordered_pairs();
        assert!(pairs.contains(&(ev("r.0.0", 1), ev("r.1", 1))));
        assert!(pairs.contains(&(ev("r.0.1", 1), ev("r.1", 1))));
        // The two join siblings are NOT ordered relative to each other.
        assert!(!pairs.contains(&(ev("r.0.0", 1), ev("r.0.1", 1))));
        assert_eq!(pairs.len(), 2);
    }

    #[test]
    fn loop_sequences_iterations_and_counter() {
        // L(M) with K=3: body r.b and counter r.c each fire 3×, strictly
        // alternating b1, c1, b2, c2, b3, c3.
        let s = Shape::Loop(boxed(marker()));
        let p = interpret(&s, 3);
        assert_eq!(
            p.events,
            vec![
                ev("r.b", 1),
                ev("r.c", 1),
                ev("r.b", 2),
                ev("r.c", 2),
                ev("r.b", 3),
                ev("r.c", 3),
            ]
        );
        // body ≺ counter within an iteration; counter ≺ next body across.
        let pairs = p.ordered_pairs();
        assert!(pairs.contains(&(ev("r.b", 1), ev("r.c", 1))));
        assert!(pairs.contains(&(ev("r.c", 1), ev("r.b", 2))));
        assert!(pairs.contains(&(ev("r.b", 3), ev("r.c", 3))));
    }

    #[test]
    fn race_keeps_winner_drops_loser() {
        // R(M, M): only the winner at r.w runs; the loser r.l is abandoned.
        let s = Shape::Race(boxed(marker()), boxed(marker()));
        let p = interpret(&s, 2);
        assert_eq!(p.events, vec![ev("r.w", 1)]);
    }

    #[test]
    fn loop_break_fires_marker_n_times() {
        let s = Shape::LoopBreak { n: 3 };
        let p = interpret(&s, 2);
        assert_eq!(p.events, vec![ev("r.0", 1), ev("r.0", 2), ev("r.0", 3)]);
        // strictly sequential
        let pairs = p.ordered_pairs();
        assert!(pairs.contains(&(ev("r.0", 1), ev("r.0", 2))));
        assert!(pairs.contains(&(ev("r.0", 2), ev("r.0", 3))));
    }

    #[test]
    fn nested_loop_multiplies_body_count() {
        // L(L(M)) with K=2: inner body fires K×K = 4 times.
        let s = Shape::Loop(boxed(Shape::Loop(boxed(marker()))));
        let p = interpret(&s, 2);
        let counts = p.path_counts();
        assert_eq!(counts.get("r.b.b"), Some(&4)); // inner body 2×2
        assert_eq!(counts.get("r.b.c"), Some(&4)); // inner counter 2×2
        assert_eq!(counts.get("r.c"), Some(&2)); // outer counter 2
    }

    #[test]
    fn all_edges_point_forward() {
        // The recorded happens-before relation is acyclic by construction: every
        // edge connects an earlier-emitted event to a later one.
        for shape in shapes_up_to(&ALL_COMBS, 2) {
            let p = interpret(&shape, 3);
            for &(u, v) in &p.edges {
                assert!(u < v, "edge ({u},{v}) is not forward for {shape:?}");
            }
        }
    }

    #[test]
    fn iterations_are_dense_and_one_based_per_path() {
        // For every path, its iteration numbers are exactly 1..=count with no
        // gaps — matching the live MAX(iteration)+1 sequence.
        for shape in shapes_up_to(&ALL_COMBS, 2) {
            let p = interpret(&shape, 3);
            let mut seen: BTreeMap<String, Vec<u64>> = BTreeMap::new();
            for e in &p.events {
                seen.entry(e.node_path.clone())
                    .or_default()
                    .push(e.iteration);
            }
            for (path, iters) in seen {
                let want: Vec<u64> = (1..=iters.len() as u64).collect();
                assert_eq!(iters, want, "path {path} iterations not dense in {shape:?}");
            }
        }
    }

    #[test]
    fn differential_matches_render_over_full_depth2_matrix() {
        // The headline Phase 5 model-level oracle: the simulation interpreter and
        // the closed-form renderer agree on per-path counts for EVERY shape in the
        // depth-2 live matrix (plus the hand seeds), across several K values.
        let mut shapes = shapes_up_to(&ALL_COMBS, 2);
        shapes.extend(seed_shapes());
        for k in [1u64, 2, 3] {
            for shape in &shapes {
                assert!(
                    counts_match_render(shape, k),
                    "count differential failed at K={k} for {shape:?}:\n  interp={:?}\n  render={:?}",
                    interpret(shape, k).path_counts(),
                    render(shape, k, "diff").expected,
                );
            }
        }
    }
}
