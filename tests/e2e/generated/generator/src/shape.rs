// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Shape model and deterministic enumeration of combinator-nesting trees.
//!
//! A [`Shape`] is an abstract nesting tree over the pg_durable DSL combinators.
//! Leaves are markers (rendered as `df.sql` INSERTs into a shared trace table);
//! internal nodes are combinators (`seq`, `if`, `loop`, `join`, `join3`, `race`).
//!
//! Nesting depth is defined structurally: a marker has depth 0, and a combinator
//! has depth `1 + max(child depth)`. This matches the "combinator-nesting depth"
//! notion in issue #232 (e.g. `loop(marker)` is depth 1, `loop(join(m, m))` is
//! depth 2).

use std::collections::BTreeMap;

/// The branch a generated `df.if` deterministically takes.
///
/// The canonical exhaustive enumeration always renders `Cond::True` (then-branch
/// taken, else-branch left pending). `Cond::False` is reserved for hand-written
/// seeds that exercise the else-taken path.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Cond {
    True,
    False,
}

impl Cond {
    /// The SQL predicate this condition renders to.
    pub fn sql(self) -> &'static str {
        match self {
            Cond::True => "SELECT true",
            Cond::False => "SELECT false",
        }
    }
}

/// An abstract combinator-nesting tree.
#[derive(Clone, Debug)]
pub enum Shape {
    /// A leaf marker — records one execution of its node path.
    Marker,
    /// `df.seq(a, b)` — runs `a` then `b`.
    Seq(Box<Shape>, Box<Shape>),
    /// `df.if(cond, then, else)` — takes exactly one branch.
    If {
        then_b: Box<Shape>,
        else_b: Box<Shape>,
        cond: Cond,
    },
    /// `df.loop(body, cond)` — runs `body` a fixed number of iterations.
    Loop(Box<Shape>),
    /// `df.join(a, b)` — runs both branches; completes when both finish.
    Join(Box<Shape>, Box<Shape>),
    /// `df.join3(a, b, c)` — runs all three branches.
    Join3(Box<Shape>, Box<Shape>, Box<Shape>),
    /// `df.race(a, b)` — `a` deterministically wins; `b` is abandoned.
    Race(Box<Shape>, Box<Shape>),
    /// Seed-only: a loop whose body breaks after `n` marker executions.
    LoopBreak { n: u32 },
}

/// The combinators that may appear in the exhaustive enumeration.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Comb {
    Seq,
    If,
    Loop,
    Join,
    Join3,
    Race,
}

impl Comb {
    /// Parses a comma-list token (e.g. `"seq"`) into a combinator.
    pub fn parse(token: &str) -> Result<Comb, String> {
        match token.trim().to_ascii_lowercase().as_str() {
            "seq" => Ok(Comb::Seq),
            "if" => Ok(Comb::If),
            "loop" => Ok(Comb::Loop),
            "join" => Ok(Comb::Join),
            "join3" => Ok(Comb::Join3),
            "race" => Ok(Comb::Race),
            other => Err(format!("unknown combinator '{other}'")),
        }
    }

    /// Stable lowercase name used in the manifest header.
    pub fn name(self) -> &'static str {
        match self {
            Comb::Seq => "seq",
            Comb::If => "if",
            Comb::Loop => "loop",
            Comb::Join => "join",
            Comb::Join3 => "join3",
            Comb::Race => "race",
        }
    }
}

impl Shape {
    /// Structural nesting depth (marker = 0, combinator = 1 + max child depth).
    pub fn depth(&self) -> u32 {
        match self {
            Shape::Marker => 0,
            Shape::Loop(a) => 1 + a.depth(),
            Shape::Seq(a, b) | Shape::Join(a, b) | Shape::Race(a, b) => {
                1 + a.depth().max(b.depth())
            }
            Shape::If { then_b, else_b, .. } => 1 + then_b.depth().max(else_b.depth()),
            Shape::Join3(a, b, c) => 1 + a.depth().max(b.depth()).max(c.depth()),
            // A break-loop is structurally a single loop over fixed leaves.
            Shape::LoopBreak { .. } => 1,
        }
    }

