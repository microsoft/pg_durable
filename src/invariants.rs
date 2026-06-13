// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Structural-invariant oracle for durable function instances.
//!
//! `df.assert_structural_invariants(instance_id)` post-run validates the
//! persisted DSL execution snapshot (the rows in `df.nodes` for one instance)
//! against the operational-semantics contract documented in
//! `docs/dsl-semantics.md`.
//!
//! It is a **sound snapshot oracle**: every violation it reports is a genuine
//! contract breach. It intentionally does *not* attempt invariants that require
//! execution or iteration **counts** (e.g. issue #227 "single execution outside
//! a loop", issue #230 "loop body iteration count"), because `df.nodes` stores
//! the *current state* of each node (updated in place by the
//! `update_node_status` activity), not an append-only trace. On
//! `continue_as_new` a loop body's node rows are reset and overwritten, so the
//! snapshot cannot reveal how many times a node executed. Those count-based
//! invariants need an event log and are tracked as follow-up work.
//!
//! The checker is split into a pure [`evaluate_invariants`] over an in-memory
//! node map (unit-testable, no SPI) and a thin `#[pg_extern]` wrapper
//! ([`assert_structural_invariants`]) that loads the snapshot via SPI.
//!
//! ## Persisted child encoding
//!
//! A node's children come from two places, mirroring how the executor reads
//! them (`src/orchestrations/execute_function_graph.rs`):
//! * the structural columns `left_node` / `right_node`, and
//! * string id references embedded in the `query` JSON — `condition_node`
//!   (`df.if`, `df.loop` while-condition) and `extra_nodes` (`df.join3`).
//!
//! Note `df.if_rows` produces an IF with **no** `condition_node` (it tests a
//! prior named result in memory), so `condition_node` is always optional.

use pgrx::prelude::*;
use std::collections::{HashMap, HashSet};

// Invariant names (stable identifiers returned in the `invariant` column).
const INV_REACHABLE: &str = "every_reachable_node_completed";
const INV_JOIN_BRANCHES: &str = "join_all_branches_completed";
const INV_UNTAKEN_IF: &str = "untaken_if_branch_pending";
const INV_RACE_BRANCH: &str = "race_at_least_one_branch_completed";
const INV_JOIN_NAMES: &str = "join_branch_result_name_disjoint";
const INV_QUERY_JSON: &str = "query_json_well_formed";

const STATUS_COMPLETED: &str = "completed";
const STATUS_PENDING: &str = "pending";

fn is_completed(status: &str) -> bool {
    status.eq_ignore_ascii_case(STATUS_COMPLETED)
}

fn is_pending(status: &str) -> bool {
    status.eq_ignore_ascii_case(STATUS_PENDING)
}

/// A terminal (quiesced) instance status — the oracle's snapshot precondition.
/// On a non-terminal instance the snapshot is mid-flight and a completed JOIN
/// may legitimately have branches still running, so the oracle declines to run.
fn is_terminal_instance(status: &str) -> bool {
    status.eq_ignore_ascii_case(STATUS_COMPLETED)
        || status.eq_ignore_ascii_case("failed")
        || status.eq_ignore_ascii_case("cancelled")
}

/// Minimal projection of a `df.nodes` row used by the oracle.
#[derive(Debug, Clone)]
struct OracleNode {
    id: String,
    node_type: String,
    query: Option<String>,
    result_name: Option<String>,
    left_node: Option<String>,
    right_node: Option<String>,
    status: String,
}

impl OracleNode {
    fn is_type(&self, ty: &str) -> bool {
        self.node_type.eq_ignore_ascii_case(ty)
    }

    /// Parse the `query` JSON once (None if absent or not an object).
    fn config(&self) -> Option<serde_json::Value> {
        let q = self.query.as_ref()?;
        serde_json::from_str::<serde_json::Value>(q).ok()
    }

    /// `condition_node` id embedded in `query` (IF via `df.if`, while-LOOP).
    /// Absent for `df.if_rows` and for plain infinite loops.
    fn condition_node_id(&self) -> Option<String> {
        self.config()?
            .get("condition_node")
            .and_then(|v| v.as_str())
            .map(str::to_string)
    }

