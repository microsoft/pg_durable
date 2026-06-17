// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Phase 4 (#232) — metamorphic relations.
//!
//! A metamorphic relation is an equivalence-class test: two DSL programs the
//! runtime should treat as observably equivalent, run side by side, asserting
//! that the same things happened in both.
//!
//! The Phase 2 matrix tags every marker by its STRUCTURAL `node_path` (`r`,
//! `r.0`, `r.b`…), which necessarily differs between two structurally-different
//! (but equivalent) programs. So metamorphic relations instead tag markers by a
//! STABLE LEAF LABEL (`a`, `b`, `c`): the same logical leaf carries the same
//! label in BOTH programs of a pair. The observable is then the multiset
//! `{label -> completed-count}`, and the equivalence predicate is multiset
//! equality. Untaken `if` branches and abandoned `race` losers simply produce
//! no trace rows, so they contribute 0 to the multiset automatically.
//!
//! Each relation emits ONE self-contained `.sql` test that starts both programs
//! (tagged `meta-NNNN-a` / `meta-NNNN-b` in the shared `df_gen_trace`), waits for
//! both, asserts the Phase 1 oracle passes for both, then asserts:
//!   1. HEADLINE — `observable(A) == observable(B)` (EXCEPT-based multiset diff).
//!   2. BACKSTOP — each side equals the generator-computed ground truth. This
//!      catches a symmetric bug where A and B are wrong the *same* way (which the
//!      pure-state Phase 1 invariants and the headline check would both miss).

use crate::emit::json_escape;
use crate::render::marker_sql;
use crate::shape::Cond;
use std::collections::BTreeMap;

/// Sleep (seconds) for the deterministic loser branch of a metamorphic `race`.
///
/// The winner is a near-instant marker, so duroxide resolves the race and
/// abandons this sleep the moment the marker completes — the timer never fires
/// and adds no latency. A large value is therefore free insurance against
/// scheduler jitter ever letting the loser win.
const RACE_LOSER_SLEEP_SECS: u64 = 30;

/// A label-tagged program: the metamorphic counterpart to a `Shape`.
///
/// Unlike `Shape`, leaves carry an explicit, stable label so the same logical
/// leaf can appear in both programs of an equivalence pair.
#[derive(Clone, Debug)]
pub enum Meta {
    /// A marker leaf that records one completion under `label`.
    Leaf(String),
    /// `a` then `b`.
    Seq(Box<Meta>, Box<Meta>),
    /// `df.if(cond, then, else)` — only the taken branch runs.
    If(Cond, Box<Meta>, Box<Meta>),
    /// `df.join(a, b)` — both branches run.
    Join(Box<Meta>, Box<Meta>),
    /// `df.race(winner, df.sleep(N))` — only `winner` runs to completion.
    Race(Box<Meta>),
    /// A do-while loop that runs `body` exactly `k` times, terminating once the
    /// `anchor` leaf (which `body` must contain) has executed `k` times.
    DoWhile {
        body: Box<Meta>,
        anchor: String,
        k: u64,
    },
    /// A loop that runs `body` then `df.break`s once the `anchor` leaf has
    /// executed `n` times, yielding exactly `n` body runs.
    LoopBreak {
        body: Box<Meta>,
        anchor: String,
        n: u64,
    },
}

/// Computes the ground-truth observable multiset for a program.
///
/// `mult` is the number of times the enclosing context runs this subtree (1 at
/// the root, scaled by loop counts). Leaves accumulate; untaken/abandoned
/// branches are simply never visited, so they never appear in the map.
fn eval(prog: &Meta, mult: u64, out: &mut BTreeMap<String, u64>) {
    match prog {
        Meta::Leaf(label) => *out.entry(label.clone()).or_insert(0) += mult,
        Meta::Seq(a, b) => {
            eval(a, mult, out);
            eval(b, mult, out);
        }
        Meta::If(cond, then, els) => match cond {
            Cond::True => eval(then, mult, out),
            Cond::False => eval(els, mult, out),
        },
        Meta::Join(a, b) => {
            eval(a, mult, out);
            eval(b, mult, out);
        }
        Meta::Race(winner) => eval(winner, mult, out),
        Meta::DoWhile { body, k, .. } => eval(body, mult.saturating_mul(*k), out),
        Meta::LoopBreak { body, n, .. } => eval(body, mult.saturating_mul(*n), out),
    }
}