    /// A compact, canonical, human-readable signature.
    ///
    /// Structurally distinct trees produce distinct signatures, so the signature
    /// doubles as a dedup/sort key and as the stable identity in the manifest.
    pub fn signature(&self) -> String {
        match self {
            Shape::Marker => "M".to_string(),
            Shape::Seq(a, b) => format!("S({},{})", a.signature(), b.signature()),
            Shape::If {
                then_b,
                else_b,
                cond,
            } => {
                let tag = match cond {
                    Cond::True => "I",
                    Cond::False => "Ielse",
                };
                format!("{tag}({},{})", then_b.signature(), else_b.signature())
            }
            Shape::Loop(a) => format!("L({})", a.signature()),
            Shape::Join(a, b) => format!("J({},{})", a.signature(), b.signature()),
            Shape::Join3(a, b, c) => {
                format!("J3({},{},{})", a.signature(), b.signature(), c.signature())
            }
            Shape::Race(a, b) => format!("R({},{})", a.signature(), b.signature()),
            Shape::LoopBreak { n } => format!("LB{n}"),
        }
    }

    /// Classifies whether this shape is expected to fail live execution because
    /// it nests a `df.loop` in a host context the product's loop implementation
    /// mishandles. Returns `Some(reason)` for shapes that must be **quarantined**
    /// (run non-blocking / xfail) and `None` for shapes expected to pass.
    ///
    /// # Why this exists
    ///
    /// `execute_loop_node` ends each continuing iteration with `continue_as_new`,
    /// which restarts the *currently executing* orchestration from its root:
    ///
    /// * Inside a `join`/`race`/`join3` branch the running orchestration is
    ///   `ExecuteSubtree`, whose input parser then receives a `FunctionInput`
    ///   instead of the `{graph, node_id, results}` it expects → the sub-orch
    ///   fails with "Missing graph in ExecuteSubtree input", so the parent
    ///   combinator never completes and the instance hangs (bug class #230).
    /// * At top level it restarts `ExecuteFunctionGraph`, re-running the loop's
    ///   *preceding* siblings and inflating their marker counts (bug class #227).
    ///
    /// The predicate below is a purely structural model of those two failure
    /// modes. It is validated to reproduce the live depth-2 failure set exactly
    /// (see `is_problematic_matches_empirical_depth2_failset`).
    pub fn is_problematic(&self) -> Option<&'static str> {
        self.classify_for_quarantine(None)
    }

    /// Recursive classifier. `inherited_host_danger` carries a non-`None` reason
    /// when this subtree executes inside a host context where a `df.loop`'s
    /// `continue_as_new` is mishandled (a join/race-winner branch, or a
    /// non-leading sequence position). A `df.loop` reached with
    /// `inherited_host_danger = Some(..)` is quarantined with that reason.
    fn classify_for_quarantine(
        &self,
        inherited_host_danger: Option<&'static str>,
    ) -> Option<&'static str> {
        match self {
            // Leaves never fail on their own.
            Shape::Marker => None,
            // `if` is transparent: it propagates the inherited context but never
            // introduces one. A loop in an `if` branch at top level is safe.
            Shape::If { then_b, else_b, .. } => then_b
                .classify_for_quarantine(inherited_host_danger)
                .or_else(|| else_b.classify_for_quarantine(inherited_host_danger)),
            // In a sequence the leading element executes first and is re-entered
            // harmlessly by a root restart, so it only inherits the ambient
            // context. Every later element runs *after* its predecessors, so a
            // loop there re-runs them on `continue_as_new` → over-count. The tail
            // keeps any stricter inherited reason rather than masking a host
            // join/race danger with the weaker seq-tail reason.
            Shape::Seq(a, b) => a
                .classify_for_quarantine(inherited_host_danger)
                .or_else(|| {
                    b.classify_for_quarantine(inherited_host_danger.or(Some("loop-in-seq-tail")))
                }),
            // Every join branch runs as an `ExecuteSubtree`, so any loop inside
            // either branch is mishandled.
            Shape::Join(a, b) => a
                .classify_for_quarantine(Some("loop-in-join"))
                .or_else(|| b.classify_for_quarantine(Some("loop-in-join"))),
            Shape::Join3(a, b, c) => a
                .classify_for_quarantine(Some("loop-in-join"))
                .or_else(|| b.classify_for_quarantine(Some("loop-in-join")))
                .or_else(|| c.classify_for_quarantine(Some("loop-in-join"))),
            // The race *winner* runs as an `ExecuteSubtree` and must complete, so
            // a loop there hangs. The loser is abandoned, so a loop confined to
            // it only inherits the ambient context (safe at top level).
            Shape::Race(w, l) => w
                .classify_for_quarantine(Some("loop-in-race-winner"))
                .or_else(|| l.classify_for_quarantine(inherited_host_danger)),
            // A loop reached inside a bad host context is quarantined. Otherwise
            // a loop whose body itself contains a combinator (join/race/loop)
            // re-enters that combinator's sub-orchestration on every iteration
            // and is mishandled the same way.
            Shape::Loop(body) => {
                if let Some(reason) = inherited_host_danger {
                    Some(reason)
                } else if body.contains_combinator() {
                    Some("loop-body-combinator")
                } else {
                    // The body is a pure tree of `Marker`/`Seq`/`If` with no
                    // nested combinator, so it can never itself yield a reason; a
                    // plain loop over markers at the root is safe.
                    None
                }
            }
            // A break-loop is a fixed-iteration loop over markers; same rules.
            Shape::LoopBreak { .. } => inherited_host_danger,
        }
    }

    /// True when this subtree contains a combinator whose execution spawns a
    /// sub-orchestration that a surrounding `df.loop` body would re-enter on
    /// every iteration: `join`, `join3`, `race`, or a nested `loop`. `seq` and
    /// `if` are transparent control flow and do not count on their own.
    fn contains_combinator(&self) -> bool {
        match self {
            Shape::Marker => false,
            Shape::Seq(a, b) => a.contains_combinator() || b.contains_combinator(),
            Shape::If { then_b, else_b, .. } => {
                then_b.contains_combinator() || else_b.contains_combinator()
            }
            Shape::Loop(_)
            | Shape::LoopBreak { .. }
            | Shape::Join(_, _)
            | Shape::Join3(_, _, _)
            | Shape::Race(_, _) => true,
        }
    }
}