    /// `extra_nodes` ids embedded in `query` (e.g. the 3rd branch of `df.join3`).
    fn extra_node_ids(&self) -> Vec<String> {
        let Some(cfg) = self.config() else {
            return Vec::new();
        };
        cfg.get("extra_nodes")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|e| e.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// All child node ids: structural (`left`/`right`) plus query-embedded
    /// (`condition_node`, `extra_nodes`).
    fn child_ids(&self) -> Vec<String> {
        let mut ids = Vec::new();
        if let Some(l) = &self.left_node {
            ids.push(l.clone());
        }
        if let Some(r) = &self.right_node {
            ids.push(r.clone());
        }
        if let Some(c) = self.condition_node_id() {
            ids.push(c);
        }
        ids.extend(self.extra_node_ids());
        ids
    }

    /// Branch roots only: `left`/`right` plus `extra_nodes` (used by JOIN/RACE).
    /// Excludes `condition_node`, which is not a parallel branch.
    fn branch_ids(&self) -> Vec<String> {
        let mut ids = Vec::new();
        if let Some(l) = &self.left_node {
            ids.push(l.clone());
        }
        if let Some(r) = &self.right_node {
            ids.push(r.clone());
        }
        ids.extend(self.extra_node_ids());
        ids
    }

    /// Node types whose `query` column holds JSON *configuration* (not raw SQL):
    /// IF/LOOP embed `condition_node`, JOIN embeds `extra_nodes`. For these a
    /// present-but-unparseable `query` silently drops children, so it must be
    /// reported rather than swallowed by [`config`](Self::config)'s `.ok()`.
    fn uses_json_query(&self) -> bool {
        self.is_type("IF") || self.is_type("LOOP") || self.is_type("JOIN")
    }

    /// True when `query` is present and non-blank but is not a JSON object.
    fn has_malformed_json_query(&self) -> bool {
        match self.query.as_deref() {
            Some(q) if !q.trim().is_empty() => {
                !matches!(serde_json::from_str::<serde_json::Value>(q), Ok(v) if v.is_object())
            }
            _ => false,
        }
    }
}

/// A single result row of the oracle.
#[derive(Debug, Clone, PartialEq, Eq)]
struct CheckRow {
    invariant: String,
    passed: bool,
    node_id: Option<String>,
    detail: Option<String>,
}

/// Push either a single `passed` row (no violations) or one row per violation.
/// Violations are sorted for deterministic output.
fn finalize(invariant: &str, mut violations: Vec<(String, String)>, rows: &mut Vec<CheckRow>) {
    if violations.is_empty() {
        rows.push(CheckRow {
            invariant: invariant.to_string(),
            passed: true,
            node_id: None,
            detail: None,
        });
        return;
    }
    violations.sort();
    for (node_id, detail) in violations {
        rows.push(CheckRow {
            invariant: invariant.to_string(),
            passed: false,
            node_id: Some(node_id),
            detail: Some(detail),
        });
    }
}

/// Record an invariant that was not evaluated (reported as passed with a reason).
fn skip(invariant: &str, reason: String, rows: &mut Vec<CheckRow>) {
    rows.push(CheckRow {
        invariant: invariant.to_string(),
        passed: true,
        node_id: None,
        detail: Some(format!("skipped: {reason}")),
    });
}

/// Collect a node id and its full subtree (cycle-safe via the visited set).
fn collect_subtree(root: &str, nodes: &HashMap<String, OracleNode>, out: &mut HashSet<String>) {
    let mut stack = vec![root.to_string()];
    while let Some(id) = stack.pop() {
        if !out.insert(id.clone()) {
            continue;
        }
        if let Some(node) = nodes.get(&id) {
            for child in node.child_ids() {
                stack.push(child);
            }
        }
    }
}

/// Sorted node ids — gives deterministic iteration over the snapshot.
fn sorted_ids(nodes: &HashMap<String, OracleNode>) -> Vec<String> {
    let mut ids: Vec<String> = nodes.keys().cloned().collect();
    ids.sort();
    ids
}

/// Ids of every node that lives *inside* a LOOP body (the union of each LOOP's
/// `left_node` subtree).
///
/// Inside a loop body the executor re-runs nodes via duroxide `continue_as_new`,
/// overwriting per-node status lazily *without* a blanket reset (see
/// `execute_loop_node` in `src/orchestrations/execute_function_graph.rs`). Two
/// consequences make the strict completeness rules unsound for these nodes:
/// * an IF that takes different branches across iterations ends with *both*
///   branches recorded `completed` (stale), and
/// * a `break` unwinds an in-flight JOIN/RACE, leaving a sibling branch
///   non-completed even though the JOIN itself is recorded `completed`.
///
/// The reachability / JOIN / IF checks therefore relax (scope), not skip, for
/// nodes in this set. The loop's own `condition_node` is a child of the LOOP
/// node — not of the body — so it is intentionally excluded and stays strict.
fn nodes_under_loop(nodes: &HashMap<String, OracleNode>) -> HashSet<String> {
    let mut under = HashSet::new();
    for node in nodes.values() {
        if !node.is_type("LOOP") {
            continue;
        }
        if let Some(body) = &node.left_node {
            collect_subtree(body, nodes, &mut under);
        }
    }
    under
}

/// Invariant 1: in a *completed* instance, every node reachable along the taken
/// execution path is `completed`.
///
/// The reached set is computed top-down honouring each combinator's recorded
/// outcome, so legitimately-pending nodes (the untaken IF branch, an abandoned
/// RACE loser, a loop's while-condition on a break-exit) are never required to
/// be completed:
/// * THEN  → both children run.
/// * JOIN  → all branches run.
/// * IF    → the `condition_node` (if present) plus the taken (non-pending) branch.
/// * RACE  → only the completed (winner) branch(es).
/// * LOOP  → the body; the while-condition only if it itself completed.
/// * leaves (SQL/SLEEP/WAIT_SCHEDULE/BREAK/HTTP/SIGNAL) → no children.
///
/// Loop-scoping: for a JOIN *inside* a loop body a `break` can abandon a sibling
/// branch, so only its completed branches are treated as on-path (see
/// [`nodes_under_loop`]).
///
/// Only evaluated for completed instances: a failed/cancelled instance
/// legitimately leaves nodes off the path pending.
fn check_reachable_completed(
    nodes: &HashMap<String, OracleNode>,
    root_id: &str,
    instance_status: &str,
    under_loop: &HashSet<String>,
    rows: &mut Vec<CheckRow>,
) {
    if !is_completed(instance_status) {
        skip(
            INV_REACHABLE,
            format!(
                "instance status is '{instance_status}'; reachability completeness is only checked for completed instances"
            ),
            rows,
        );
        return;
    }

    let mut violations: Vec<(String, String)> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut stack = vec![root_id.to_string()];

    while let Some(id) = stack.pop() {
        if !seen.insert(id.clone()) {
            continue;
        }
        let Some(node) = nodes.get(&id) else {
            violations.push((
                id.clone(),
                "reachable node id not found in df.nodes".to_string(),
            ));
            continue;
        };
        if !is_completed(&node.status) {
            violations.push((
                id.clone(),
                format!(
                    "reachable {} node is '{}', expected completed",
                    node.node_type, node.status
                ),
            ));
            // Do not descend through a node that is not completed: its children's
            // expected state is ambiguous, and descending would cascade spurious
            // violations.
            continue;
        }
        push_reached_children(node, nodes, under_loop, &mut stack);
    }

    finalize(INV_REACHABLE, violations, rows);
}

fn push_reached_children(
    node: &OracleNode,
    nodes: &HashMap<String, OracleNode>,
    under_loop: &HashSet<String>,
    stack: &mut Vec<String>,
) {
    // Push a child id when `predicate` holds. When the id is absent from the
    // snapshot, push it anyway iff `report_absent` so the walk surfaces the
    // dangling reference ("not found in df.nodes"); for legitimately-absent
    // references (an infinite loop's missing while-condition) keep it silent.
    let push_if = |stack: &mut Vec<String>,
                   id: &str,
                   report_absent: bool,
                   predicate: &dyn Fn(&OracleNode) -> bool| {
        match nodes.get(id) {
            Some(child) => {
                if predicate(child) {
                    stack.push(id.to_string());
                }
            }
            None => {
                if report_absent {
                    stack.push(id.to_string());
                }
            }
        }
    };

    match node.node_type.to_ascii_uppercase().as_str() {
        "THEN" => {
            if let Some(l) = &node.left_node {
                stack.push(l.clone());
            }
            if let Some(r) = &node.right_node {
                stack.push(r.clone());
            }
        }
        "JOIN" => {
            if under_loop.contains(&node.id) {
                // Inside a loop body a `break` can abandon a sibling branch,
                // leaving it non-completed under a `completed` JOIN. Descend only
                // into completed branches; the JOIN-branches check applies the
                // matching relaxed completeness.
                for branch in node.branch_ids() {
                    push_if(stack, &branch, false, &|c| is_completed(&c.status));
                }
            } else {
                // Outside any loop all branches are on the path; push them all so
                // a missing branch id is surfaced as a dangling reference.
                for branch in node.branch_ids() {
                    stack.push(branch);
                }
            }
        }
        "IF" => {
            // The condition node (df.if) always runs; a dangling reference is
            // worth surfacing.
            if let Some(c) = node.condition_node_id() {
                stack.push(c);
            }
            // Descend into the taken (non-pending) branch(es) only; a taken but
            // absent branch is a dangling reference worth surfacing.
            if let Some(l) = &node.left_node {
                push_if(stack, l, true, &|c| !is_pending(&c.status));
            }
            if let Some(r) = &node.right_node {
                push_if(stack, r, true, &|c| !is_pending(&c.status));
            }
        }
        "RACE" => {
            // Descend into completed (winner) branch(es); abandoned losers may be
            // legitimately pending/running. A winner whose id is absent is a
            // dangling reference worth surfacing.
            for branch in node.branch_ids() {
                push_if(stack, &branch, true, &|c| is_completed(&c.status));
            }
        }
        "LOOP" => {
            // The body's last iteration completed on a completed loop.
            if let Some(body) = &node.left_node {
                stack.push(body.clone());
            }
            // The while-condition ran (and is recorded completed) only on a
            // condition-false exit, not on a break-exit. Require it only if it
            // actually completed; a legitimately-absent condition (infinite loop)
            // stays silent.
            if let Some(c) = node.condition_node_id() {
                push_if(stack, &c, false, &|c| is_completed(&c.status));
            }
        }
        // Leaves have no children.
        _ => {}
    }
}

/// Invariant 2: a *completed* JOIN has every branch completed.
///
/// Loop-scoping: for a JOIN inside a loop body a `break` can abandon a sibling
/// branch (left non-completed under a `completed` JOIN). There the rule relaxes
/// to "no branch *failed*, none missing" — a running/pending abandoned sibling
/// is accepted (see [`nodes_under_loop`]). A `completed` JOIN with zero branches
/// is always a violation: it cannot meaningfully complete.
fn check_join_branches_completed(
    nodes: &HashMap<String, OracleNode>,
    under_loop: &HashSet<String>,
    rows: &mut Vec<CheckRow>,
) {
    let mut violations: Vec<(String, String)> = Vec::new();

    for id in sorted_ids(nodes) {
        let node = &nodes[&id];
        if !node.is_type("JOIN") || !is_completed(&node.status) {
            continue;
        }
        let branches = node.branch_ids();
        if branches.is_empty() {
            violations.push((
                node.id.clone(),
                format!("JOIN {} completed but has no branches", node.id),
            ));
            continue;
        }
        let relaxed = under_loop.contains(&node.id);
        for branch in branches {
            match nodes.get(&branch) {
                Some(child) if is_completed(&child.status) => {}
                // Under a loop, a break-abandoned sibling is non-terminal
                // (running/pending) and legitimate; only a genuine `failed`
                // branch is still a violation there.
                Some(child) if relaxed && !child.status.eq_ignore_ascii_case("failed") => {}
                Some(child) => violations.push((
                    branch.clone(),
                    format!(
                        "JOIN {} completed but branch {} is '{}'",
                        node.id, branch, child.status
                    ),
                )),
                None => violations.push((
                    branch.clone(),
                    format!("JOIN {} branch {} missing from df.nodes", node.id, branch),
                )),
            }
        }
    }

    finalize(INV_JOIN_BRANCHES, violations, rows);
}

/// Invariant 3: a *completed* IF takes exactly one branch; the untaken branch's
/// whole subtree stays pending; the `condition_node` (when present) completed.
///
/// Gated on the IF being completed (not merely terminal): a failed IF may have
/// failed in its condition before any branch was selected, which legitimately
/// leaves both branches pending.
///
/// Loop-scoping: for an IF inside a loop body the executor re-runs it across
/// iterations and overwrites branch status lazily, so the final snapshot can
/// show *both* branches `completed` (stale) and an untaken subtree non-pending.
/// The "exactly one branch taken" and "untaken subtree pending" rules are
/// unsound there and are skipped; the condition-node check still applies (see
/// [`nodes_under_loop`]).
fn check_untaken_if_branch_pending(
    nodes: &HashMap<String, OracleNode>,
    under_loop: &HashSet<String>,
    rows: &mut Vec<CheckRow>,
) {
    let mut violations: Vec<(String, String)> = Vec::new();

    for id in sorted_ids(nodes) {
        let node = &nodes[&id];
        if !node.is_type("IF") || !is_completed(&node.status) {
            continue;
        }

        if !under_loop.contains(&node.id) {
            let branches: Vec<String> = [&node.left_node, &node.right_node]
                .into_iter()
                .flatten()
                .cloned()
                .collect();

            let taken: Vec<String> = branches
                .iter()
                .filter(|b| nodes.get(*b).is_some_and(|n| !is_pending(&n.status)))
                .cloned()
                .collect();

            if taken.len() > 1 {
                violations.push((
                    node.id.clone(),
                    format!(
                        "IF {} took more than one branch (both non-pending)",
                        node.id
                    ),
                ));
            } else if taken.is_empty() {
                violations.push((
                    node.id.clone(),
                    format!(
                        "IF {} completed but neither branch was taken (both pending)",
                        node.id
                    ),
                ));
            }

            // Every untaken branch subtree must be entirely pending.
            for branch in &branches {
                if taken.contains(branch) {
                    continue;
                }
                let mut subtree = HashSet::new();
                collect_subtree(branch, nodes, &mut subtree);
                for sid in &subtree {
                    if let Some(sn) = nodes.get(sid) {
                        if !is_pending(&sn.status) {
                            violations.push((
                                sid.clone(),
                                format!(
                                    "IF {} untaken branch node {} is '{}', expected pending",
                                    node.id, sid, sn.status
                                ),
                            ));
                        }
                    }
                }
            }
        }

        // The condition node (df.if) runs whenever the IF is reached — in or out
        // of a loop. A present-but-non-completed or a missing condition node is a
        // violation.
        if let Some(cond) = node.condition_node_id() {
            match nodes.get(&cond) {
                Some(cn) if is_completed(&cn.status) => {}
                Some(cn) => violations.push((
                    cond.clone(),
                    format!(
                        "IF {} condition node {} is '{}', expected completed",
                        node.id, cond, cn.status
                    ),
                )),
                None => violations.push((
                    cond.clone(),
                    format!(
                        "IF {} condition node {} missing from df.nodes",
                        node.id, cond
                    ),
                )),
            }
        }
    }

    finalize(INV_UNTAKEN_IF, violations, rows);
}

/// Invariant 4: a *completed* RACE has at least one completed branch.
///
/// This is the sound replacement for the issue's `race_loser_terminal`
/// ("exactly one branch completes"), which is **not** sound: a race may resolve
/// against a branch that was already completed, and near-simultaneous
/// completions ("photo finish") can leave more than one branch completed
/// (see `docs/dsl-semantics.md` §C5).
fn check_race_branch_completed(nodes: &HashMap<String, OracleNode>, rows: &mut Vec<CheckRow>) {
    let mut violations: Vec<(String, String)> = Vec::new();

    for id in sorted_ids(nodes) {
        let node = &nodes[&id];
        if !node.is_type("RACE") || !is_completed(&node.status) {
            continue;
        }
        let any_completed = node
            .branch_ids()
            .iter()
            .any(|b| nodes.get(b).is_some_and(|n| is_completed(&n.status)));
        if !any_completed {
            violations.push((
                node.id.clone(),
                format!("RACE {} completed but no branch is completed", node.id),
            ));
        }
    }

    finalize(INV_RACE_BRANCH, violations, rows);
}

/// Invariant 5 (static): the parallel branches of a JOIN must bind disjoint
/// `result_name`s. Two branches binding the same name race to overwrite it in
/// the merged variable map, so the merged value is non-deterministic
/// (`docs/dsl-semantics.md` §C4). Checked structurally, independent of run state.
///
/// A JOIN that references the same branch id more than once (`left_node ==
/// right_node`, or a duplicate `extra_nodes` entry) is itself malformed; that is
/// reported as a `duplicate_branch_id` violation and the names analysis is
/// skipped for that JOIN (visiting the same subtree twice would otherwise report
/// a spurious self-collision).
fn check_join_result_name_disjoint(nodes: &HashMap<String, OracleNode>, rows: &mut Vec<CheckRow>) {
    let mut violations: Vec<(String, String)> = Vec::new();

    for id in sorted_ids(nodes) {
        let node = &nodes[&id];
        if !node.is_type("JOIN") {
            continue;
        }

        // Detect duplicate branch ids before the names analysis.
        let branches = node.branch_ids();
        let mut unique: Vec<String> = Vec::with_capacity(branches.len());
        let mut dup_reported: HashSet<String> = HashSet::new();
        for b in &branches {
            if unique.contains(b) {
                if dup_reported.insert(b.clone()) {
                    violations.push((
                        node.id.clone(),
                        format!(
                            "JOIN {} references the same branch id {} more than once",
                            node.id, b
                        ),
                    ));
                }
            } else {
                unique.push(b.clone());
            }
        }
        if !dup_reported.is_empty() {
            // Skip the names analysis for a malformed (duplicate-branch) JOIN.
            continue;
        }

        // name -> branch root that first bound it
        let mut seen: HashMap<String, String> = HashMap::new();
        for branch in unique {
            let mut subtree = HashSet::new();
            collect_subtree(&branch, nodes, &mut subtree);

            let mut names_here: Vec<String> = subtree
                .iter()
                .filter_map(|sid| nodes.get(sid).and_then(|n| n.result_name.clone()))
                .collect();
            names_here.sort();
            names_here.dedup();

            for name in names_here {
                if let Some(prev_branch) = seen.get(&name) {
                    violations.push((
                        node.id.clone(),
                        format!(
                            "JOIN {} binds result_name '{}' in multiple parallel branches ({} and {})",
                            node.id, name, prev_branch, branch
                        ),
                    ));
                } else {
                    seen.insert(name, branch.clone());
                }
            }
        }
    }

    finalize(INV_JOIN_NAMES, violations, rows);
}

/// Evaluate every structural invariant over an in-memory snapshot.
///
/// `instance_status` is the recorded `df.instances.status`, lowercased. Global
/// completeness is asserted only for completed instances; the local node-level
/// rules apply regardless of instance state. Rows are returned in invariant
/// order, violations sorted within each invariant.
fn evaluate_invariants(
    nodes: &HashMap<String, OracleNode>,
    root_id: &str,
    instance_status: &str,
) -> Vec<CheckRow> {
    let mut rows = Vec::new();
    let under_loop = nodes_under_loop(nodes);
    check_query_json_well_formed(nodes, &mut rows);
    check_reachable_completed(nodes, root_id, instance_status, &under_loop, &mut rows);
    check_join_branches_completed(nodes, &under_loop, &mut rows);
    check_untaken_if_branch_pending(nodes, &under_loop, &mut rows);
    check_race_branch_completed(nodes, &mut rows);
    check_join_result_name_disjoint(nodes, &mut rows);
    rows
}

/// Invariant 0 (static): a node whose `query` holds JSON configuration (IF/LOOP
/// `condition_node`, JOIN `extra_nodes`) must have a well-formed JSON *object*.
///
/// [`OracleNode::config`] swallows parse errors with `.ok()`, so a malformed or
/// wrong-shape `query` would otherwise make the node look childless and pass the
/// branch checks by omission — unsound. This surfaces the corruption directly.
fn check_query_json_well_formed(nodes: &HashMap<String, OracleNode>, rows: &mut Vec<CheckRow>) {
    let mut violations: Vec<(String, String)> = Vec::new();
    for id in sorted_ids(nodes) {
        let node = &nodes[&id];
        if node.uses_json_query() && node.has_malformed_json_query() {
            violations.push((
                node.id.clone(),
                format!(
                    "{} node {} has a present but non-object/unparseable query JSON",
                    node.node_type, node.id
                ),
            ));
        }
    }
    finalize(INV_QUERY_JSON, violations, rows);
}

/// Load every `df.nodes` row for one instance into an id-keyed map (RLS-scoped).
///
/// Delegates the positional SPI read to the canonical [`crate::db::NodeSnapshot`]
/// loader. Returns `None` when the instance has more than
/// [`crate::db::MAX_NODES_PER_INSTANCE`] nodes, so the caller can report
/// "instance too large" instead of evaluating a truncated snapshot (which could
/// manufacture a false "missing branch" violation).
fn load_oracle_nodes(instance_id: &str) -> Option<HashMap<String, OracleNode>> {
    let snapshots = crate::db::load_node_snapshots(instance_id, crate::db::MAX_NODES_PER_INSTANCE)?;
    let mut nodes = HashMap::with_capacity(snapshots.len());
    for s in snapshots {
        nodes.insert(
            s.id.clone(),
            OracleNode {
                id: s.id,
                node_type: s.node_type,
                query: s.query,
                result_name: s.result_name,
                left_node: s.left_node,
                right_node: s.right_node,
                status: s.status,
            },
        );
    }
    Some(nodes)
}

// The pg_extern table-iterator type is repeated inline below because the
// `name!`/`TableIterator` macro expansion must appear in the function signature;
// keep it in sync with [`InvariantRow`].
type InvariantRow = (
    name!(invariant, String),
    name!(passed, bool),
    name!(node_id, Option<String>),
    name!(detail, Option<String>),
);

/// Validate the structural invariants of a durable function instance against the
/// operational-semantics contract (`docs/dsl-semantics.md`).
///
/// Returns one row per invariant when it holds, or one row per offending node
/// when it is violated. This is a sound *snapshot* oracle — it cannot catch
/// invariants that require execution/iteration counts (see the module docs).
///
/// With `fail_on_violation => true` the function raises an error if any
/// invariant is violated, which makes it a one-line assertion for tests:
///
/// ```sql
/// SELECT * FROM df.assert_structural_invariants('abc12345', true);
/// ```
#[pg_extern(schema = "df")]
pub fn assert_structural_invariants(
    instance_id: &str,
    fail_on_violation: default!(bool, "false"),
) -> TableIterator<
    'static,
    // Inline form of [`InvariantRow`] — the `name!` macro must expand in the
    // signature. Keep the two in sync.
    (
        name!(invariant, String),
        name!(passed, bool),
        name!(node_id, Option<String>),
        name!(detail, Option<String>),
    ),
> {
    // Ownership/existence check goes through RLS, so non-owned instances are
    // invisible. Also fetch the root node and recorded status in one shot.
    // `Some(1)` + `into_iter().next()` reads exactly the first row (a `for`
    // loop that always returns would trip `clippy::never_loop`).
    let info: Option<(Option<String>, String)> = Spi::connect(|client| {
        let sql = "SELECT root_node, status FROM df.instances WHERE id = $1";
        client
            .select(sql, Some(1), &[instance_id.into()])
            .ok()
            .and_then(|table| {
                table.into_iter().next().map(|row| {
                    let root: Option<String> = row.get(1).ok().flatten();
                    let status: Option<String> = row.get(2).ok().flatten();
                    (root, status.unwrap_or_default())
                })
            })
    });

    let (root_id, status) = match info {
        Some((Some(root), status)) => (root, status),
        Some((None, _)) => {
            return finish(
                vec![CheckRow {
                    invariant: "instance_has_root_node".to_string(),
                    passed: false,
                    node_id: Some(instance_id.to_string()),
                    detail: Some("instance exists but has no root_node".to_string()),
                }],
                fail_on_violation,
            );
        }
        None => {
            return finish(
                vec![CheckRow {
                    invariant: "instance_found".to_string(),
                    passed: false,
                    node_id: Some(instance_id.to_string()),
                    detail: Some(
                        "instance not found or not visible to the current user".to_string(),
                    ),
                }],
                fail_on_violation,
            );
        }
    };

    // Snapshot soundness: a still-running instance has nodes legitimately in
    // flight, and concurrent writes make a read racy. Evaluate only terminal
    // instances; otherwise report a single (passed) skipped row.
    if !is_terminal_instance(&status) {
        return finish(
            vec![CheckRow {
                invariant: "instance_terminal".to_string(),
                passed: true,
                node_id: Some(instance_id.to_string()),
                detail: Some(format!(
                    "skipped: instance status '{status}' is not terminal (still running)"
                )),
            }],
            fail_on_violation,
        );
    }

    let nodes = match load_oracle_nodes(instance_id) {
        Some(nodes) => nodes,
        None => {
            return finish(
                vec![CheckRow {
                    invariant: "instance_size".to_string(),
                    passed: false,
                    node_id: Some(instance_id.to_string()),
                    detail: Some(format!(
                        "instance has more than {} nodes; too large to evaluate",
                        crate::db::MAX_NODES_PER_INSTANCE
                    )),
                }],
                fail_on_violation,
            );
        }
    };
    let rows = evaluate_invariants(&nodes, &root_id, &status.to_ascii_lowercase());
    finish(rows, fail_on_violation)
}

/// Convert check rows into the table iterator, optionally raising on violations.
fn finish(rows: Vec<CheckRow>, fail_on_violation: bool) -> TableIterator<'static, InvariantRow> {
    if fail_on_violation {
        let violations: Vec<&CheckRow> = rows.iter().filter(|r| !r.passed).collect();
        if !violations.is_empty() {
            let summary = violations
                .iter()
                .take(10)
                .map(|r| {
                    format!(
                        "[{}] node={} {}",
                        r.invariant,
                        r.node_id.as_deref().unwrap_or("-"),
                        r.detail.as_deref().unwrap_or("")
                    )
                })
                .collect::<Vec<_>>()
                .join("; ");
            pgrx::error!(
                "df.assert_structural_invariants: {} violation(s): {summary}",
                violations.len()
            );
        }
    }