/// The observable multiset `{label -> completed-count}` for a program.
pub fn observable(prog: &Meta) -> BTreeMap<String, u64> {
    let mut m = BTreeMap::new();
    eval(prog, 1, &mut m);
    m
}

/// Renders a program to a pg_durable DSL string under trace tag `tag`.
///
/// Reuses the exact Phase 2 constructs (`marker_sql`, `df.seq`, `df.if`,
/// `df.join`, `df.race`, `df.loop`, `df.break`) so the two infrastructures stay
/// semantically identical.
pub(crate) fn render_prog(prog: &Meta, tag: &str) -> String {
    match prog {
        Meta::Leaf(label) => marker_sql(label, tag),
        Meta::Seq(a, b) => format!("df.seq({}, {})", render_prog(a, tag), render_prog(b, tag)),
        Meta::If(cond, then, els) => format!(
            "df.if($c${}$c$, {}, {})",
            cond.sql(),
            render_prog(then, tag),
            render_prog(els, tag)
        ),
        Meta::Join(a, b) => format!("df.join({}, {})", render_prog(a, tag), render_prog(b, tag)),
        Meta::Race(winner) => format!(
            "df.race({}, df.sleep({RACE_LOSER_SLEEP_SECS}))",
            render_prog(winner, tag)
        ),
        Meta::DoWhile { body, anchor, k } => {
            // do-while: body runs, THEN this predicate is checked. Counting an
            // EXISTING body leaf (the anchor) keeps the observable pure — no
            // synthetic counter leaf pollutes the multiset.
            //
            // READ-YOUR-WRITES DEPENDENCY: the predicate COUNTs the anchor's
            // prior marker rows in `df_gen_trace`, so iteration i's marker
            // INSERT must be visible to the condition query that gates iteration
            // i+1. This holds because each marker and each loop condition runs
            // as its own duroxide activity — an autocommitted statement under
            // READ COMMITTED — so a committed marker is always visible to the
            // next condition read. The live meta E2E is the empirical check; if
            // a future runtime ever batched body+condition into one uncommitted
            // unit, the count could read stale and the loop could over-run. The
            // same dependency applies to `LoopBreak` below.
            let cond = format!(
                "SELECT COUNT(*) < {k} FROM df_gen_trace \
WHERE shape_id = '{tag}' AND node_path = '{anchor}'"
            );
            format!("df.loop({}, $c${cond}$c$)", render_prog(body, tag))
        }
        Meta::LoopBreak { body, anchor, n } => {
            // See the read-your-writes note on `DoWhile`: the break predicate
            // likewise reads committed anchor rows from `df_gen_trace`.
            let break_cond = format!(
                "SELECT (SELECT COUNT(*) FROM df_gen_trace \
WHERE shape_id = '{tag}' AND node_path = '{anchor}') >= {n}"
            );
            format!(
                "df.loop(df.seq({}, df.if($c${break_cond}$c$, df.break(), $c$SELECT 1$c$)), \
$c$SELECT true$c$)",
                render_prog(body, tag)
            )
        }
    }
}

/// One metamorphic relation: a pair of programs plus the multiset they must both
/// produce.
pub struct Relation {
    /// Stable id, e.g. `meta-0001`.
    pub id: String,
    /// Short relation name, e.g. `seq-assoc`.
    pub name: &'static str,
    /// Why the two programs are equivalent (documentation / manifest).
    pub rationale: &'static str,
    pub prog_a: Meta,
    pub prog_b: Meta,
    /// Generator-computed observable both sides must equal.
    pub expected: BTreeMap<String, u64>,
}

