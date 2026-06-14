// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Phase 3 (#232) — randomized property testing with shrinking.
//!
//! This module defines a recursive `proptest::Strategy<Meta>` that generates
//! random labeled-leaf DSL trees with weighted depth and combinator-frequency
//! knobs, then asserts a battery of semantic and structural properties over
//! thousands of those trees per run. `Meta` is the std-only stand-in for the
//! issue's `FunctionGraph`; the real `FunctionGraph` is a pgrx/duroxide type
//! that does not exist in this dependency-free crate, so the model is the
//! faithful analogue (see `meta.rs`).
//!
//! ## Why model-level, not live PG
//!
//! proptest's defining feature is **shrinking**: when a property fails, it
//! automatically reduces the random input to a minimal counterexample. Shrinking
//! requires the property to execute **in-process** so proptest can drive the
//! reduction loop. A property that booted a live PostgreSQL instance per case
//! could not shrink (and could not run in this std-only crate, which has no
//! pgrx). So Phase 3 points proptest where it is strongest — the deterministic
//! reference interpreter (`meta::eval`/`observable`) and the renderer
//! (`meta::render_prog`), both pure and in-process.
//!
//! This is a deliberate, scoped choice, not a gap:
//!   * Exhaustive depth-2 **live** oracle coverage already exists (Phases 2+4).
//!   * The issue frames Phase 3's value-add as *shrinking* + unbounded random
//!     coverage, which is realized fully at the model level.
//!   * The properties harden the **same** `eval` that Phase 4's live tests use as
//!     ground truth, so model-level hardening strengthens the live suite too.
//!
//! ## Persistent failure corpus
//!
//! proptest persists any discovered counterexample to
//! `generator/proptest-regressions/prop.txt` and replays it on every subsequent
//! run. That file IS the issue's "failure corpus checked into the repo"; commit
//! it whenever it appears (it is LF-normalized via `.gitattributes`).
//!
//! ## Reproducible vs. exploratory runs
//!
//! The committed config fixes `cases = 256`. proptest's native `PROPTEST_CASES`
//! environment variable overrides that, so the CI gate runs the fixed count
//! (deterministic, fast, replays the committed corpus) while the nightly job sets
//! a larger `PROPTEST_CASES` for a fresh-seed exploratory sweep.

use crate::meta::{observable, render_prog, Meta};
use crate::refinterp::{counts_match_render, interpret};
use crate::render::render;
use crate::shape::{Cond, Shape};
use proptest::prelude::*;
use std::collections::{BTreeMap, BTreeSet};

// ---------------------------------------------------------------------------
// Tree constructors (terser than spelling out Box::new at every call site).
// ---------------------------------------------------------------------------

fn seq(a: Meta, b: Meta) -> Meta {
    Meta::Seq(Box::new(a), Box::new(b))
}

fn join(a: Meta, b: Meta) -> Meta {
    Meta::Join(Box::new(a), Box::new(b))
}

fn cond(taken: bool) -> Cond {
    if taken {
        Cond::True
    } else {
        Cond::False
    }
}

// ---------------------------------------------------------------------------
// The recursive strategy: random `Meta` trees.
// ---------------------------------------------------------------------------

/// Random leaf label drawn from a small, readable alphabet. Keeping the alphabet
/// small means leaves frequently collide, exercising the multiset-summing paths
/// of the interpreter, and keeps shrunk counterexamples tidy.
fn arb_label() -> impl Strategy<Value = String> {
    prop_oneof![Just("a"), Just("b"), Just("c"), Just("d"), Just("e"),].prop_map(String::from)
}

/// Picks an anchor leaf for a generated loop that is GUARANTEED to execute (it is
/// a key of the body's observable, i.e. it survives any untaken `if`/`race`
/// branch). The rendered do-while/break predicate counts that leaf's trace rows,
/// so anchoring on an executing leaf keeps the loop terminating were it ever run
/// live. `observable` is always non-empty for our grammar (every subtree has at
/// least one executing leaf), so the fallback is purely defensive.
fn first_executing_label(body: &Meta) -> String {
    observable(body)
        .into_keys()
        .next()
        .unwrap_or_else(|| "a".to_string())
}