    let tuples = rows
        .into_iter()
        .map(|r| (r.invariant, r.passed, r.node_id, r.detail))
        .collect::<Vec<_>>();
    TableIterator::new(tuples)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(
        id: &str,
        ty: &str,
        status: &str,
        left: Option<&str>,
        right: Option<&str>,
        query: Option<&str>,
        result_name: Option<&str>,
    ) -> OracleNode {
        OracleNode {
            id: id.to_string(),
            node_type: ty.to_string(),
            query: query.map(str::to_string),
            result_name: result_name.map(str::to_string),
            left_node: left.map(str::to_string),
            right_node: right.map(str::to_string),
            status: status.to_string(),
        }
    }

    fn map(nodes: Vec<OracleNode>) -> HashMap<String, OracleNode> {
        nodes.into_iter().map(|n| (n.id.clone(), n)).collect()
    }

    /// Find the result row(s) for one invariant.
    fn rows_for<'a>(rows: &'a [CheckRow], invariant: &str) -> Vec<&'a CheckRow> {
        rows.iter().filter(|r| r.invariant == invariant).collect()
    }

    fn passed(rows: &[CheckRow], invariant: &str) -> bool {
        let r = rows_for(rows, invariant);
        !r.is_empty() && r.iter().all(|x| x.passed)
    }

    fn cond_if(cond: &str) -> Option<String> {
        Some(format!("{{\"condition_node\": \"{cond}\"}}"))
    }

    // ----- child encoding -------------------------------------------------

    #[test]
    fn child_ids_include_condition_and_extra_nodes() {
        let if_node = node(
            "if1",
            "IF",
            "completed",
            Some("then1"),
            Some("else1"),
            Some("{\"condition_node\": \"cond1\"}"),
            None,
        );
        let mut ids = if_node.child_ids();
        ids.sort();
        assert_eq!(ids, vec!["cond1", "else1", "then1"]);

        let join3 = node(
            "j",
            "JOIN",
            "completed",
            Some("a"),
            Some("b"),
            Some("{\"extra_nodes\": [\"c\"]}"),
            None,
        );
        let mut bids = join3.branch_ids();
        bids.sort();
        assert_eq!(bids, vec!["a", "b", "c"]);
    }

    #[test]
    fn if_rows_has_no_condition_node() {
        let if_rows = node(
            "if1",
            "IF",
            "completed",
            Some("then1"),
            Some("else1"),
            Some("{\"condition_type\": \"result_has_rows\", \"result_name\": \"data\"}"),
            None,
        );
        assert_eq!(if_rows.condition_node_id(), None);
        let mut ids = if_rows.child_ids();
        ids.sort();
        assert_eq!(ids, vec!["else1", "then1"]);
    }

    // ----- every_reachable_node_completed --------------------------------

    #[test]
    fn reachable_skipped_for_non_completed_instance() {
        let nodes = map(vec![node(
            "r",
            "SQL",
            "running",
            None,
            None,
            Some("SELECT 1"),
            None,
        )]);
        let rows = evaluate_invariants(&nodes, "r", "running");
        let r = rows_for(&rows, INV_REACHABLE);
        assert_eq!(r.len(), 1);
        assert!(r[0].passed);
        assert!(r[0].detail.as_ref().unwrap().contains("skipped"));
    }

    #[test]
    fn reachable_passes_for_completed_sequence() {
        // THEN(completed) -> left SQL(completed), right SQL(completed)
        let nodes = map(vec![
            node("t", "THEN", "completed", Some("a"), Some("b"), None, None),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "completed", None, None, Some("SELECT 2"), None),
        ]);
        let rows = evaluate_invariants(&nodes, "t", "completed");
        assert!(passed(&rows, INV_REACHABLE));
    }

    #[test]
    fn reachable_flags_incomplete_node_on_path() {
        let nodes = map(vec![
            node("t", "THEN", "completed", Some("a"), Some("b"), None, None),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "pending", None, None, Some("SELECT 2"), None),
        ]);
        let rows = evaluate_invariants(&nodes, "t", "completed");
        let r = rows_for(&rows, INV_REACHABLE);
        assert!(r
            .iter()
            .any(|x| !x.passed && x.node_id.as_deref() == Some("b")));
    }

    #[test]
    fn reachable_ignores_untaken_if_branch() {
        // IF(completed) cond=c then=a(completed) else=b(pending subtree)
        let nodes = map(vec![
            node(
                "if",
                "IF",
                "completed",
                Some("a"),
                Some("b"),
                cond_if("c").as_deref(),
                None,
            ),
            node(
                "c",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT true"),
                None,
            ),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "pending", None, None, Some("SELECT 2"), None),
        ]);
        let rows = evaluate_invariants(&nodes, "if", "completed");
        assert!(
            passed(&rows, INV_REACHABLE),
            "untaken else branch must not be required completed"
        );
    }

    #[test]
    fn reachable_ignores_abandoned_race_loser() {
        // RACE(completed): left winner completed, right loser still running.
        let nodes = map(vec![
            node("rc", "RACE", "completed", Some("w"), Some("l"), None, None),
            node("w", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node(
                "l",
                "SLEEP",
                "running",
                None,
                None,
                Some("{\"sleep_seconds\":60}"),
                None,
            ),
        ]);
        let rows = evaluate_invariants(&nodes, "rc", "completed");
        assert!(passed(&rows, INV_REACHABLE));
    }

    #[test]
    fn reachable_loop_break_exit_does_not_require_condition() {
        // LOOP(completed) body completed; while-condition present but pending
        // (break-exit never evaluated it). Must still pass.
        let nodes = map(vec![
            node(
                "lp",
                "LOOP",
                "completed",
                Some("body"),
                None,
                Some("{\"condition_node\": \"cond\"}"),
                None,
            ),
            node(
                "body",
                "BREAK",
                "completed",
                None,
                None,
                Some("{\"break_value\": null}"),
                None,
            ),
            node(
                "cond",
                "SQL",
                "pending",
                None,
                None,
                Some("SELECT false"),
                None,
            ),
        ]);
        let rows = evaluate_invariants(&nodes, "lp", "completed");
        assert!(passed(&rows, INV_REACHABLE));
    }

    // ----- join_all_branches_completed -----------------------------------

    #[test]
    fn join_branches_pass_and_fail() {
        let ok = map(vec![
            node("j", "JOIN", "completed", Some("a"), Some("b"), None, None),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "completed", None, None, Some("SELECT 2"), None),
        ]);
        assert!(passed(
            &evaluate_invariants(&ok, "j", "completed"),
            INV_JOIN_BRANCHES
        ));

        let bad = map(vec![
            node("j", "JOIN", "completed", Some("a"), Some("b"), None, None),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "running", None, None, Some("SELECT 2"), None),
        ]);
        let rows = evaluate_invariants(&bad, "j", "completed");
        let r = rows_for(&rows, INV_JOIN_BRANCHES);
        assert!(r
            .iter()
            .any(|x| !x.passed && x.node_id.as_deref() == Some("b")));
    }

    // ----- untaken_if_branch_pending -------------------------------------

    #[test]
    fn untaken_if_pass() {
        let nodes = map(vec![
            node(
                "if",
                "IF",
                "completed",
                Some("a"),
                Some("b"),
                Some("{\"condition_node\": \"c\"}"),
                None,
            ),
            node(
                "c",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT true"),
                None,
            ),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "pending", None, None, Some("SELECT 2"), None),
        ]);
        assert!(passed(
            &evaluate_invariants(&nodes, "if", "completed"),
            INV_UNTAKEN_IF
        ));
    }

    #[test]
    fn untaken_if_both_branches_taken_flagged() {
        let nodes = map(vec![
            node(
                "if",
                "IF",
                "completed",
                Some("a"),
                Some("b"),
                Some("{\"condition_node\": \"c\"}"),
                None,
            ),
            node(
                "c",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT true"),
                None,
            ),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "completed", None, None, Some("SELECT 2"), None),
        ]);
        let rows = evaluate_invariants(&nodes, "if", "completed");
        assert!(!passed(&rows, INV_UNTAKEN_IF));
    }

    #[test]
    fn untaken_if_subtree_must_be_pending() {
        // else branch root pending, but a node under it completed -> violation.
        let nodes = map(vec![
            node(
                "if",
                "IF",
                "completed",
                Some("a"),
                Some("bthen"),
                Some("{\"condition_node\": \"c\"}"),
                None,
            ),
            node(
                "c",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT true"),
                None,
            ),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node(
                "bthen",
                "THEN",
                "pending",
                Some("b1"),
                Some("b2"),
                None,
                None,
            ),
            node("b1", "SQL", "completed", None, None, Some("SELECT 2"), None),
            node("b2", "SQL", "pending", None, None, Some("SELECT 3"), None),
        ]);
        let rows = evaluate_invariants(&nodes, "if", "completed");
        let r = rows_for(&rows, INV_UNTAKEN_IF);
        assert!(r
            .iter()
            .any(|x| !x.passed && x.node_id.as_deref() == Some("b1")));
    }

    // ----- race_at_least_one_branch_completed ----------------------------

    #[test]
    fn race_requires_a_completed_branch() {
        let ok = map(vec![
            node("rc", "RACE", "completed", Some("w"), Some("l"), None, None),
            node("w", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node(
                "l",
                "SLEEP",
                "running",
                None,
                None,
                Some("{\"sleep_seconds\":60}"),
                None,
            ),
        ]);
        assert!(passed(
            &evaluate_invariants(&ok, "rc", "completed"),
            INV_RACE_BRANCH
        ));

        let bad = map(vec![
            node("rc", "RACE", "completed", Some("w"), Some("l"), None, None),
            node("w", "SQL", "running", None, None, Some("SELECT 1"), None),
            node(
                "l",
                "SLEEP",
                "running",
                None,
                None,
                Some("{\"sleep_seconds\":60}"),
                None,
            ),
        ]);
        assert!(!passed(
            &evaluate_invariants(&bad, "rc", "completed"),
            INV_RACE_BRANCH
        ));
    }

    // ----- join_branch_result_name_disjoint ------------------------------

    #[test]
    fn join_name_collision_flagged() {
        let bad = map(vec![
            node("j", "JOIN", "completed", Some("a"), Some("b"), None, None),
            node(
                "a",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT 1"),
                Some("x"),
            ),
            node(
                "b",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT 2"),
                Some("x"),
            ),
        ]);
        assert!(!passed(
            &evaluate_invariants(&bad, "j", "completed"),
            INV_JOIN_NAMES
        ));

        let ok = map(vec![
            node("j", "JOIN", "completed", Some("a"), Some("b"), None, None),
            node(
                "a",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT 1"),
                Some("x"),
            ),
            node(
                "b",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT 2"),
                Some("y"),
            ),
        ]);
        assert!(passed(
            &evaluate_invariants(&ok, "j", "completed"),
            INV_JOIN_NAMES
        ));
    }

    #[test]
    fn all_invariants_present_in_output() {
        let nodes = map(vec![node(
            "r",
            "SQL",
            "completed",
            None,
            None,
            Some("SELECT 1"),
            None,
        )]);
        let rows = evaluate_invariants(&nodes, "r", "completed");
        for inv in [
            INV_REACHABLE,
            INV_JOIN_BRANCHES,
            INV_UNTAKEN_IF,
            INV_RACE_BRANCH,
            INV_JOIN_NAMES,
            INV_QUERY_JSON,
        ] {
            assert!(!rows_for(&rows, inv).is_empty(), "missing invariant {inv}");
        }
    }

    // ----- case-insensitive status (SF8) ---------------------------------

    #[test]
    fn node_status_is_case_insensitive() {
        // Mixed-case node statuses must be treated as completed.
        let nodes = map(vec![
            node("t", "THEN", "COMPLETED", Some("a"), Some("b"), None, None),
            node("a", "SQL", "Completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "completed", None, None, Some("SELECT 2"), None),
        ]);
        let rows = evaluate_invariants(&nodes, "t", "completed");
        assert!(passed(&rows, INV_REACHABLE));
    }

    // ----- missing IF condition node (MF1) -------------------------------

    #[test]
    fn missing_if_condition_node_flagged() {
        // IF completed, condition_node referenced but absent from df.nodes.
        let nodes = map(vec![
            node(
                "if",
                "IF",
                "completed",
                Some("a"),
                Some("b"),
                cond_if("cccc").as_deref(),
                None,
            ),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "pending", None, None, Some("SELECT 2"), None),
        ]);
        let rows = evaluate_invariants(&nodes, "if", "completed");
        let r = rows_for(&rows, INV_UNTAKEN_IF);
        assert!(
            r.iter()
                .any(|x| !x.passed && x.node_id.as_deref() == Some("cccc")),
            "missing IF condition node must be flagged"
        );
    }

    // ----- break abandons JOIN sibling under a loop (MF3) ----------------

    #[test]
    fn join_under_loop_tolerates_break_abandoned_sibling() {
        // LOOP body is a JOIN: one branch completed, the sibling running
        // (abandoned by a break). Under the loop this is legitimate.
        let nodes = map(vec![
            node(
                "lp",
                "LOOP",
                "completed",
                Some("j"),
                None,
                Some("{\"condition_node\": \"cond\"}"),
                None,
            ),
            node("j", "JOIN", "completed", Some("a"), Some("b"), None, None),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node(
                "b",
                "SLEEP",
                "running",
                None,
                None,
                Some("{\"sleep_seconds\":60}"),
                None,
            ),
            node(
                "cond",
                "SQL",
                "pending",
                None,
                None,
                Some("SELECT false"),
                None,
            ),
        ]);
        let rows = evaluate_invariants(&nodes, "lp", "completed");
        assert!(
            passed(&rows, INV_JOIN_BRANCHES),
            "break-abandoned sibling under a loop must not be a violation"
        );
        assert!(passed(&rows, INV_REACHABLE));
    }

    #[test]
    fn join_outside_loop_still_strict_about_running_sibling() {
        // Same shape, but the JOIN is the root (not under a loop): strict.
        let nodes = map(vec![
            node("j", "JOIN", "completed", Some("a"), Some("b"), None, None),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node(
                "b",
                "SLEEP",
                "running",
                None,
                None,
                Some("{\"sleep_seconds\":60}"),
                None,
            ),
        ]);
        let rows = evaluate_invariants(&nodes, "j", "completed");
        assert!(!passed(&rows, INV_JOIN_BRANCHES));
    }

    // ----- IF takes different branches across iterations (MF4) -----------

    #[test]
    fn if_under_loop_with_both_branches_completed_passes() {
        // Inside a loop the IF ran both branches across iterations; both end
        // `completed` (stale). The "exactly one branch" rule is skipped.
        let nodes = map(vec![
            node(
                "lp",
                "LOOP",
                "completed",
                Some("if"),
                None,
                Some("{\"condition_node\": \"lcond\"}"),
                None,
            ),
            node(
                "if",
                "IF",
                "completed",
                Some("a"),
                Some("b"),
                cond_if("ifc").as_deref(),
                None,
            ),
            node(
                "ifc",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT true"),
                None,
            ),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "completed", None, None, Some("SELECT 2"), None),
            node(
                "lcond",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT false"),
                None,
            ),
        ]);
        let rows = evaluate_invariants(&nodes, "lp", "completed");
        assert!(
            passed(&rows, INV_UNTAKEN_IF),
            "stale both-branches-completed under a loop must not be a violation"
        );
    }

    // ----- malformed query JSON (SF1) ------------------------------------

    #[test]
    fn malformed_if_query_json_flagged() {
        let nodes = map(vec![
            node(
                "if",
                "IF",
                "completed",
                Some("a"),
                Some("b"),
                Some("not json at all"),
                None,
            ),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            node("b", "SQL", "pending", None, None, Some("SELECT 2"), None),
        ]);
        let rows = evaluate_invariants(&nodes, "if", "completed");
        let r = rows_for(&rows, INV_QUERY_JSON);
        assert!(
            r.iter()
                .any(|x| !x.passed && x.node_id.as_deref() == Some("if")),
            "non-object IF query must be flagged"
        );
    }

    #[test]
    fn raw_sql_query_is_not_flagged_as_malformed_json() {
        // SQL nodes carry raw SQL in `query`; they must not trip the JSON check.
        let nodes = map(vec![node(
            "s",
            "SQL",
            "completed",
            None,
            None,
            Some("SELECT 1"),
            None,
        )]);
        let rows = evaluate_invariants(&nodes, "s", "completed");
        assert!(passed(&rows, INV_QUERY_JSON));
    }

    // ----- duplicate branch id (SF2) -------------------------------------

    #[test]
    fn join_with_left_equals_right_flagged() {
        let nodes = map(vec![
            node("j", "JOIN", "completed", Some("a"), Some("a"), None, None),
            node(
                "a",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT 1"),
                Some("x"),
            ),
        ]);
        let rows = evaluate_invariants(&nodes, "j", "completed");
        let r = rows_for(&rows, INV_JOIN_NAMES);
        assert!(
            r.iter().any(|x| !x.passed
                && x.detail
                    .as_deref()
                    .is_some_and(|d| d.contains("more than once"))),
            "duplicate branch id must be flagged, not a spurious self-collision"
        );
    }

    // ----- zero-branch JOIN (SF3) ----------------------------------------

    #[test]
    fn completed_join_with_no_branches_flagged() {
        let nodes = map(vec![node("j", "JOIN", "completed", None, None, None, None)]);
        let rows = evaluate_invariants(&nodes, "j", "completed");
        let r = rows_for(&rows, INV_JOIN_BRANCHES);
        assert!(r
            .iter()
            .any(|x| !x.passed && x.node_id.as_deref() == Some("j")));
    }

    // ----- missing JOIN branch + 3-way name collision --------------------

    #[test]
    fn join_branch_missing_from_nodes_flagged() {
        let nodes = map(vec![
            node("j", "JOIN", "completed", Some("a"), Some("b"), None, None),
            node("a", "SQL", "completed", None, None, Some("SELECT 1"), None),
            // branch "b" intentionally absent
        ]);
        let rows = evaluate_invariants(&nodes, "j", "completed");
        let r = rows_for(&rows, INV_JOIN_BRANCHES);
        assert!(r
            .iter()
            .any(|x| !x.passed && x.node_id.as_deref() == Some("b")));
    }

    #[test]
    fn join3_name_collision_via_extra_nodes() {
        let nodes = map(vec![
            node(
                "j",
                "JOIN",
                "completed",
                Some("a"),
                Some("b"),
                Some("{\"extra_nodes\": [\"c\"]}"),
                None,
            ),
            node(
                "a",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT 1"),
                Some("x"),
            ),
            node(
                "b",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT 2"),
                Some("y"),
            ),
            node(
                "c",
                "SQL",
                "completed",
                None,
                None,
                Some("SELECT 3"),
                Some("x"),
            ),
        ]);
        assert!(!passed(
            &evaluate_invariants(&nodes, "j", "completed"),
            INV_JOIN_NAMES
        ));
    }
}