fn leaf(label: &str) -> Box<Meta> {
    Box::new(Meta::Leaf(label.to_string()))
}

/// The registry of metamorphic relations.
///
/// Every relation holds under BOTH correct semantics and the *current* runtime,
/// so all are live. (None nests a loop in a non-root / join / race position, the
/// #227/#230/#233 defect zone — a loop at the root works correctly.) For each
/// relation this asserts `observable(A) == observable(B)`, so a mis-specified
/// pair fails loudly at generation time rather than producing a vacuous test.
pub fn registry() -> Vec<Relation> {
    let specs: Vec<(&'static str, &'static str, Meta, Meta)> = vec![
        (
            "seq-assoc",
            "Sequence is associative: re-grouping nested seq does not change the \
order or the set of side effects.",
            Meta::Seq(leaf("a"), Box::new(Meta::Seq(leaf("b"), leaf("c")))),
            Meta::Seq(Box::new(Meta::Seq(leaf("a"), leaf("b"))), leaf("c")),
        ),
        (
            "if-true",
            "A constant-true if reduces to its then-branch; the else-branch never runs.",
            Meta::If(Cond::True, leaf("a"), leaf("b")),
            Meta::Leaf("a".to_string()),
        ),
        (
            "if-false",
            "A constant-false if reduces to its else-branch; the then-branch never runs.",
            Meta::If(Cond::False, leaf("a"), leaf("b")),
            Meta::Leaf("b".to_string()),
        ),
        (
            "join-comm",
            "Parallel join is commutative: swapping branches yields the same \
multiset of side effects.",
            Meta::Join(leaf("a"), leaf("b")),
            Meta::Join(leaf("b"), leaf("a")),
        ),
        (
            "race-winner",
            "A race whose only other branch is a long sleep reduces to its \
deterministic winner.",
            Meta::Race(leaf("a")),
            Meta::Leaf("a".to_string()),
        ),
        (
            "do-while-once",
            "A do-while loop whose condition is already false after the first body \
run reduces to its body.",
            Meta::DoWhile {
                body: leaf("a"),
                anchor: "a".to_string(),
                k: 1,
            },
            Meta::Leaf("a".to_string()),
        ),
        (
            "loop-break-once",
            "A loop that breaks immediately after its first body run reduces to its body.",
            Meta::LoopBreak {
                body: leaf("a"),
                anchor: "a".to_string(),
                n: 1,
            },
            Meta::Leaf("a".to_string()),
        ),
    ];

    specs
        .into_iter()
        .enumerate()
        .map(|(idx, (name, rationale, prog_a, prog_b))| {
            let exp_a = observable(&prog_a);
            let exp_b = observable(&prog_b);
            assert_eq!(
                exp_a, exp_b,
                "relation '{name}' is mis-specified: observable(A)={exp_a:?} != observable(B)={exp_b:?}"
            );
            // A relation whose observable is empty would be vacuous: both sides
            // trivially agree (multiset {} == {}) even if the runtime executed
            // nothing. Enforce non-vacuity in the generation path, not just in
            // the unit tests, so such a relation can never be rendered.
            assert!(
                !exp_a.is_empty(),
                "relation '{name}' has an empty observable — a vacuous metamorphic test"
            );
            Relation {
                id: format!("meta-{:04}", idx + 1),
                name,
                rationale,
                prog_a,
                prog_b,
                expected: exp_a,
            }
        })
        .collect()
}

