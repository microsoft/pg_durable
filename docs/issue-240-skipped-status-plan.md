# Issue 240 Design and Implementation Plan

## Summary

Issue 240 requests a clear way to distinguish nodes that were never executed because the workflow already failed. Today those nodes remain in `pending`, which is ambiguous.

Proposed enhancement:
- Add a terminal node status: `skipped`.
- On workflow failure, convert remaining `pending` nodes to `skipped` when the failure came from node execution (that is, at least one node is `failed`).

This keeps the existing instance-level status model unchanged (`df.instances.status` still ends as `failed`) while making node-level outcomes explicit.

## Current Behavior (Observed)

Live repro on local pg instance:
- Step 1 SQL node: `completed`
- Step 2 SQL node (intentional error): `failed`
- Step 3 SQL node (never executed): `pending`
- Instance: `failed`

This is the ambiguity reported in issue 240.

## Goals

- Make unexecuted downstream nodes observable as `skipped` after terminal workflow failure.
- Preserve backward compatibility of the new binary against old schemas.
- Keep implementation minimal and low-risk (no new tables or public function signatures).

## Non-Goals

- No change to `df.instances.status` vocabulary.
- No new monitoring projection table in this iteration.
- No attempt to classify every failure mode as producing `skipped` (for example, pre-execution policy rejection may remain as-is).

## Proposed Design

### 1. Schema: add `skipped` to allowed node statuses

Update node status check constraints so `skipped` is valid:
- Install DDL in `src/lib.rs`:
  - `nodes_status_chk`: include `skipped`.
- Upgrade DDL in next upgrade script:
  - drop and recreate `nodes_status_chk` (or equivalent alteration) to include `skipped`.

`nodes_result_status_chk` can remain unchanged because `skipped` nodes should not carry `result`.

### 2. Runtime: mark pending nodes as skipped at terminal failure

Add an activity that performs one set-based update for a single instance:

- New activity (suggested): `mark_pending_nodes_skipped`.
- SQL behavior:
  - `UPDATE df.nodes`
  - `SET status = 'skipped', updated_at = now()`
  - `WHERE instance_id = $1 AND status = 'pending'`
  - guarded by `EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = $1 AND status = 'failed')`

Guard rationale:
- Avoid changing semantics for failures that occur before any node execution (for example, instance-level rejection paths that currently do not mark node failures).
- Keep behavior aligned with issue wording: downstream steps skipped due to an earlier step failure.

### 3. Orchestration integration point

In `execute_function_graph` top-level failure path (when instance is being moved to `failed`):
- After node failure is recorded and before/after instance status update, schedule the new activity once for that instance.
- Make the update idempotent and best-effort (safe if retried).

Why this placement:
- Central place where terminal failure is decided.
- Avoids needing per-node graph traversal logic.
- Handles linear and composite graphs (`THEN`, `IF`, `JOIN`, `RACE`, `LOOP`) uniformly.

### 4. Optional hardening in `update_node_status`

No required behavior change, but add a small guard in plan review:
- Keep allowing transitions to `completed` / `failed` as today.
- Ensure no code path writes result for `skipped`.

## Backward Compatibility and Upgrade Strategy

### Binary backward compatibility (B1)

New `.so` may run against an older schema where `nodes_status_chk` does not include `skipped`.
If runtime writes `skipped` in that state, updates would fail.

Plan:
- Runtime schema detection for `skipped` support before attempting the bulk update.
- If unsupported, no-op and keep legacy behavior (`pending`).

Implementation options:
- Option A (preferred): activity checks `pg_constraint` definition for `nodes_status_chk` containing `skipped`.
- Option B: attempt update inside savepoint-like handling and ignore check-constraint violation.

Option A is clearer and avoids noisy errors.

### Schema upgrade (A/B2)

- Create next upgrade script `sql/pg_durable--0.2.2--0.2.3.sql` (version number illustrative; use actual next version).
- Add DDL to update `nodes_status_chk` to include `skipped`.
- Ensure fresh-install schema (from current `src/lib.rs` extension SQL) matches upgraded schema.

## Test Plan

### Unit / Rust-level

- Activity test: when instance has a failed node plus pending nodes, only pending nodes become `skipped`.
- Activity test: when no failed node exists, no rows are changed.
- Compatibility test hook: when schema does not support `skipped`, activity no-ops without error.

### E2E SQL

Add a new E2E SQL test (for example `tests/e2e/sql/49_failed_downstream_nodes_skipped.sql`):
- Build a 3-step sequence where step 2 fails.
- Wait for terminal instance status `failed`.
- Assert:
  - step 1 node is `completed`
  - step 2 node is `failed`
  - step 3 node is `skipped` (not `pending`)
- Include clear failure messages.

Also verify an instance-level failure path with no node failure (if represented in existing tests) does not force all nodes to `skipped`.

### Upgrade tests

Run:
- `./scripts/test-upgrade.sh`

Focus expectations:
- Scenario A: fresh install vs upgraded schema parity for `nodes_status_chk`.
- Scenario B1: new `.so` still works against old schema; `skipped` behavior degrades safely to legacy (`pending`) until upgrade.
- Scenario B2: data remains accessible post-upgrade.

## Docs Plan

Update user-facing status vocabulary references:
- `USER_GUIDE.md` (node status semantics)
- `docs/api-reference.md` if status values are documented there
- Optional release note entry in `CHANGELOG.md`

## Rollout and Risk

Risks:
- Writing `skipped` against non-upgraded schema (mitigated by runtime check).
- Unexpected interactions with in-flight parallel constructs (mitigated by set-based terminal update and idempotence).

Rollout:
1. Land schema + runtime + tests in one PR.
2. Validate full local matrix: fmt, clippy, unit, e2e, upgrade.
3. Document behavior change as node-level observability enhancement.

## Acceptance Criteria

- Failed workflow with downstream unexecuted nodes shows `skipped` for those nodes (post-upgrade schema).
- No regression to existing instance terminal statuses.
- New binary remains functional against pre-upgrade schema.
- E2E and upgrade tests pass.

## Implementation Checklist

- [ ] Add `skipped` to node status check constraint in install DDL (`src/lib.rs`).
- [ ] Add upgrade script change for `nodes_status_chk`.
- [ ] Add new activity to mark pending nodes as skipped for failed instances.
- [ ] Register activity in `src/registry.rs`.
- [ ] Call activity from orchestration failure path.
- [ ] Add schema-compatibility guard for pre-upgrade schemas.
- [ ] Add E2E SQL coverage.
- [ ] Update docs and changelog notes.
- [ ] Run fmt, clippy, unit, e2e, upgrade tests.