/// A recursive strategy producing random `Meta` trees.
///
/// `prop_recursive` bounds the shape: at most depth 4, ~48 total nodes, with ~3
/// children per recursive level. The `prop_oneof!` weights are the
/// combinator-frequency knobs the issue calls for — `seq` is the most common
/// glue, loops the rarest (they multiply work). Loop iteration counts are bounded
/// to `1..=4` so observable counts never approach `u64` overflow even under
/// nested loops.
fn arb_meta() -> impl Strategy<Value = Meta> {
    let leaf = arb_label().prop_map(Meta::Leaf);
    leaf.prop_recursive(4, 48, 3, |inner| {
        prop_oneof![
            3 => (inner.clone(), inner.clone()).prop_map(|(a, b)| seq(a, b)),
            2 => (inner.clone(), inner.clone()).prop_map(|(a, b)| join(a, b)),
            2 => (any::<bool>(), inner.clone(), inner.clone())
                .prop_map(|(c, t, e)| Meta::If(cond(c), Box::new(t), Box::new(e))),
            1 => inner.clone().prop_map(|w| Meta::Race(Box::new(w))),
            1 => (inner.clone(), 1u64..=4).prop_map(|(b, k)| {
                let anchor = first_executing_label(&b);
                Meta::DoWhile { body: Box::new(b), anchor, k }
            }),
            1 => (inner, 1u64..=4).prop_map(|(b, n)| {
                let anchor = first_executing_label(&b);
                Meta::LoopBreak { body: Box::new(b), anchor, n }
            }),
        ]
    })
}

// ---------------------------------------------------------------------------
// Independent oracles (deliberately NOT shared with meta.rs).
// ---------------------------------------------------------------------------

/// An INDEPENDENT re-implementation of the observable semantics, written in a
/// deliberately different style from `meta::eval`: a functional fold that returns
/// a fresh map and multiplies explicitly, versus `eval`'s in-place accumulator
/// threading a `mult` argument. A transcription bug in one is therefore unlikely
/// to be mirrored in the other, making `observable == ref_observable` a genuine
/// differential check across the whole random-tree space — and a foothold for the
/// Phase 5 differential-testing work.
fn ref_observable(p: &Meta) -> BTreeMap<String, u64> {
    fn merge(mut a: BTreeMap<String, u64>, b: BTreeMap<String, u64>) -> BTreeMap<String, u64> {
        for (k, v) in b {
            *a.entry(k).or_insert(0) += v;
        }
        a
    }
    fn scale(m: BTreeMap<String, u64>, by: u64) -> BTreeMap<String, u64> {
        m.into_iter().map(|(k, v)| (k, v * by)).collect()
    }
    match p {
        Meta::Leaf(l) => {
            let mut m = BTreeMap::new();
            m.insert(l.clone(), 1);
            m
        }
        Meta::Seq(a, b) | Meta::Join(a, b) => merge(ref_observable(a), ref_observable(b)),
        Meta::If(Cond::True, t, _) => ref_observable(t),
        Meta::If(Cond::False, _, e) => ref_observable(e),
        Meta::Race(w) => ref_observable(w),
        Meta::DoWhile { body, k, .. } => scale(ref_observable(body), *k),
        Meta::LoopBreak { body, n, .. } => scale(ref_observable(body), *n),
    }
}

fn total(m: &BTreeMap<String, u64>) -> u64 {
    m.values().sum()
}