/// Renders the full text of a self-contained `.sql` E2E test for one relation.
///
/// This is the metamorphic sibling of `emit::sql_test` (the Phase 2 matrix
/// renderer). The two intentionally diverge — this one tags markers by STABLE
/// LEAF LABEL and asserts a multiset equivalence between two programs, whereas
/// `emit::sql_test` tags by STRUCTURAL `node_path` and asserts per-path counts
/// for a single program. They share the same `df_gen_trace` schema, Phase 1
/// oracle call, and `SELECT 'TEST PASSED'` epilogue; a maintainer changing any
/// of those shared conventions in one renderer should mirror it in the other
/// (`backstop_guards_are_emitted` / `sql_test_has_expected_anatomy` pin the
/// emitted shapes so silent drift fails a unit test).
pub fn meta_sql_test(rel: &Relation, wait_timeout: u32) -> String {
    let id = &rel.id;
    let tag_a = format!("{id}-a");
    let tag_b = format!("{id}-b");
    let dsl_a = render_prog(&rel.prog_a, &tag_a);
    let dsl_b = render_prog(&rel.prog_b, &tag_b);
    let mut out = String::new();

    out.push_str("-- Copyright (c) Microsoft Corporation.\n");
    out.push_str("-- Licensed under the PostgreSQL License.\n");
    out.push_str("--\n");
    out.push_str(
        "-- AUTO-GENERATED by pg_durable_matrix_gen (metamorphic) — DO NOT EDIT BY HAND.\n",
    );
    out.push_str(
        "-- Regenerate: cargo run --manifest-path tests/e2e/generated/generator/Cargo.toml\n",
    );
    out.push_str(&format!("-- Relation {id}  name={}\n", rel.name));
    out.push_str(&format!("-- {}\n", rel.rationale));
    out.push_str(
        "-- Metamorphic: programs A and B must produce the same observable (the\n\
         -- multiset of leaf-label execution counts). The test asserts\n\
         -- observable(A) == observable(B) AND that each side matches the\n\
         -- generator ground truth.\n",
    );
    out.push('\n');

    out.push_str("SET SESSION AUTHORIZATION df_e2e_user;\n\n");
    out.push_str(
        "CREATE TABLE IF NOT EXISTS df_gen_trace (shape_id TEXT, node_path TEXT, iteration INT, \
wall_clock TIMESTAMPTZ);\n",
    );
    out.push_str("ALTER TABLE df_gen_trace ADD COLUMN IF NOT EXISTS shape_id TEXT;\n");
    out.push_str(&format!(
        "DELETE FROM df_gen_trace WHERE shape_id IN ('{tag_a}', '{tag_b}');\n\n"
    ));

    out.push_str("CREATE TEMP TABLE _meta_state (which TEXT, instance_id TEXT);\n");
    out.push_str("INSERT INTO _meta_state SELECT 'a', df.start(\n    ");
    out.push_str(&dsl_a);
    out.push_str(&format!(",\n    '{tag_a}'\n);\n"));
    out.push_str("INSERT INTO _meta_state SELECT 'b', df.start(\n    ");
    out.push_str(&dsl_b);
    out.push_str(&format!(",\n    '{tag_b}'\n);\n\n"));

    out.push_str("DO $GEN$\n");
    out.push_str("DECLARE\n");
    out.push_str("    inst_a TEXT;\n");
    out.push_str("    inst_b TEXT;\n");
    out.push_str("    status TEXT;\n");
    out.push_str("    all_passed BOOLEAN;\n");
    out.push_str("    viol TEXT;\n");
    out.push_str("    unexpected TEXT;\n");
    out.push_str("    diff_rows INT;\n");
    out.push_str("BEGIN\n");
    out.push_str("    SELECT instance_id INTO inst_a FROM _meta_state WHERE which = 'a';\n");
    out.push_str("    SELECT instance_id INTO inst_b FROM _meta_state WHERE which = 'b';\n\n");

    // Both instances must complete.
    out.push_str(&format!(
        "    SELECT df.wait_for_completion(inst_a, {wait_timeout}) INTO status;\n"
    ));
    out.push_str("    IF status != 'completed' THEN\n");
    out.push_str(&format!(
        "        RAISE EXCEPTION 'TEST FAILED [{id}/a]: status = %', status;\n"
    ));
    out.push_str("    END IF;\n");
    out.push_str(&format!(
        "    SELECT df.wait_for_completion(inst_b, {wait_timeout}) INTO status;\n"
    ));
    out.push_str("    IF status != 'completed' THEN\n");
    out.push_str(&format!(
        "        RAISE EXCEPTION 'TEST FAILED [{id}/b]: status = %', status;\n"
    ));
    out.push_str("    END IF;\n\n");

    // Phase 1 oracle must pass for both programs.
    out.push_str("    -- Phase 1 structural-invariant oracle must pass for both programs.\n");
    for (which, inst) in [("a", "inst_a"), ("b", "inst_b")] {
        out.push_str(
            "    SELECT COALESCE(bool_and(passed), false), \
string_agg(invariant, ', ') FILTER (WHERE NOT passed)\n",
        );
        out.push_str(&format!(
            "      INTO all_passed, viol\n      FROM df.assert_structural_invariants({inst});\n"
        ));
        out.push_str("    IF NOT all_passed THEN\n");
        out.push_str(&format!(
            "        RAISE EXCEPTION 'TEST FAILED [{id}/{which}]: invariant violation(s): %', viol;\n"
        ));
        out.push_str("    END IF;\n");
    }
    out.push('\n');

    // HEADLINE: observable(A) multiset == observable(B) multiset.
    out.push_str(
        "    -- Metamorphic relation: observable(A) multiset == observable(B) multiset.\n",
    );
    out.push_str("    SELECT COUNT(*) INTO diff_rows FROM (\n");
    out.push_str(&format!(
        "        (SELECT node_path, COUNT(*) AS n FROM df_gen_trace \
WHERE shape_id = '{tag_a}' GROUP BY node_path\n"
    ));
    out.push_str("         EXCEPT\n");
    out.push_str(&format!(
        "         SELECT node_path, COUNT(*) AS n FROM df_gen_trace \
WHERE shape_id = '{tag_b}' GROUP BY node_path)\n"
    ));
    out.push_str("        UNION ALL\n");
    out.push_str(&format!(
        "        (SELECT node_path, COUNT(*) AS n FROM df_gen_trace \
WHERE shape_id = '{tag_b}' GROUP BY node_path\n"
    ));
    out.push_str("         EXCEPT\n");
    out.push_str(&format!(
        "         SELECT node_path, COUNT(*) AS n FROM df_gen_trace \
WHERE shape_id = '{tag_a}' GROUP BY node_path)\n"
    ));
    out.push_str("    ) d;\n");
    out.push_str("    IF diff_rows <> 0 THEN\n");
    out.push_str(&format!(
        "        RAISE EXCEPTION 'TEST FAILED [{id}]: observable(A) != observable(B) \
(% differing label-count row(s))', diff_rows;\n"
    ));
    out.push_str("    END IF;\n\n");

    // BACKSTOP: each side matches the generator-computed expected multiset.
    out.push_str("    -- Backstop: each side matches the generator ground truth (catches a\n");
    out.push_str("    -- symmetric bug where A and B are wrong in the same way).\n");
    for (which, tag) in [("a", &tag_a), ("b", &tag_b)] {
        for (label, count) in &rel.expected {
            out.push_str(&format!(
                "    IF (SELECT COUNT(*) FROM df_gen_trace \
WHERE shape_id = '{tag}' AND node_path = '{label}') <> {count} THEN\n"
            ));
            out.push_str(&format!(
                "        RAISE EXCEPTION 'TEST FAILED [{id}/{which}]: label {label} expected {count}, got %',\n"
            ));
            out.push_str(&format!(
                "            (SELECT COUNT(*) FROM df_gen_trace \
WHERE shape_id = '{tag}' AND node_path = '{label}');\n"
            ));
            out.push_str("    END IF;\n");
        }
        if rel.expected.is_empty() {
            out.push_str("    SELECT string_agg(DISTINCT node_path, ', ') INTO unexpected\n");
            out.push_str(&format!(
                "      FROM df_gen_trace WHERE shape_id = '{tag}';\n"
            ));
        } else {
            let known: Vec<String> = rel.expected.keys().map(|l| format!("'{l}'")).collect();
            out.push_str("    SELECT string_agg(DISTINCT node_path, ', ') INTO unexpected\n");
            out.push_str(&format!(
                "      FROM df_gen_trace WHERE shape_id = '{tag}' AND node_path NOT IN ({});\n",
                known.join(", ")
            ));
        }
        out.push_str("    IF unexpected IS NOT NULL THEN\n");
        out.push_str(&format!(
            "        RAISE EXCEPTION 'TEST FAILED [{id}/{which}]: unexpected label(s): %', unexpected;\n"
        ));
        out.push_str("    END IF;\n");
    }

    out.push_str("END $GEN$;\n\n");
    out.push_str("DROP TABLE _meta_state;\n");
    out.push_str("SELECT 'TEST PASSED' AS result;\n");

    out
}

