// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Shared read-time node-status inference for `df.instance_nodes()` and
//! `df.explain()`.

use std::collections::{HashMap, HashSet};

pub(crate) fn status_details_select_expr(client: &pgrx::spi::SpiClient) -> &'static str {
    let present = client
        .select(
            "SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.columns
                 WHERE table_schema = 'df'
                   AND table_name = 'nodes'
                   AND column_name = 'status_details'
             )",
            None,
            &[],
        )
        .ok()
        .and_then(|table| table.into_iter().next())
        .and_then(|row| row.get::<bool>(1).ok().flatten())
        .unwrap_or(false);

    if present {
        "status_details::text"
    } else {
        "NULL::text"
    }
}

/// Structural facts needed to infer a node's status.
pub trait NodeFacts {
    fn node_type(&self) -> &str;
    fn query(&self) -> Option<&str>;
    fn left_node(&self) -> Option<&str>;
    fn right_node(&self) -> Option<&str>;
    fn status(&self) -> Option<&str>;
    fn status_details(&self) -> Option<&str>;
}

/// Result of inference for a single node.
#[derive(Debug, Clone)]
pub struct Inferred {
    /// The derived status: `pending` / `running` / `completed` / `failed` /
    /// `skipped`.
    pub status: String,
    /// When the status was *derived* from an ancestor (a `skipped` branch or a
    /// superseded loop node), the ancestor node id that drove it; otherwise None.
    pub from_ancestor_id: Option<String>,
}

/// Parse the loop generation (the second "::"-token) from a node's
/// status_details `execution_id` stamp. None when never stamped / unparseable.
fn gen_of(status_details: Option<&str>) -> Option<i64> {
    let sd = status_details?;
    let v: serde_json::Value = serde_json::from_str(sd).ok()?;
    v.get("execution_id")?
        .as_str()?
        .split("::")
        .nth(1)?
        .parse::<i64>()
        .ok()
}

fn is_terminal(status: Option<&str>) -> bool {
    matches!(status, Some("completed") | Some("failed"))
}

/// Enumerate child node ids referenced by compound nodes.
fn children_of<N: NodeFacts>(n: &N) -> Vec<String> {
    fn config_node(query: Option<&str>, key: &str, out: &mut Vec<String>) {
        if let Some(cfg) = query {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(cfg) {
                if let Some(s) = v.get(key).and_then(|c| c.as_str()) {
                    out.push(s.to_string());
                }
            }
        }
    }
    let mut kids: Vec<String> = Vec::new();
    match n.node_type().to_uppercase().as_str() {
        "THEN" | "RACE" => {
            kids.extend(n.left_node().map(String::from));
            kids.extend(n.right_node().map(String::from));
        }
        "JOIN" => {
            kids.extend(n.left_node().map(String::from));
            kids.extend(n.right_node().map(String::from));
            if let Some(cfg) = n.query() {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(cfg) {
                    if let Some(extra) = v.get("extra_nodes").and_then(|e| e.as_array()) {
                        for x in extra {
                            if let Some(s) = x.as_str() {
                                kids.push(s.to_string());
                            }
                        }
                    }
                }
            }
        }
        "IF" => {
            config_node(n.query(), "condition_node", &mut kids);
            kids.extend(n.left_node().map(String::from));
            kids.extend(n.right_node().map(String::from));
        }
        "LOOP" => {
            kids.extend(n.left_node().map(String::from));
            config_node(n.query(), "condition_node", &mut kids);
        }
        _ => {}
    }
    kids
}