fn clone_box(s: &Shape) -> Box<Shape> {
    Box::new(s.clone())
}

/// Enumerates every shape whose depth is `<= max_depth`, built only from the
/// enabled `combs`.
///
/// The construction is canonical: each structurally distinct tree is produced
/// exactly once. `shapes_up_to(d)` = `{Marker}` plus, for every enabled
/// combinator, that combinator applied to all child tuples drawn from
/// `shapes_up_to(d - 1)`. Because `shapes_up_to(d - 1) ⊆ shapes_up_to(d)`, the
/// single top-level call already contains all shallower trees, each once.
pub fn shapes_up_to(combs: &[Comb], max_depth: u32) -> Vec<Shape> {
    let mut out = vec![Shape::Marker];
    if max_depth == 0 {
        return out;
    }
    let smaller = shapes_up_to(combs, max_depth - 1);
    for &c in combs {
        match c {
            Comb::Seq => {
                for a in &smaller {
                    for b in &smaller {
                        out.push(Shape::Seq(clone_box(a), clone_box(b)));
                    }
                }
            }
            Comb::If => {
                for a in &smaller {
                    for b in &smaller {
                        out.push(Shape::If {
                            then_b: clone_box(a),
                            else_b: clone_box(b),
                            cond: Cond::True,
                        });
                    }
                }
            }
            Comb::Loop => {
                for a in &smaller {
                    out.push(Shape::Loop(clone_box(a)));
                }
            }
            Comb::Join => {
                for a in &smaller {
                    for b in &smaller {
                        out.push(Shape::Join(clone_box(a), clone_box(b)));
                    }
                }
            }
            Comb::Join3 => {
                for a in &smaller {
                    for b in &smaller {
                        for c2 in &smaller {
                            out.push(Shape::Join3(clone_box(a), clone_box(b), clone_box(c2)));
                        }
                    }
                }
            }
            Comb::Race => {
                for a in &smaller {
                    for b in &smaller {
                        out.push(Shape::Race(clone_box(a), clone_box(b)));
                    }
                }
            }
        }
    }
    out
}