/// All labels syntactically present in the tree, including those in untaken `if`
/// branches and abandoned `race` losers — because the renderer emits a marker
/// node for every leaf regardless of reachability (the DSL graph still contains
/// it). So every label here must appear in the rendered SQL.
fn labels_of(p: &Meta, out: &mut BTreeSet<String>) {
    match p {
        Meta::Leaf(l) => {
            out.insert(l.clone());
        }
        Meta::Seq(a, b) | Meta::Join(a, b) => {
            labels_of(a, out);
            labels_of(b, out);
        }
        Meta::If(_, t, e) => {
            labels_of(t, out);
            labels_of(e, out);
        }
        Meta::Race(w) => labels_of(w, out),
        Meta::DoWhile { body, .. } | Meta::LoopBreak { body, .. } => labels_of(body, out),
    }
}

#[derive(Default)]
struct NodeCounts {
    race: usize,
    dowhile: usize,
    loop_break: usize,
}

/// Counts the combinator nodes whose rendering is structurally checkable: each
/// `Race` emits exactly one `df.race(`/`df.sleep(` pair; each loop emits one
/// `df.loop(`; each `LoopBreak` additionally emits one `df.break()`.
fn node_counts(p: &Meta) -> NodeCounts {
    fn go(p: &Meta, c: &mut NodeCounts) {
        match p {
            Meta::Leaf(_) => {}
            Meta::Seq(a, b) | Meta::Join(a, b) => {
                go(a, c);
                go(b, c);
            }
            Meta::If(_, t, e) => {
                go(t, c);
                go(e, c);
            }
            Meta::Race(w) => {
                c.race += 1;
                go(w, c);
            }
            Meta::DoWhile { body, .. } => {
                c.dowhile += 1;
                go(body, c);
            }
            Meta::LoopBreak { body, .. } => {
                c.loop_break += 1;
                go(body, c);
            }
        }
    }
    let mut c = NodeCounts::default();
    go(p, &mut c);
    c
}