/// Compute the inferred status for every node in `nodes`, walking top-down from
/// `root_node`. The returned map has one entry per node id present in `nodes`.
pub fn infer_statuses<N: NodeFacts>(
    root_node: Option<&str>,
    nodes: &HashMap<String, N>,
) -> HashMap<String, Inferred> {
    // A walk frame: (node id, nearest terminal ancestor id, highest-generation
    // ancestor as (generation, node id)).
    type Frame = (String, Option<String>, Option<(i64, String)>);

    let mut out: HashMap<String, Inferred> = HashMap::new();
    let mut visited: HashSet<String> = HashSet::new();

    // Top-down walk from the root, carrying the nearest terminal ancestor and
    // highest-generation ancestor seen so far.
    if let Some(root) = root_node {
        let mut stack: Vec<Frame> = vec![(root.to_string(), None, None)];
        while let Some((node_id, nta, max_gen_anc)) = stack.pop() {
            if !visited.insert(node_id.clone()) {
                continue;
            }
            let n = match nodes.get(&node_id) {
                Some(n) => n,
                None => continue, // dangling reference (should not happen)
            };

            let gen_n = gen_of(n.status_details());
            let terminal = is_terminal(n.status());
            let superseded = match (gen_n, &max_gen_anc) {
                (Some(g), Some((ag, _))) => *ag > g,
                _ => false,
            };

            let (inferred, from_anc): (String, Option<String>) = if terminal {
                if superseded {
                    // Terminal in an older generation: a newer iteration exists. If a
                    // terminal ancestor decided against this branch it is `skipped`;
                    // otherwise it will re-run, so it reads back as `pending`.
                    match &nta {
                        Some(a) => ("skipped".to_string(), Some(a.clone())),
                        None => (
                            "pending".to_string(),
                            max_gen_anc.as_ref().map(|(_, id)| id.clone()),
                        ),
                    }
                } else {
                    // Physically ran in the current generation: keep its stored status.
                    (n.status().unwrap_or("pending").to_string(), None)
                }
            } else {
                // Non-terminal: a terminal ancestor means this branch was abandoned
                // (untaken IF arm / right of a failed THEN / RACE loser) -> `skipped`.
                match &nta {
                    Some(a) => ("skipped".to_string(), Some(a.clone())),
                    None => match n.status() {
                        Some("running") => ("running".to_string(), None),
                        _ => ("pending".to_string(), None),
                    },
                }
            };

            out.insert(
                node_id.clone(),
                Inferred {
                    status: inferred,
                    from_ancestor_id: from_anc,
                },
            );

            // A terminal node decides its descendants are `skipped` only when it ran in
            // the CURRENT generation. A *superseded* terminal node belongs to an older loop
            // generation and is about to re-run together with its whole subtree, so it must
            // not mask its descendants as skipped — they keep the existing decision (usually
            // none, so they read back as `pending` like the superseded node itself).
            let child_nta = if terminal && !superseded {
                Some(node_id.clone())
            } else {
                nta.clone()
            };
            let child_max_gen_anc = match (gen_n, max_gen_anc.clone()) {
                (Some(g), Some((ag, aid))) => {
                    if g >= ag {
                        Some((g, node_id.clone()))
                    } else {
                        Some((ag, aid))
                    }
                }
                (Some(g), None) => Some((g, node_id.clone())),
                (None, prev) => prev,
            };

            for child in children_of(n) {
                stack.push((child, child_nta.clone(), child_max_gen_anc.clone()));
            }
        }
    }

    // Defensive: surface any node not reachable from the root (orphaned or
    // referenced only through configs we do not traverse) with its stored status
    // and no derived inference, so the result map stays complete.
    for (id, n) in nodes {
        if visited.contains(id) {
            continue;
        }
        out.insert(
            id.clone(),
            Inferred {
                status: n.status().unwrap_or("pending").to_string(),
                from_ancestor_id: None,
            },
        );
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal in-memory node used to drive pure inference tests.
    struct TestNode {
        node_type: &'static str,
        query: Option<String>,
        left: Option<&'static str>,
        right: Option<&'static str>,
        status: Option<&'static str>,
        status_details: Option<String>,
    }

    impl TestNode {
        fn new(node_type: &'static str) -> Self {
            TestNode {
                node_type,
                query: None,
                left: None,
                right: None,
                status: None,
                status_details: None,
            }
        }
        fn status(mut self, s: &'static str) -> Self {
            self.status = Some(s);
            self
        }
        fn left(mut self, n: &'static str) -> Self {
            self.left = Some(n);
            self
        }
        fn right(mut self, n: &'static str) -> Self {
            self.right = Some(n);
            self
        }
        fn query(mut self, q: &str) -> Self {
            self.query = Some(q.to_string());
            self
        }
        /// Stamp the node with an `execution_id` whose second "::"-token is `gen`.
        fn gen(mut self, exec_id: &str) -> Self {
            self.status_details = Some(format!(r#"{{"execution_id":"{exec_id}"}}"#));
            self
        }
    }

    impl NodeFacts for TestNode {
        fn node_type(&self) -> &str {
            self.node_type
        }
        fn query(&self) -> Option<&str> {
            self.query.as_deref()
        }
        fn left_node(&self) -> Option<&str> {
            self.left
        }
        fn right_node(&self) -> Option<&str> {
            self.right
        }
        fn status(&self) -> Option<&str> {
            self.status
        }
        fn status_details(&self) -> Option<&str> {
            self.status_details.as_deref()
        }
    }

    fn graph(nodes: Vec<(&'static str, TestNode)>) -> HashMap<String, TestNode> {
        nodes
            .into_iter()
            .map(|(id, n)| (id.to_string(), n))
            .collect()
    }

    fn status_of<'a>(out: &'a HashMap<String, Inferred>, id: &str) -> &'a str {
        out.get(id)
            .map(|i| i.status.as_str())
            .unwrap_or("<missing>")
    }

    #[test]
    fn untaken_if_arm_is_skipped() {
        // if(true): then-arm runs, else-arm is never taken -> skipped, decided by IF.
        let g = graph(vec![
            (
                "if",
                TestNode::new("IF")
                    .query(r#"{"condition_node":"cond"}"#)
                    .left("then")
                    .right("else")
                    .status("completed")
                    .gen("i::1"),
            ),
            ("cond", TestNode::new("SQL").status("completed").gen("i::1")),
            ("then", TestNode::new("SQL").status("completed").gen("i::1")),
            ("else", TestNode::new("SQL").status("pending")),
        ]);

        let out = infer_statuses(Some("if"), &g);

        assert_eq!(status_of(&out, "then"), "completed");
        assert_eq!(status_of(&out, "else"), "skipped");
        assert_eq!(
            out.get("else").unwrap().from_ancestor_id.as_deref(),
            Some("if")
        );
    }

    #[test]
    fn right_of_failed_then_is_skipped() {
        // left of a THEN fails -> the THEN fails and the right side never runs -> skipped.
        let g = graph(vec![
            (
                "then",
                TestNode::new("THEN")
                    .left("a")
                    .right("b")
                    .status("failed")
                    .gen("i::1"),
            ),
            ("a", TestNode::new("SQL").status("failed").gen("i::1")),
            ("b", TestNode::new("SQL").status("pending")),
        ]);

        let out = infer_statuses(Some("then"), &g);

        assert_eq!(status_of(&out, "a"), "failed");
        assert_eq!(status_of(&out, "b"), "skipped");
        assert_eq!(
            out.get("b").unwrap().from_ancestor_id.as_deref(),
            Some("then")
        );
    }

    #[test]
    fn race_loser_is_skipped() {
        // RACE resolves: the winner completes, the still-running loser -> skipped.
        let g = graph(vec![
            (
                "race",
                TestNode::new("RACE")
                    .left("win")
                    .right("lose")
                    .status("completed")
                    .gen("i::1"),
            ),
            ("win", TestNode::new("SQL").status("completed").gen("i::1")),
            ("lose", TestNode::new("SLEEP").status("running").gen("i::1")),
        ]);

        let out = infer_statuses(Some("race"), &g);

        assert_eq!(status_of(&out, "win"), "completed");
        assert_eq!(status_of(&out, "lose"), "skipped");
        assert_eq!(
            out.get("lose").unwrap().from_ancestor_id.as_deref(),
            Some("race")
        );
    }

    #[test]
    fn clean_sequence_inferred_matches_physical() {
        // A fully-completed sequence: nothing is skipped, inferred == physical.
        let g = graph(vec![
            (
                "then",
                TestNode::new("THEN")
                    .left("a")
                    .right("b")
                    .status("completed")
                    .gen("i::1"),
            ),
            ("a", TestNode::new("SQL").status("completed").gen("i::1")),
            ("b", TestNode::new("SQL").status("completed").gen("i::1")),
        ]);

        let out = infer_statuses(Some("then"), &g);

        for id in ["then", "a", "b"] {
            assert_eq!(status_of(&out, id), "completed");
            assert!(out.get(id).unwrap().from_ancestor_id.is_none());
        }
    }

    #[test]
    fn superseded_loop_body_subtree_is_all_pending() {
        // Regression test: a loop has advanced to generation 2 (LOOP stamped i::2)
        // while the entire previous-generation body subtree is still stamped i::1.
        // Every superseded body node is about to re-run, so ALL of them must read
        // `pending` — not just the top of the subtree. Before the fix the inner
        // nodes were masked as `skipped` because their superseded THEN parent was
        // wrongly used as a skip-deciding ancestor.
        let g = graph(vec![
            (
                "loop",
                TestNode::new("LOOP")
                    .left("outer")
                    .status("running")
                    .gen("i::2"),
            ),
            (
                "outer",
                TestNode::new("THEN")
                    .left("inner")
                    .right("sleep2")
                    .status("completed")
                    .gen("i::1"),
            ),
            (
                "inner",
                TestNode::new("THEN")
                    .left("sleep5")
                    .right("insert")
                    .status("completed")
                    .gen("i::1"),
            ),
            (
                "sleep5",
                TestNode::new("SLEEP").status("completed").gen("i::1"),
            ),
            (
                "insert",
                TestNode::new("SQL").status("completed").gen("i::1"),
            ),
            (
                "sleep2",
                TestNode::new("SLEEP").status("completed").gen("i::1"),
            ),
        ]);

        let out = infer_statuses(Some("loop"), &g);

        for id in ["outer", "inner", "sleep5", "insert", "sleep2"] {
            assert_eq!(
                status_of(&out, id),
                "pending",
                "superseded body node {id} should read pending"
            );
        }
    }

    #[test]
    fn current_generation_decider_still_skips_superseded_descendant() {
        // Guard against over-correcting the fix: a terminal decider in the CURRENT
        // generation (IF stamped i::2 that took the then-arm) must still mark its
        // untaken else-arm `skipped`, even though that arm physically ran in an
        // earlier generation (i::1) and is therefore superseded.
        let g = graph(vec![
            (
                "loop",
                TestNode::new("LOOP")
                    .left("if")
                    .status("running")
                    .gen("i::2"),
            ),
            (
                "if",
                TestNode::new("IF")
                    .query(r#"{"condition_node":"cond"}"#)
                    .left("then")
                    .right("else")
                    .status("completed")
                    .gen("i::2"),
            ),
            ("cond", TestNode::new("SQL").status("completed").gen("i::2")),
            ("then", TestNode::new("SQL").status("completed").gen("i::2")),
            // else ran in the previous iteration, now untaken in the current one.
            ("else", TestNode::new("SQL").status("completed").gen("i::1")),
        ]);

        let out = infer_statuses(Some("loop"), &g);

        assert_eq!(status_of(&out, "then"), "completed");
        assert_eq!(status_of(&out, "else"), "skipped");
        assert_eq!(
            out.get("else").unwrap().from_ancestor_id.as_deref(),
            Some("if")
        );
    }
}