/// Hand-written seed shapes that cover paths the canonical enumeration omits:
/// the else-taken `df.if` branch and `df.break` inside a loop.
///
/// (`loop`-not-at-root and `join`-inside-loop — issues #227 and #230 — are
/// already covered structurally by the depth-2 enumeration, e.g. `S(M,L(M))`
/// and `L(J(M,M))`; they need no dedicated seed.)
pub fn seed_shapes() -> Vec<Shape> {
    vec![
        // else-taken: only the else marker runs.
        Shape::If {
            then_b: Box::new(Shape::Marker),
            else_b: Box::new(Shape::Marker),
            cond: Cond::False,
        },
        // else-taken nested under a sequence.
        Shape::Seq(
            Box::new(Shape::If {
                then_b: Box::new(Shape::Marker),
                else_b: Box::new(Shape::Marker),
                cond: Cond::False,
            }),
            Box::new(Shape::Marker),
        ),
        // break after 3 iterations.
        Shape::LoopBreak { n: 3 },
    ]
}

/// Builds the final, deterministically ordered shape list.
///
/// Shapes are sorted by signature so identifiers are stable regardless of the
/// enumeration traversal order. An optional `max_shapes` cap truncates the
/// sorted list (used to bound deeper, combinatorially large profiles).
pub fn build_matrix(
    combs: &[Comb],
    max_depth: u32,
    include_seeds: bool,
    max_shapes: Option<usize>,
) -> Vec<Shape> {
    let mut all = shapes_up_to(combs, max_depth);
    if include_seeds {
        // Seeds are hand-written depth-1/2 shapes; honor the depth bound so
        // `--max-depth` stays a reliable structural-complexity cap (a depth-2
        // seed must not leak into a depth-1 matrix).
        all.extend(seed_shapes().into_iter().filter(|s| s.depth() <= max_depth));
    }
    // Dedup by signature (seeds may coincide with enumerated shapes), then sort
    // for a canonical, review-friendly order.
    let mut by_sig: BTreeMap<String, Shape> = BTreeMap::new();
    for s in all {
        by_sig.entry(s.signature()).or_insert(s);
    }
    let mut ordered: Vec<Shape> = by_sig.into_values().collect();
    ordered.sort_by_key(|s| s.signature());
    if let Some(cap) = max_shapes {
        ordered.truncate(cap);
    }
    ordered
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFAULT: [Comb; 5] = [Comb::Seq, Comb::If, Comb::Loop, Comb::Join, Comb::Race];

    #[test]
    fn depth0_is_single_marker() {
        let s = shapes_up_to(&DEFAULT, 0);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].signature(), "M");
    }

    #[test]
    fn depth1_count_is_six() {
        // 1 marker + seq + if + loop + join + race (each over a single marker).
        let s = shapes_up_to(&DEFAULT, 1);
        assert_eq!(s.len(), 6);
    }

    #[test]
    fn depth2_default_count_is_151() {
        let s = shapes_up_to(&DEFAULT, 2);
        assert_eq!(s.len(), 151);
    }

    #[test]
    fn depth2_with_join3_count_is_547() {
        let full = [
            Comb::Seq,
            Comb::If,
            Comb::Loop,
            Comb::Join,
            Comb::Join3,
            Comb::Race,
        ];
        let s = shapes_up_to(&full, 2);
        assert_eq!(s.len(), 547);
    }

    #[test]
    fn enumeration_has_no_duplicate_signatures() {
        let s = shapes_up_to(&DEFAULT, 2);
        let mut sigs: Vec<String> = s.iter().map(|x| x.signature()).collect();
        sigs.sort();
        let before = sigs.len();
        sigs.dedup();
        assert_eq!(before, sigs.len(), "enumeration produced duplicate shapes");
    }

    #[test]
    fn depth_matches_structure() {
        assert_eq!(Shape::Marker.depth(), 0);
        let loop_join = Shape::Loop(Box::new(Shape::Join(
            Box::new(Shape::Marker),
            Box::new(Shape::Marker),
        )));
        assert_eq!(loop_join.depth(), 2);
    }

    #[test]
    fn build_matrix_is_deterministic() {
        let a = build_matrix(&DEFAULT, 2, true, None);
        let b = build_matrix(&DEFAULT, 2, true, None);
        let sa: Vec<String> = a.iter().map(|s| s.signature()).collect();
        let sb: Vec<String> = b.iter().map(|s| s.signature()).collect();
        assert_eq!(sa, sb);
    }

    /// The exact set of signatures that fail live execution in the depth-2
    /// matrix, captured from a clean, trace-isolated characterization run during
    /// Phase 2 bring-up (a live `--include-generated` run on the depth-2 matrix;
    /// see `tests/e2e/generated/README.md`). `is_problematic` must reproduce this
    /// set precisely so the quarantine split stays in lock-step with observed
    /// product behavior.
    ///
    /// To refresh after a product loop-handling fix: re-run the matrix live,
    /// collect the signatures that now pass, remove them from this array, and
    /// promote them out of `quarantine/`. A mismatch fails
    /// `is_problematic_matches_empirical_depth2_failset` below.
    const EMPIRICAL_FAILS: [&str; 26] = [
        "J(I(M,M),L(M))",
        "J(J(M,M),L(M))",
        "J(L(M),I(M,M))",
        "J(L(M),J(M,M))",
        "J(L(M),L(M))",
        "J(L(M),M)",
        "J(L(M),R(M,M))",
        "J(L(M),S(M,M))",
        "J(M,L(M))",
        "J(R(M,M),L(M))",
        "J(S(M,M),L(M))",
        "L(J(M,M))",
        "L(L(M))",
        "L(R(M,M))",
        "R(L(M),I(M,M))",
        "R(L(M),J(M,M))",
        "R(L(M),L(M))",
        "R(L(M),M)",
        "R(L(M),R(M,M))",
        "R(L(M),S(M,M))",
        "S(I(M,M),L(M))",
        "S(J(M,M),L(M))",
        "S(L(M),L(M))",
        "S(M,L(M))",
        "S(R(M,M),L(M))",
        "S(S(M,M),L(M))",
    ];

    #[test]
    fn is_problematic_matches_empirical_depth2_failset() {
        use std::collections::BTreeSet;
        let expected: BTreeSet<&str> = EMPIRICAL_FAILS.iter().copied().collect();

        let matrix = build_matrix(&DEFAULT, 2, true, None);
        let mut false_positives = Vec::new();
        let mut false_negatives = Vec::new();
        for shape in &matrix {
            let sig = shape.signature();
            let predicted_fail = shape.is_problematic().is_some();
            let actually_fails = expected.contains(sig.as_str());
            match (predicted_fail, actually_fails) {
                (true, false) => false_positives.push(sig),
                (false, true) => false_negatives.push(sig),
                _ => {}
            }
        }
        assert!(
            false_positives.is_empty() && false_negatives.is_empty(),
            "classifier disagrees with empirical fail set:\n  \
             false positives (predicted fail, actually pass): {false_positives:?}\n  \
             false negatives (predicted pass, actually fail): {false_negatives:?}"
        );

        // Every empirical fail must correspond to a real matrix shape.
        let matrix_sigs: BTreeSet<String> = matrix.iter().map(|s| s.signature()).collect();
        for sig in &expected {
            assert!(
                matrix_sigs.contains(*sig),
                "empirical fail '{sig}' is not present in the generated matrix"
            );
        }
    }

    #[test]
    fn is_problematic_reasons_are_stable() {
        let cases: [(&str, Shape); 5] = [
            // loop in a join branch
            (
                "loop-in-join",
                Shape::Join(
                    Box::new(Shape::Marker),
                    Box::new(Shape::Loop(Box::new(Shape::Marker))),
                ),
            ),
            // loop in the race winner slot
            (
                "loop-in-race-winner",
                Shape::Race(
                    Box::new(Shape::Loop(Box::new(Shape::Marker))),
                    Box::new(Shape::Marker),
                ),
            ),
            // loop in a non-leading sequence position
            (
                "loop-in-seq-tail",
                Shape::Seq(
                    Box::new(Shape::Marker),
                    Box::new(Shape::Loop(Box::new(Shape::Marker))),
                ),
            ),
            // loop whose body is itself a combinator
            (
                "loop-body-combinator",
                Shape::Loop(Box::new(Shape::Join(
                    Box::new(Shape::Marker),
                    Box::new(Shape::Marker),
                ))),
            ),
            // a top-level loop over a marker is fine
            ("", Shape::Loop(Box::new(Shape::Marker))),
        ];
        for (want, shape) in cases {
            match (want, shape.is_problematic()) {
                ("", got) => assert_eq!(got, None, "expected pass, got {got:?}"),
                (reason, got) => assert_eq!(got, Some(reason)),
            }
        }
    }

    #[test]
    fn loop_in_race_loser_and_if_branch_pass() {
        // loop confined to the abandoned race loser is safe
        let race_loser = Shape::Race(
            Box::new(Shape::Marker),
            Box::new(Shape::Loop(Box::new(Shape::Marker))),
        );
        assert_eq!(race_loser.is_problematic(), None);
        // loop in an if branch at top level is safe
        let if_branch = Shape::If {
            then_b: Box::new(Shape::Loop(Box::new(Shape::Marker))),
            else_b: Box::new(Shape::Marker),
            cond: Cond::True,
        };
        assert_eq!(if_branch.is_problematic(), None);
        // leading loop in a sequence is safe
        let seq_lead = Shape::Seq(
            Box::new(Shape::Loop(Box::new(Shape::Marker))),
            Box::new(Shape::Marker),
        );
        assert_eq!(seq_lead.is_problematic(), None);
    }

    #[test]
    fn seq_tail_does_not_mask_host_join_danger() {
        // Regression (S2): a loop in a seq tail that is itself inside a join
        // branch must keep the stronger host reason, not be relabeled
        // "loop-in-seq-tail".
        let shape = Shape::Join(
            Box::new(Shape::Seq(
                Box::new(Shape::Marker),
                Box::new(Shape::Loop(Box::new(Shape::Marker))),
            )),
            Box::new(Shape::Marker),
        );
        assert_eq!(shape.is_problematic(), Some("loop-in-join"));
    }

    #[test]
    fn loop_over_pure_marker_tree_is_safe() {
        // Regression (M1): a loop whose body is a combinator-free Seq/If tree is
        // safe and must classify as `None` (guards the removed dead
        // `loop-nested` recursion that used to run here).
        let seq_body = Shape::Loop(Box::new(Shape::Seq(
            Box::new(Shape::Marker),
            Box::new(Shape::Marker),
        )));
        assert_eq!(seq_body.is_problematic(), None);
        let if_body = Shape::Loop(Box::new(Shape::If {
            then_b: Box::new(Shape::Marker),
            else_b: Box::new(Shape::Marker),
            cond: Cond::True,
        }));
        assert_eq!(if_body.is_problematic(), None);
    }

    #[test]
    fn contains_combinator_is_exhaustive() {
        let m = || Box::new(Shape::Marker);
        // Transparent control flow / leaves spawn no sub-orchestration of their
        // own.
        assert!(!Shape::Marker.contains_combinator());
        assert!(!Shape::Seq(m(), m()).contains_combinator());
        assert!(!Shape::If {
            then_b: m(),
            else_b: m(),
            cond: Cond::True,
        }
        .contains_combinator());
        // Combinators a surrounding loop body would re-enter every iteration.
        assert!(Shape::Loop(m()).contains_combinator());
        assert!(Shape::LoopBreak { n: 2 }.contains_combinator());
        assert!(Shape::Join(m(), m()).contains_combinator());
        assert!(Shape::Join3(m(), m(), m()).contains_combinator());
        assert!(Shape::Race(m(), m()).contains_combinator());
    }

    #[test]
    fn seeds_respect_max_depth() {
        // Regression (S7): the `Seq(If(else),M)` seed has structural depth 2 and
        // must not leak into a depth-1 matrix.
        let d1 = build_matrix(&DEFAULT, 1, true, None);
        assert!(
            !d1.iter().any(|s| s.signature() == "S(Ielse(M,M),M)"),
            "depth-2 seed leaked into a depth-1 matrix"
        );
        // At depth 2 the seed is present.
        let d2 = build_matrix(&DEFAULT, 2, true, None);
        assert!(d2.iter().any(|s| s.signature() == "S(Ielse(M,M),M)"));
    }
}