/// Independent structural paren-balance checker (intentionally not the meta.rs
/// test helper of the same name): strips the renderer's two dollar-quoted span
/// kinds (`$mk$` marker SQL and `$c$` condition SQL) so the parens embedded in
/// that SQL don't confuse the balance of the DSL combinator parens, then verifies
/// the remaining parens nest cleanly. Having a second, independent implementation
/// guards against a bug in the shared helper masking a real render defect.
fn parens_balanced(dsl: &str) -> bool {
    fn strip(mut s: String, tag: &str) -> String {
        while let Some(start) = s.find(tag) {
            match s[start + tag.len()..].find(tag) {
                Some(rel) => {
                    let end = start + tag.len() + rel + tag.len();
                    s.replace_range(start..end, "");
                }
                None => break,
            }
        }
        s
    }
    let stripped = strip(strip(dsl.to_string(), "$mk$"), "$c$");
    let mut depth: i32 = 0;
    for ch in stripped.chars() {
        match ch {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
}

// ---------------------------------------------------------------------------
// Phase 5 (#232): random `Shape` trees, for differential + causal-order checks
// against the reference interpreter. `Shape` is the node-path-tagged model the
// live `df_gen_trace` records, so these properties harden the SAME ground truth
// the live Phase 2 matrix asserts.
// ---------------------------------------------------------------------------

/// A recursive strategy producing random `Shape` trees. Mirrors `arb_meta`'s
/// shape budget (depth 4, ~48 nodes, ~3 children) and combinator weighting. A
/// single loop iteration count `K` is applied uniformly at interpret/render
/// time (see the properties below), bounded small so nested loops never approach
/// `u64` overflow.
fn arb_shape() -> impl Strategy<Value = Shape> {
    let leaf = prop_oneof![
        3 => Just(Shape::Marker),
        1 => (1u32..=4).prop_map(|n| Shape::LoopBreak { n }),
    ];
    leaf.prop_recursive(4, 48, 3, |inner| {
        prop_oneof![
            3 => (inner.clone(), inner.clone())
                .prop_map(|(a, b)| Shape::Seq(Box::new(a), Box::new(b))),
            2 => (any::<bool>(), inner.clone(), inner.clone()).prop_map(|(c, t, e)| Shape::If {
                then_b: Box::new(t),
                else_b: Box::new(e),
                cond: cond(c),
            }),
            1 => inner.clone().prop_map(|b| Shape::Loop(Box::new(b))),
            2 => (inner.clone(), inner.clone())
                .prop_map(|(a, b)| Shape::Join(Box::new(a), Box::new(b))),
            1 => (inner.clone(), inner.clone(), inner.clone())
                .prop_map(|(a, b, c)| Shape::Join3(Box::new(a), Box::new(b), Box::new(c))),
            1 => (inner.clone(), inner)
                .prop_map(|(a, b)| Shape::Race(Box::new(a), Box::new(b))),
        ]
    })
}

// ---------------------------------------------------------------------------
// Properties.
// ---------------------------------------------------------------------------

proptest! {
    // Fixed default for reproducible CI runs; proptest's native PROPTEST_CASES
    // env var overrides this (the nightly exploration job sets it higher).
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// The interpreter is a pure function: same tree, same observable.
    #[test]
    fn eval_is_deterministic(p in arb_meta()) {
        prop_assert_eq!(observable(&p), observable(&p));
    }

    /// DIFFERENTIAL: `meta::eval` agrees with an independently-written reference
    /// interpreter on every random tree. Breaks the circularity in which the
    /// metamorphic registry trusts `eval` to compute its own ground truth.
    #[test]
    fn eval_matches_independent_reference(p in arb_meta()) {
        prop_assert_eq!(observable(&p), ref_observable(&p));
    }

    /// `seq` is associative under the observable (the issue's seq-assoc relation,
    /// generalized from the single hand-picked case to arbitrary subtrees).
    #[test]
    fn seq_is_associative(a in arb_meta(), b in arb_meta(), c in arb_meta()) {
        let left = seq(a.clone(), seq(b.clone(), c.clone()));
        let right = seq(seq(a, b), c);
        prop_assert_eq!(observable(&left), observable(&right));
    }

    /// `join` is commutative under the observable (join-comm, generalized).
    #[test]
    fn join_is_commutative(a in arb_meta(), b in arb_meta()) {
        prop_assert_eq!(observable(&join(a.clone(), b.clone())), observable(&join(b, a)));
    }

    /// `join` is associative under the observable.
    #[test]
    fn join_is_associative(a in arb_meta(), b in arb_meta(), c in arb_meta()) {
        let left = join(a.clone(), join(b.clone(), c.clone()));
        let right = join(join(a, b), c);
        prop_assert_eq!(observable(&left), observable(&right));
    }

    /// `seq(a, b)` and `join(a, b)` yield the SAME observable: the multiset of
    /// completion counts is order-free, so sequential vs. concurrent execution of
    /// the same two children is observably indistinguishable.
    #[test]
    fn seq_and_join_have_same_observable(a in arb_meta(), b in arb_meta()) {
        prop_assert_eq!(observable(&seq(a.clone(), b.clone())), observable(&join(a, b)));
    }

    /// `if` reduces to exactly the taken branch (if-true / if-false, generalized).
    #[test]
    fn if_selects_the_taken_branch(a in arb_meta(), b in arb_meta()) {
        let taken = Meta::If(Cond::True, Box::new(a.clone()), Box::new(b.clone()));
        let untaken = Meta::If(Cond::False, Box::new(a.clone()), Box::new(b.clone()));
        prop_assert_eq!(observable(&taken), observable(&a));
        prop_assert_eq!(observable(&untaken), observable(&b));
    }

    /// `race(winner, loser)` reduces to the winner (race-winner, generalized): the
    /// abandoned loser contributes nothing to the observable.
    #[test]
    fn race_reduces_to_winner(a in arb_meta()) {
        prop_assert_eq!(observable(&Meta::Race(Box::new(a.clone()))), observable(&a));
    }

    /// A loop scales every body count by its iteration factor (do-while `k` /
    /// break-after `n`), generalizing meta.rs's fixed `loop_multiplier_scales_body`
    /// to arbitrary bodies and factors.
    #[test]
    fn loop_scales_body_counts(b in arb_meta(), k in 1u64..=4) {
        let base = observable(&b);
        let anchor = first_executing_label(&b);
        let dw = Meta::DoWhile { body: Box::new(b.clone()), anchor: anchor.clone(), k };
        let lb = Meta::LoopBreak { body: Box::new(b), anchor, n: k };
        let want: BTreeMap<String, u64> =
            base.iter().map(|(l, c)| (l.clone(), *c * k)).collect();
        prop_assert_eq!(observable(&dw), want.clone());
        prop_assert_eq!(observable(&lb), want);
    }

    /// Combinators that run all their children conserve the total completion
    /// count; `race` conserves only the winner's.
    #[test]
    fn structural_combinators_conserve_total(a in arb_meta(), b in arb_meta()) {
        let ta = total(&observable(&a));
        let tb = total(&observable(&b));
        prop_assert_eq!(total(&observable(&seq(a.clone(), b.clone()))), ta + tb);
        prop_assert_eq!(total(&observable(&join(a.clone(), b.clone()))), ta + tb);
        prop_assert_eq!(total(&observable(&Meta::Race(Box::new(a)))), ta);
    }

    /// Rendering is a pure function: same tree, byte-identical SQL.
    #[test]
    fn render_is_deterministic(p in arb_meta()) {
        prop_assert_eq!(render_prog(&p, "prop"), render_prog(&p, "prop"));
    }

    /// Every random tree renders to structurally well-formed DSL: balanced
    /// combinator parens, balanced dollar-quotes, no leaked `df.start`, one
    /// `df.race(`+`df.sleep(` per race, one `df.loop(` per loop, one `df.break()`
    /// per break-loop, and every label present. Generalizes meta.rs's fixed
    /// `renders_have_balanced_parens_and_dollar_quotes` to thousands of trees.
    #[test]
    fn render_is_structurally_wellformed(p in arb_meta()) {
        let dsl = render_prog(&p, "prop");

        prop_assert!(parens_balanced(&dsl), "unbalanced parens: {}", dsl);
        prop_assert_eq!(dsl.matches("$mk$").count() % 2, 0, "unbalanced $mk$: {}", dsl);
        prop_assert_eq!(dsl.matches("$c$").count() % 2, 0, "unbalanced $c$: {}", dsl);
        prop_assert!(!dsl.contains("df.start"), "render leaked df.start: {}", dsl);

        let counts = node_counts(&p);
        prop_assert_eq!(dsl.matches("df.race(").count(), counts.race);
        prop_assert_eq!(dsl.matches("df.sleep(").count(), counts.race);
        prop_assert_eq!(dsl.matches("df.loop(").count(), counts.dowhile + counts.loop_break);
        prop_assert_eq!(dsl.matches("df.break()").count(), counts.loop_break);

        let mut labels = BTreeSet::new();
        labels_of(&p, &mut labels);
        for l in labels {
            prop_assert!(dsl.contains(&format!("'{}'", l)), "label {} missing: {}", l, dsl);
        }
    }

    // -----------------------------------------------------------------------
    // Phase 5: reference-interpreter differential + causal-order laws over
    // random `Shape` trees. The interpreter (`refinterp`) is a THIRD,
    // independently-written semantics; these properties cross-check it against
    // the renderer's closed-form counts and assert the happens-before structure
    // the live wall-clock trace must obey.
    // -----------------------------------------------------------------------

    /// DIFFERENTIAL: the interpreter's per-path completion counts equal the
    /// renderer's closed-form `expected` map on every random tree and every
    /// `k`. Two independent implementations (step-by-step simulation vs.
    /// arithmetic `mult`) — agreement is strong evidence both are correct.
    #[test]
    fn interp_counts_match_render(shape in arb_shape(), k in 1u64..=3) {
        prop_assert!(
            counts_match_render(&shape, k),
            "count mismatch k={}: interp={:?} render={:?}",
            k,
            interpret(&shape, k).path_counts(),
            render(&shape, k, "prop").expected,
        );
    }

    /// The interpreter is a pure function: same tree + same `k`, identical
    /// pomset (events AND happens-before edges).
    #[test]
    fn interp_is_deterministic(shape in arb_shape(), k in 1u64..=3) {
        prop_assert_eq!(interpret(&shape, k), interpret(&shape, k));
    }

    /// Acyclicity, structurally: every happens-before edge points strictly
    /// forward in the linearization (`u < v`), so the relation is a DAG and
    /// the live wall-clock assertions can never be self-contradictory.
    #[test]
    fn interp_edges_point_forward(shape in arb_shape(), k in 1u64..=3) {
        let pom = interpret(&shape, k);
        for &(u, v) in &pom.edges {
            prop_assert!(u < v, "non-forward edge ({}, {}) in {:?}", u, v, shape);
        }
    }

    /// Per node_path, the recorded `iteration` values are exactly the dense
    /// range `1..=count` — no gaps, no duplicates — mirroring the live
    /// `MAX(iteration) == count` contract the loop oracle relies on.
    #[test]
    fn interp_iterations_are_dense(shape in arb_shape(), k in 1u64..=3) {
        let pom = interpret(&shape, k);
        let mut per_path: BTreeMap<String, Vec<u64>> = BTreeMap::new();
        for ev in &pom.events {
            per_path.entry(ev.node_path.clone()).or_default().push(ev.iteration);
        }
        for (path, mut iters) in per_path {
            iters.sort_unstable();
            let expected: Vec<u64> = (1..=iters.len() as u64).collect();
            prop_assert_eq!(&iters, &expected, "iterations for {} not dense: {:?}", path, iters);
        }
    }

    /// CAUSAL-ORDER LAW (Seq), structurally: `Seq(a, b)` linearizes all of `a`
    /// (event indices `0..na`) strictly before all of `b` (`na..`), PRESERVES
    /// each child's happens-before relation untouched, and adds only forward
    /// `a ≺ b` cross edges — at least one iff both sides execute. Asserting the
    /// edge *partition* (not just its size) is the order-level analogue of
    /// Phase 4's count laws and Phase 5's unique value-add: a size-only check
    /// could pass while a dropped child edge masks a spurious cross edge.
    #[test]
    fn interp_seq_introduces_order(a in arb_shape(), b in arb_shape(), k in 1u64..=3) {
        let pa = interpret(&a, k);
        let pb = interpret(&b, k);
        let na = pa.events.len();
        let seq = Shape::Seq(Box::new(a.clone()), Box::new(b.clone()));
        let ps = interpret(&seq, k);

        // Seq concatenates a's events then b's, so the index space partitions at
        // `na`. Split seq's edges into within-a, within-b (shifted back), and the
        // cross edges, asserting every cross edge runs strictly a → b.
        prop_assert_eq!(ps.events.len(), na + pb.events.len());
        let mut within_a: BTreeSet<(usize, usize)> = BTreeSet::new();
        let mut within_b: BTreeSet<(usize, usize)> = BTreeSet::new();
        let mut cross = 0usize;
        for &(u, v) in &ps.edges {
            if v < na {
                within_a.insert((u, v));
            } else if u >= na {
                within_b.insert((u - na, v - na));
            } else {
                prop_assert!(u < na && v >= na, "stray seq edge ({}, {})", u, v);
                cross += 1;
            }
        }
        // Both child relations survive composition byte-for-byte.
        prop_assert_eq!(&within_a, &pa.edges, "seq altered a's happens-before");
        prop_assert_eq!(&within_b, &pb.edges, "seq altered b's happens-before");
        // Sequencing introduces happens-before iff both sides actually execute.
        if na == 0 || pb.events.is_empty() {
            prop_assert_eq!(cross, 0, "empty side must add no cross edge");
        } else {
            prop_assert!(cross > 0, "seq added no happens-before edge");
        }
    }

    /// CAUSAL-ORDER LAW (Join), structurally: parallel branches are CONCURRENT.
    /// `Join(a, b)`'s happens-before relation is EXACTLY a's edges unioned with
    /// b's edges (shifted into the second index block) — no cross edge in either
    /// direction. Asserting the edge *set* (not just its size) proves the
    /// harness imposes no wall-clock ordering between branches and so stays
    /// flake-free regardless of interleaving.
    #[test]
    fn interp_join_adds_no_order(a in arb_shape(), b in arb_shape(), k in 1u64..=3) {
        let pa = interpret(&a, k);
        let pb = interpret(&b, k);
        let na = pa.events.len();
        let join = Shape::Join(Box::new(a), Box::new(b));
        let pj = interpret(&join, k);

        prop_assert_eq!(pj.events.len(), na + pb.events.len());
        let mut expected: BTreeSet<(usize, usize)> = pa.edges.clone();
        for &(u, v) in &pb.edges {
            expected.insert((u + na, v + na));
        }
        prop_assert_eq!(pj.edges, expected);
    }
}

// ---------------------------------------------------------------------------
// Unit tests for the strategy's own helpers (deterministic, no proptest needed).
// ---------------------------------------------------------------------------

#[cfg(test)]
mod helper_tests {
    use super::*;

    #[test]
    fn ref_observable_matches_eval_on_hand_cases() {
        // seq(a, loop(b x3)) -> {a:1, b:3}; race(a) abandons nothing extra.
        let p = seq(
            Meta::Leaf("a".into()),
            Meta::DoWhile {
                body: Box::new(Meta::Leaf("b".into())),
                anchor: "b".into(),
                k: 3,
            },
        );
        assert_eq!(observable(&p), ref_observable(&p));
        assert_eq!(
            ref_observable(&p),
            BTreeMap::from([("a".into(), 1), ("b".into(), 3)])
        );
    }

    #[test]
    fn first_executing_label_skips_untaken_branch() {
        // if(false, a, b) executes only b, so the anchor must be b, never a.
        let body = Meta::If(
            Cond::False,
            Box::new(Meta::Leaf("a".into())),
            Box::new(Meta::Leaf("b".into())),
        );
        assert_eq!(first_executing_label(&body), "b");
    }

    #[test]
    fn node_counts_and_labels_are_accurate() {
        // race(loop_break(seq(a, b) x2)) over a join with c.
        let p = join(
            Meta::Race(Box::new(Meta::LoopBreak {
                body: Box::new(seq(Meta::Leaf("a".into()), Meta::Leaf("b".into()))),
                anchor: "a".into(),
                n: 2,
            })),
            Meta::Leaf("c".into()),
        );
        let c = node_counts(&p);
        assert_eq!((c.race, c.dowhile, c.loop_break), (1, 0, 1));

        let mut labels = BTreeSet::new();
        labels_of(&p, &mut labels);
        assert_eq!(
            labels,
            BTreeSet::from(["a".to_string(), "b".to_string(), "c".to_string()])
        );
    }

    #[test]
    fn parens_balanced_ignores_sql_inside_dollar_quotes() {
        // A marker's embedded SQL has unbalanced-looking parens, but they live
        // inside $mk$…$mk$, so the DSL itself is balanced.
        let dsl = render_prog(&Meta::Leaf("a".into()), "prop");
        assert!(parens_balanced(&dsl));
        // A genuinely unbalanced DSL is rejected.
        assert!(!parens_balanced("df.seq((a)"));
    }
}
