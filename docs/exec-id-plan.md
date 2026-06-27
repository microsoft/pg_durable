# Plan: execution_id node state (TEMPORARY — do not commit)

> This plan file is scratch. Delete `docs/exec-id-plan.md` before the feature
> branch is finalized (last step below). It must not land in history.

## Goal

Replace the `node-state-model` PR's stored `status_reason` approach with an
`execution_id`-based model where **physical** statuses are written by the owning
orchestration and **implicit** statuses (`skipped`, `cancelled`) are *derived at
read time* in `df.instance_nodes` from each node's ancestors — with no duroxide
dependency in the read path.

---

## Step 1 — Schema: `status_details JSONB` on `df.nodes`

- Add `status_details JSONB` (nullable) to `df.nodes` in [src/lib.rs](src/lib.rs)
  `create_tables` DDL.
- Stores the writer's `execution_id` (the ordered path; see Step 4) plus room
  for small read-path payloads we already need (the IF decision; the RACE
  winner — see Step 6).
- Incidental cleanup agreed earlier: **drop the dead `error` column** and stop
  overloading `result` for non-result data.
- Keep `nodes_status_chk` limited to the **physical** statuses
  (`pending`/`running`/`completed`/`failed`). `skipped`/`cancelled` are never
  stored, so they must NOT be added to the check constraint.
- Grants: add `status_details` to nothing in the user INSERT column list (worker
  writes it); remove `error` from any column lists in `df.grant_usage` /
  `df.revoke_usage`.
- **Upgrade script** `sql/pg_durable--0.2.4--0.2.5.sql` (next version): `ADD
  COLUMN status_details`, `DROP COLUMN error`, constraint + grant adjustments.
- **Binary backward-compat (B1):** the new `.so` must still run against older
  schemas that lack `status_details`/still have `error`. The write path (Step 2)
  and read path (Step 3) must degrade gracefully when the column is absent
  (runtime column detection, or a guarded query) — verify with
  `scripts/test-upgrade.sh`.

## Step 2 — Write path: fence status updates on `execution_id`

- In [src/activities/update_node_status.rs](src/activities/update_node_status.rs):
  accept the caller's `execution_id`, write it to `status_details`, and make the
  `UPDATE` **conditional**: apply only when the incoming `execution_id` is **not
  superseded** by the stored one (`incoming >= stored`, equal allowed for
  running→terminal within one execution).
- Ordering: JSONB does not compare the way we need. Store/compare via a
  **comparable form** (e.g. an `int[]` of the execution numbers) so Postgres'
  native lexicographic array order gives "first differing segment, larger number
  wins". The JSONB can carry the human-readable path; the gate compares the
  array form (column, generated column, or extracted in the `WHERE`).
- **Fire-and-forget / determinism:** the activity returns `Ok` regardless of
  whether the row was updated; the orchestration must never branch on the
  outcome (keep `let _ = ctx.schedule_activity(...)`).

## Step 3 — Read path: `df.instance_nodes` infers status from `df.nodes` only

- Rewrite [src/monitoring.rs](src/monitoring.rs) `instance_nodes` to:
  1. **Drop the duroxide dependency** — read solely from `df.nodes` (one
     `SELECT` of the instance's rows). Remove `list_executions` / the fabricated
     `execution_id` cross join.
  2. For each node, **leave `status` and the stored `execution_id` untouched**
     and instead **add inferred fields to the returned `status_details`**:
     - `inferred_status` — the *effective* state at read time (`skipped`,
       `cancelled`, `pending`, or the node's own physical status when no
       ancestor overrides it).
     - `inferred_status_from_ancestor_id` — the node whose state *determined*
       `inferred_status` (the first ancestor whose `execution_id` is not a
       prefix of this node's). Makes the derivation explainable per row.
     - We deliberately do NOT add `inferred_status_execution_id`: it is just the
       `execution_id` of `inferred_status_from_ancestor_id`'s row, so a reader
       can join to that node if needed.
     - Rationale: the read path **must not compete with the write path**. By
       augmenting (not overwriting) `status_details`, the helper never races the
       orchestration's fenced writes. (If we later materialize this at the DB
       level it would compete — defer that decision.)
  3. **Derivation (leaf→root climb):** find the first ancestor whose
     `execution_id` is not a prefix of the node's; that ancestor's state sets
     `inferred_status`. Ancestor `failed` ⇒ `skipped`; `running`/newer execution
     ⇒ `pending`; `completed` but branch/iteration not taken ⇒ `skipped`; RACE
     loser ⇒ `cancelled`. Use the IF decision and RACE winner recorded in
     `status_details` (Step 6) to know which branch/iteration is "taken".
  4. Children are reachable via `left_node`/`right_node`; the tree is immutable
     after `df.start()`, so no parent column is required (optional safe
     denormalization only).
- Output columns: `status` and `status_details` keep their stored values; the
  inferred fields live inside the returned `status_details` JSONB only, never in
  the base table.

## Step 4 — Document the `execution_id`

- Fold the structure from [docs/execution-id.md](docs/execution-id.md) into the
  permanent doc (see Step 7): ordered path `root:n₀ : seg₁:n₁ : … : segₖ:nₖ`;
  segment added only at sub-orchestration boundaries (loop iteration, join/race
  branch); branch numbers = 1, loop numbers = 1..N; same node across executions
  shares segment identities+length, differing only in numbers ⇒ total order.

## Step 5 — Document the state-transition graph + helper

- Add a diagram of node states with the **physical** transitions
  (`pending→running→completed|failed`) drawn solid and the **implicit, never
  materialized** ones (`→skipped`, `→cancelled`, re-entry `→pending` on a new
  execution) drawn dashed, with a clear note that the dashed ones exist only in
  `df.instance_nodes` output.
- Document the inference helper used by `instance_nodes` (the ancestor-climb /
  derivation function): inputs, the prefix rule, each case, and that it emits
  `inferred_status` + `inferred_status_from_ancestor_id` into `status_details`
  rather than mutating the stored `status`/`execution_id`.

## Step 6 — RACE winner recording (small behavioral add)

- The root→leaves / branch-taken inference needs the RACE node to record its
  **winning branch** in `status_details`. Add this write in the race
  orchestration if not already present.

## Step 7 — Docs cleanup

- Delete [docs/execution-id.md](docs/execution-id.md) and
  [docs/node-state-model.md](docs/node-state-model.md); their content is folded
  into the permanent doc/diagram (Steps 4–5).
- Delete this plan file `docs/exec-id-plan.md` (must not be committed on the
  feature branch).

---

## Open dependency you may be assuming implicitly

**Loop boundary (prerequisite, not in your list).** Clean per-iteration
`execution_id` segments require a nested loop to run as a **sub-orchestration
rooted at the loop node**. Today the loop uses `ctx.continue_as_new` from
`graph.root_node_id` (the only `continue_as_new` caller), which both produces the
existing nested-loop "restarts wrong root" bug and prevents a nested loop from
owning its own segment. This must be addressed (or explicitly deferred with
top-level-loops-only scope) for Steps 2–3 to be correct. Track it as a separate
work item.