/// Serializes the relation registry to the golden `meta-manifest.json`
/// (deterministic, 2-space indented).
pub fn meta_manifest_json(rels: &[Relation]) -> String {
    let mut out = String::new();
    out.push_str("{\n");
    out.push_str("  \"version\": 1,\n");
    out.push_str("  \"generator\": \"pg_durable_matrix_gen\",\n");
    out.push_str("  \"kind\": \"metamorphic\",\n");
    out.push_str(&format!("  \"relation_count\": {},\n", rels.len()));
    out.push_str("  \"relations\": [\n");

    for (i, rel) in rels.iter().enumerate() {
        let tag_a = format!("{}-a", rel.id);
        let tag_b = format!("{}-b", rel.id);
        out.push_str("    {\n");
        out.push_str(&format!("      \"id\": \"{}\",\n", rel.id));
        out.push_str(&format!("      \"name\": \"{}\",\n", json_escape(rel.name)));
        out.push_str(&format!(
            "      \"rationale\": \"{}\",\n",
            json_escape(rel.rationale)
        ));
        out.push_str(&format!(
            "      \"dsl_a\": \"{}\",\n",
            json_escape(&render_prog(&rel.prog_a, &tag_a))
        ));
        out.push_str(&format!(
            "      \"dsl_b\": \"{}\",\n",
            json_escape(&render_prog(&rel.prog_b, &tag_b))
        ));

        if rel.expected.is_empty() {
            out.push_str("      \"expected\": {}\n");
        } else {
            out.push_str("      \"expected\": {\n");
            let entries: Vec<String> = rel
                .expected
                .iter()
                .map(|(l, c)| format!("        \"{}\": {}", json_escape(l), c))
                .collect();
            out.push_str(&entries.join(",\n"));
            out.push_str("\n      }\n");
        }

        if i + 1 < rels.len() {
            out.push_str("    },\n");
        } else {
            out.push_str("    }\n");
        }
    }

    out.push_str("  ]\n");
    out.push_str("}\n");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Strips `$tag$…$tag$` dollar-quoted spans so paren-balance checks ignore
    /// SQL text. Only the two tags the renderer emits (`$mk$`, `$c$`) are used.
    fn strip_quoted(mut s: String, tag: &str) -> String {
        while let Some(start) = s.find(tag) {
            let Some(rel) = s[start + tag.len()..].find(tag) else {
                break;
            };
            let end = start + tag.len() + rel + tag.len();
            s.replace_range(start..end, "");
        }
        s
    }

    fn parens_balanced(dsl: &str) -> bool {
        let stripped = strip_quoted(strip_quoted(dsl.to_string(), "$mk$"), "$c$");
        let mut depth: i32 = 0;
        for c in stripped.chars() {
            match c {
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

    #[test]
    fn registry_is_nonempty() {
        assert!(!registry().is_empty());
    }

    #[test]
    fn ids_are_sequential() {
        for (i, rel) in registry().iter().enumerate() {
            assert_eq!(rel.id, format!("meta-{:04}", i + 1));
        }
    }

    #[test]
    fn every_relation_is_equivalent_and_nonvacuous() {
        for rel in registry() {
            let a = observable(&rel.prog_a);
            let b = observable(&rel.prog_b);
            assert_eq!(a, b, "relation '{}' A != B", rel.name);
            assert_eq!(a, rel.expected, "relation '{}' expected mismatch", rel.name);
            assert!(
                !rel.expected.is_empty(),
                "relation '{}' has an empty observable",
                rel.name
            );
        }
    }

    #[test]
    fn interpreter_matches_hand_computed() {
        // seq(a, seq(b, c)) -> {a:1, b:1, c:1}
        let p = Meta::Seq(leaf("a"), Box::new(Meta::Seq(leaf("b"), leaf("c"))));
        let o = observable(&p);
        assert_eq!(o.get("a"), Some(&1));
        assert_eq!(o.get("b"), Some(&1));
        assert_eq!(o.get("c"), Some(&1));
        assert_eq!(o.len(), 3);

        // if(false, a, b) -> {b:1}; a never runs.
        let p = Meta::If(Cond::False, leaf("a"), leaf("b"));
        let o = observable(&p);
        assert_eq!(o.get("b"), Some(&1));
        assert_eq!(o.get("a"), None);
        assert_eq!(o.len(), 1);

        // race(a) -> {a:1}; the sleep loser contributes nothing.
        let o = observable(&Meta::Race(leaf("a")));
        assert_eq!(o, BTreeMap::from([("a".to_string(), 1)]));
    }

    #[test]
    fn loop_multiplier_scales_body() {
        // A do-while body run 3x multiplies its leaves.
        let p = Meta::DoWhile {
            body: Box::new(Meta::Seq(leaf("a"), leaf("b"))),
            anchor: "a".to_string(),
            k: 3,
        };
        let o = observable(&p);
        assert_eq!(o.get("a"), Some(&3));
        assert_eq!(o.get("b"), Some(&3));

        // A loop-break body run 3x (anchor reaches n=3) likewise multiplies —
        // covers the k>1 / n>1 case the single-iteration registry relations do
        // not exercise.
        let p = Meta::LoopBreak {
            body: Box::new(Meta::Seq(leaf("a"), leaf("b"))),
            anchor: "a".to_string(),
            n: 3,
        };
        let o = observable(&p);
        assert_eq!(o.get("a"), Some(&3));
        assert_eq!(o.get("b"), Some(&3));
    }

    #[test]
    fn eval_matches_registry_specs() {
        // Independent ground truth: the expected observable for each relation,
        // hand-written HERE rather than derived from eval(). This breaks the
        // circularity in `every_relation_is_equivalent_and_nonvacuous`, where
        // `rel.expected` is itself produced by eval() — so an eval() bug would
        // agree with itself and ship silently. Both programs of every pair, and
        // the stored `expected`, must match these literals.
        fn hand_computed(name: &str) -> BTreeMap<String, u64> {
            let m = |pairs: &[(&str, u64)]| -> BTreeMap<String, u64> {
                pairs.iter().map(|(l, c)| (l.to_string(), *c)).collect()
            };
            match name {
                "seq-assoc" => m(&[("a", 1), ("b", 1), ("c", 1)]),
                "if-true" => m(&[("a", 1)]),
                "if-false" => m(&[("b", 1)]),
                "join-comm" => m(&[("a", 1), ("b", 1)]),
                "race-winner" => m(&[("a", 1)]),
                "do-while-once" => m(&[("a", 1)]),
                "loop-break-once" => m(&[("a", 1)]),
                other => {
                    panic!("no hand-written ground truth for relation '{other}' — add one here")
                }
            }
        }
        for rel in registry() {
            let want = hand_computed(rel.name);
            assert_eq!(
                observable(&rel.prog_a),
                want,
                "relation '{}': observable(A) != hand-computed",
                rel.name
            );
            assert_eq!(
                observable(&rel.prog_b),
                want,
                "relation '{}': observable(B) != hand-computed",
                rel.name
            );
            assert_eq!(
                rel.expected, want,
                "relation '{}': stored expected != hand-computed",
                rel.name
            );
        }
    }

    #[test]
    fn backstop_guards_are_emitted() {
        // Proves the symmetric-bug BACKSTOP is wired into the rendered SQL: for
        // each side, every expected label gets a `<> count` guard, plus an
        // unexpected-label `NOT IN (...)` guard pinning the side to exactly the
        // known label set. Without these, a bug making A and B wrong the SAME
        // way (equal-but-incorrect observables) would slip past the headline
        // EXCEPT diff. seq-assoc has the richest observable ({a:1,b:1,c:1}).
        let rels = registry();
        let rel = rels.iter().find(|r| r.name == "seq-assoc").unwrap();
        let sql = meta_sql_test(rel, 30);
        let id = &rel.id;
        for which in ["a", "b"] {
            let tag = format!("{id}-{which}");
            for (label, count) in [("a", 1), ("b", 1), ("c", 1)] {
                assert!(
                    sql.contains(&format!(
                        "WHERE shape_id = '{tag}' AND node_path = '{label}') <> {count}"
                    )),
                    "missing per-label backstop guard for {tag}/{label}"
                );
            }
            assert!(
                sql.contains(&format!(
                    "WHERE shape_id = '{tag}' AND node_path NOT IN ('a', 'b', 'c')"
                )),
                "missing unexpected-label backstop guard for {tag}"
            );
        }
    }

    #[test]
    fn renders_have_balanced_parens_and_dollar_quotes() {
        for rel in registry() {
            for (tag, prog) in [
                (format!("{}-a", rel.id), &rel.prog_a),
                (format!("{}-b", rel.id), &rel.prog_b),
            ] {
                let dsl = render_prog(prog, &tag);
                assert!(parens_balanced(&dsl), "unbalanced parens: {dsl}");
                assert_eq!(dsl.matches("$mk$").count() % 2, 0, "unbalanced $mk$: {dsl}");
                assert_eq!(dsl.matches("$c$").count() % 2, 0, "unbalanced $c$: {dsl}");
                // render_prog must never emit df.start (that's the test wrapper).
                assert!(!dsl.contains("df.start"), "render leaked df.start: {dsl}");
            }
        }
    }

    #[test]
    fn sql_test_has_expected_anatomy() {
        let rels = registry();
        let rel = &rels[0];
        let sql = meta_sql_test(rel, 30);
        assert!(sql.contains("SELECT 'TEST PASSED'"));
        assert!(sql.contains(&format!("'{}-a'", rel.id)));
        assert!(sql.contains(&format!("'{}-b'", rel.id)));
        assert!(sql.contains("df.assert_structural_invariants(inst_a)"));
        assert!(sql.contains("df.assert_structural_invariants(inst_b)"));
        assert!(sql.contains("EXCEPT"));
        assert!(sql.contains("observable(A) != observable(B)"));
        // Exactly two durable instances are started.
        assert_eq!(sql.matches("df.start(").count(), 2);
    }

    #[test]
    fn manifest_is_deterministic() {
        let rels = registry();
        assert_eq!(meta_manifest_json(&rels), meta_manifest_json(&rels));
        let m = meta_manifest_json(&rels);
        assert!(m.contains("\"kind\": \"metamorphic\""));
        assert!(m.contains(&format!("\"relation_count\": {}", rels.len())));
    }
}
