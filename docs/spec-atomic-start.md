# Spec: Atomic `df.start()` — Eliminating `df.*` ↔ `_duroxide` Divergence

**Status:** Proposal
**Author:** pg_durable team
**Date:** June 2026

## Overview

`df.start()` writes to two independent stores that are **not** committed together:

- the **pg_durable control plane** (`df.nodes`, `df.instances`) — written on the
  caller's backend transaction via SPI; and
- the **duroxide runtime** (`_duroxide.orchestrator_queue`) — enqueued
  out-of-band on a *separate* sqlx connection pool, committed independently.

Because the two halves are not atomic, the stores can diverge. The most common
failure is the "rolled-back start" leak: a `df.start()` whose surrounding
transaction is rolled back (or whose batch subtransaction aborts on a PK
collision) leaves an **orphaned orchestration** in `_duroxide` with no
corresponding `df.*` rows. The background worker then repeatedly tries to load a
graph that does not exist, fails after a 5 s timeout, and the orphan persists in
`_duroxide.instances`.

Four designs were explored to keep the two stores consistent (see **Design
options considered** below). This spec **implements Option 3 (primary) plus
Option 4 (complementary backstop)**: make the duroxide start-enqueue part of the
caller's backend transaction so `df.start()` is atomic — either everything
commits or nothing does — and add an asynchronous reconciler to repair any
residual drift that start-time atomicity cannot prevent.

### Evidence (observed during investigation)

- A `df.start()` executed inside a transaction that was then `ROLLBACK`-ed left a
  row in `_duroxide.instances` (e.g. `48819f12`) with **zero** rows in
  `df.instances`. The orphan survived the rollback.
- Under load, orphaned start items self-sustain via retry and saturate the
  2-thread worker with 5 s "Instance not found … transaction may have been
  rolled back" failures.
- The short-id PK-collision path (8 hex chars ≈ 2³²) reliably aborts `df.start()`
  well under 1M instances (observed first-collision draws: 9248, 34845, 40445,
  60776). That abort is *safe* today (it happens before the duroxide enqueue),
  but it exercises the same dual-write seam.

## Design options considered

Four approaches were explored for keeping the `df.*` control plane and the
`_duroxide` runtime consistent. The mechanics of the chosen approach are detailed
in **Design** below; this section records all four and the decision.

**Option 1 — Single source of truth in `_duroxide`.** Drop the `df.instances` /
`df.nodes` control tables entirely, keep all instance state in `_duroxide`,
serialize the graph into the orchestration input, and have duroxide expose
whatever state pg_durable needs (via views / read APIs).
*Guarantee:* total — there is only one store, so nothing can diverge.
*Cost:* large — moves the `submitted_by` security boundary, requires rebuilding
per-user RLS over duroxide-owned tables, re-exposing every `df.*` read surface,
and a destructive migration with B1 backward-compat implications. A possible
long-term direction, not this change.

**Option 2 — Hand duroxide-pg our SQL to run inside *its* transaction.** Keep
both schemas; extend duroxide-pg so the start-enqueue also executes the
pg_durable `df.*` writes in the same (sqlx, worker-pool) transaction.
*Guarantee:* `df.*` ↔ `_duroxide` atomic — but on the worker-pool connection, so
`df.start()` stops participating in the *caller's* transaction and the `df.*`
writes run as the pool role, breaking `current_user` / `submitted_by` capture and
RLS. Strictly weaker than Option 3.

**Option 3 — Hand duroxide-pg *our* (the caller's) transaction.** Keep both
schemas; run duroxide's start-enqueue inside the caller's backend transaction via
SPI, alongside the `df.*` writes.
*Guarantee:* strongest — `df.nodes` + `df.instances` + the queue row + the
caller's surrounding statements all commit or roll back together; identity
capture and the `df.*` read surface are untouched; the 5 s load race disappears.
*Cost:* small — the start is a single SQL-function call — with one wrinkle: a
`SECURITY DEFINER` enqueue entrypoint is needed because the queue INSERT is
owner-only. **Chosen as the primary fix.**

**Option 4 — Tolerate divergence; repair asynchronously.** Accept a transient
window and add a reconciler — ideally a built-in durable function — that detects
and repairs mismatches (orphaned `_duroxide` instances, stuck `df.instances`
rows, `status`-mirror drift).
*Guarantee:* none added; eventual consistency with bounded repair latency.
*Value:* the only option that also catches divergence from crashes
*mid-execution* and from paths Option 3 does not cover (the worker-side mirror
activities, and signal/cancel until they are migrated). **Chosen as a
complementary backstop.**

### Comparison

| Option | Atomic with `df.*` | Atomic with caller tx | Kills 5 s load race | Fixes crash-time drift | Effort |
|--------|:--:|:--:|:--:|:--:|:--:|
| 1 — single source of truth in `_duroxide` | n/a (one store) | no¹ | yes | yes | Large |
| 2 — our SQL in duroxide's tx | yes | **no** | yes | no | Medium |
| 3 — enqueue in caller's tx (SPI) | yes | **yes** | **yes** | no | Small–Med |
| 4 — async GC / reconciler | repairs | — | no | **yes** | Small–Med |

¹ Option 1 also decouples from the caller's transaction unless the enqueue is
itself done via SPI — at which point its start path converges with Option 3.
"Fixes crash-time drift" = repairs divergence from a crash *mid-execution* (not
just at start); only Options 1 and 4 do this, which is why Option 4 is kept as a
backstop alongside Option 3.

### Decision

Implement **Option 3 + Option 4**. Option 3 removes the dual-write at the source
for backend-initiated starts (and, in a later phase, `df.cancel`); Option 4 is a
lightweight safety net for the residual divergence that no start-time atomicity
can prevent (crashes mid-execution, the best-effort `df.*` mirror, and
not-yet-migrated signal/cancel). Options 1 and 2 are rejected — Option 1 is
disproportionate to the problem, and Option 2 is a strictly weaker variant of
Option 3.

## Background: how a start is written today

`crate::dsl::start()` (src/dsl.rs) executes, in order, on the **caller's**
transaction unless noted:

1. `instance_id = short_id()` (src/dsl.rs:645).
2. Read-only validation (database exists, caller has `LOGIN`, superuser policy).
3. `insert_nodes()` → INSERT rows into `df.nodes` (src/dsl.rs:842).
4. INSERT row into `df.instances` (src/dsl.rs:888).
5. Capture `df.vars` snapshot.
6. `start_durable_function()` → `Client::start_orchestration()` →
   `store.enqueue_for_orchestrator(StartOrchestration)` (src/dsl.rs:923) — runs on
   the cached `DUROXIDE_CLIENT` sqlx pool (src/client.rs), **separate
   connection, independently committed.** Failures here are logged, not raised
   (src/dsl.rs:928).

Key facts that make the fix small:

- **The start is a single enqueue.** `Client::start_orchestration` builds one
  `WorkItem::StartOrchestration` and calls `enqueue_for_orchestrator`
  (duroxide `client/mod.rs`). The duroxide-pg provider implements that as one
  call to the SQL function `_duroxide.enqueue_orchestrator_work(...)`, whose body
  is a single `INSERT INTO _duroxide.orchestrator_queue`. The
  `_duroxide.instances`/`history` rows are materialized **later** by the worker.
- **The atomic unit is therefore just** `{df.nodes INSERTs, df.instances INSERT,
  one orchestrator_queue INSERT}`.
- **duroxide-pg is SQL-function based.** Every provider operation is a function
  in the `_duroxide` schema, so the enqueue can be invoked directly via SPI on
  the caller's transaction — no async pool required for the start path.

### What each store owns (so we know what must *not* change)

| Data | Source of truth | Notes |
|------|-----------------|-------|
| Graph (`df.nodes`) | `df.*` | duroxide does not store it; the worker loads it via the `load-function-graph` activity. |
| Execution history | `_duroxide.history` | duroxide-internal; transactional per turn via `ack_orchestration_item`. |
| Control plane (`root_node`, `submitted_by`, `database`, `label`) | `df.instances` | needed by the worker to load + authenticate. |
| `df.instances.status` | best-effort mirror | written by the `update-instance-status` activity; not atomic with duroxide, self-heals. |
| `df.nodes.status/result/error` | best-effort mirror | written by the `update-node-status` activity; same properties as above. |

`submitted_by` is a **security boundary**: it is captured as `current_user` at
`df.start()` time and pinned by a composite FK; the worker re-checks the
superuser policy (src/activities/load_function_graph.rs). Any change must keep it
unforgeable.

### Dual-write inventory

Auditing every `df.*` writer against every duroxide-client call, the cross-store
seams are bounded and fall into two distinct classes.

**Backend (session) side — `df.*` on the caller's transaction + an out-of-band
duroxide-client enqueue.** This is the class Option 3 fixes.

| Site | `df.*` write (user tx, SPI) | `_duroxide` write (out-of-band pool) | Dual-write? |
|------|------|------|------|
| `df.start()` | INSERT `df.nodes` + `df.instances` (src/dsl.rs:842,888) | enqueue `StartOrchestration` (src/dsl.rs:923) | **Yes** — Phase 1 |
| `df.cancel()` | UPDATE `df.instances.status='cancelled'` (src/dsl.rs:966) | `cancel_instance` enqueue (src/dsl.rs:955) | **Yes** — Phase 2 |
| `df.signal()` | **none** (only an RLS read of `df.instances`) | `raise_event` + descendant fan-out (src/dsl.rs:616) | **No** — single store |

Notes:

- **`df.cancel()` is a genuine dual-write** with two twists vs `df.start()`: it
  enqueues to duroxide **first** and then does the `df.*` UPDATE (opposite
  order), and the UPDATE is only an *optimistic* mirror — the authoritative
  `cancelled` status is re-applied when the worker processes the cancel via
  `update-instance-status`, so divergence here is usually transient and
  self-healing. It still belongs in the same in-transaction treatment for strict
  atomicity.
- **`df.signal()` is not a dual-write**: it writes only `_duroxide`. There is no
  cross-store inconsistency to create; moving it in-transaction only changes
  "don't deliver the signal if my surrounding tx rolls back" semantics — a
  nice-to-have, not a consistency fix.
- Not seams: `df.run()` is a no-op stub; `df.result/status/explain/monitoring`
  are reads; `df.vars` and `df._worker_epoch` touch only `df.*`.

**Worker side — `df.*` mirror maintained by activities, on a connection separate
from duroxide's history ack.** Option 3 does **not** address this class.

| Activity | `df.*` write | Property |
|----------|--------------|----------|
| `update-instance-status` | UPDATE `df.instances.status` | eventually consistent, self-healing |
| `update-node-status` | UPDATE `df.nodes.status/result/error` | eventually consistent, self-healing |

These are at-least-once activities re-applied on replay, so a crash between the
duroxide ack and the mirror update is transient lag, not permanent divergence.
This is the "best-effort mirror"; any persistent drift is the reconciler's job
(see Complementary backstop), not Option 3's.

## Goals

- `df.start()` is **atomic with the caller's transaction**: on rollback, no
  `df.*` rows *and* no `_duroxide` start item remain; on commit, both are present
  and the worker picks the instance up only after the `df.*` rows are visible.
- Eliminate the rolled-back-start orphan leak at the source.
- Eliminate the `load-function-graph` "wait up to 5 s for the row to appear"
  race (it becomes structurally impossible).
- No change to the `df.*` schema's read surface (status/result/monitoring/explain
  keep working unchanged).

## Non-goals

- Collapsing `df.*` into `_duroxide` (Option 1) — out of scope; tracked
  separately as a possible long-term direction.
- Fixing the best-effort `df.instances.status` mirror (it is eventually
  consistent by design).
- Changing short-id generation / the id space. (Independent; can be addressed
  separately. This spec makes a collision a clean, fully-atomic abort.)
- Migrating `df.signal()` / `df.cancel()` to the in-transaction path — same
  mechanism, scoped as a follow-up (see Phasing).

## Design

### Mechanism

In `crate::dsl::start()`, replace step 6 (the out-of-band
`start_durable_function` pool call) with an **SPI call** that enqueues the start
work item on the caller's transaction, immediately after the `df.instances`
INSERT:

```text
-- still on the caller's transaction (SPI):
INSERT INTO df.nodes ...                          -- step 3 (unchanged)
INSERT INTO df.instances ...                      -- step 4 (unchanged)
SELECT df.__enqueue_start($instance_id, $work_item_json, $visible_at);  -- step 6 (new)
```

Because the enqueue is now an SPI statement, it shares the caller's transaction:
rollback removes the queue row along with the `df.*` rows; commit makes them
visible together.

### The work item

pg_durable already depends on the `duroxide` crate, so it should **construct and
serialize the real `WorkItem` type** rather than hand-rolling JSON, guaranteeing
wire compatibility:

```rust
let item = duroxide::providers::WorkItem::StartOrchestration {
    instance: instance_id.clone(),
    orchestration: orchestrations::execute_function_graph::NAME.into(),
    input: input_json,                       // existing FunctionInput JSON
    version: None,                           // runtime resolves from registry
    parent_instance: None,
    parent_id: None,
    execution_id: duroxide::INITIAL_EXECUTION_ID,   // = 1
};
let work_item_json = serde_json::to_string(&item)?;
```

`WorkItem` is externally tagged (default serde), i.e.
`{"StartOrchestration":{...}}`. These are exactly the values the current
`Client::start_orchestration` path uses, so worker behavior is unchanged.

The enqueue target is the existing function (body is a single INSERT; the
`p_orchestration_name/version/execution_id` params are accepted but unused — the
work item is self-contained):

```sql
_duroxide.enqueue_orchestrator_work(
    p_instance_id   text,
    p_work_item     text,                 -- work_item_json
    p_visible_at    timestamptz,          -- now() for immediate start
    p_orchestration_name text DEFAULT NULL,
    p_orchestration_version text DEFAULT NULL,
    p_execution_id  bigint DEFAULT NULL)
```

### Privilege model (the one real wrinkle)

`_duroxide.orchestrator_queue` grants INSERT to its **owner only** (the
`pg_durable.worker_role`; `relacl` is empty → no PUBLIC), and
`_duroxide.enqueue_orchestrator_work` is `SECURITY INVOKER`. `df.start()` is also
`SECURITY INVOKER` and runs SPI as the calling user. Therefore a normal caller
cannot insert into the queue directly — confirmed: for a fresh `LOGIN` role,
`has_table_privilege(... 'INSERT') = false`.

The enqueue must run through a **`SECURITY DEFINER`** entrypoint owned by a role
that owns the `_duroxide` queue tables. Two placements:

- **Recommended — provide it in duroxide-pg** (proper layering; pg_durable never
  touches `_duroxide` internals). Add a stable, documented `SECURITY DEFINER`
  client-enqueue function in the `_duroxide` schema, owned by the schema owner
  (`worker_role`), e.g. `_duroxide.client_enqueue_start(p_instance_id text,
  p_work_item text, p_visible_at timestamptz)`. It performs the single queue
  INSERT and is `GRANT EXECUTE`-ed to the roles allowed to start instances.
  Applied by the BGW migration runner (`ApplyAll`); no pg_durable extension
  upgrade script needed (consistent with docs/bgw-applies-migrations.md).
- **Fallback — a `df` wrapper in pg_durable.** A `df.__enqueue_start(...)`
  `SECURITY DEFINER` function owned by the extension owner that calls
  `_duroxide.enqueue_orchestrator_work(...)`. Works in the common configuration
  where the extension owner is a superuser (or otherwise owns/【has INSERT on】the
  queue). In hardened multi-role deployments where `_duroxide` is owned by a
  non-superuser `worker_role` distinct from the extension owner, this requires
  the `worker_role` to `GRANT INSERT` on the queue tables (and `EXECUTE` on the
  enqueue fn) to the wrapper's owner. The duroxide-pg placement avoids this
  coordination.

Either wrapper **must** pin `search_path` and schema-qualify every reference
(CVE-2018-1058; enforced by the pgspot gate, scripts/pgspot-gate.sh):

```sql
CREATE FUNCTION _duroxide.client_enqueue_start(...)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$ BEGIN
  INSERT INTO _duroxide.orchestrator_queue (instance_id, work_item, visible_at, created_at)
  VALUES (p_instance_id, p_work_item, p_visible_at, pg_catalog.now());
END $$;
```

The wrapper takes **only** an opaque `instance_id`, a `work_item` string, and a
timestamp — it executes no caller-supplied SQL, so the `SECURITY DEFINER`
surface is a single fixed INSERT.

### Identity / security

`submitted_by` capture is unchanged: it is still read as `current_user` inside
`df.start()` (`SECURITY INVOKER`) **before** the enqueue and stored in
`df.instances`. The `SECURITY DEFINER` wrapper does not touch identity; the work
item carries only the orchestration name/input. The worker continues to
authenticate using `df.instances.submitted_by` and re-check the superuser policy
(unchanged). No new forgery surface is introduced.

### Worker readiness and ordering

- Keep the existing worker-readiness gate: if `_worker_ready` is absent/stale,
  `df.start()` errors as it does today (the `_duroxide` schema may not yet
  exist). This check moves from "before acquiring the client" to "before the SPI
  enqueue."
- The enqueue is the **last** write in `df.start()`; a PK collision on
  `df.nodes`/`df.instances` still aborts before it (no behavior change for the
  collision case, now fully inside one transaction).

### Consequence: the 5 s load race disappears

`load-function-graph` currently polls for up to `MAX_WAIT_SECS = 5` because the
worker could dequeue a start item before the caller's `df.*` rows committed
(src/activities/load_function_graph.rs:21,60). With an atomic start, a queue row
becomes visible to the worker **only** after the `df.*` rows commit in the same
transaction, so the "not yet visible / rolled back" branch cannot occur. The
retry loop can be simplified to a single read (optionally retain a short grace
for replication scenarios). This also removes the worker-saturation failure mode.

## Transaction-semantics decision (must be made explicit)

This change makes `df.start()` **atomic with the caller's transaction**:

```sql
BEGIN;
SELECT df.start('SELECT 1');   -- enqueued on THIS transaction
ROLLBACK;                      -- start is fully undone; nothing runs
```

Today the behavior is inconsistent (the `df.*` rows roll back but the duroxide
enqueue does not). The new behavior is the least-surprising contract and is the
explicit, documented decision of this spec. Note for users: a `df.start()` in a
transaction that later rolls back will **not** run — which is the desired fix,
but a behavior change from "fire-and-forget at statement time." This must be
called out in `USER_GUIDE.md`.

## Signals & cancellation (follow-up)

See the Dual-write inventory above for the precise classification. In short:

- **`df.cancel()` is a genuine dual-write** (`df.instances.status` + a
  `CancelInstance` enqueue) and should get the same in-transaction treatment as
  `df.start()`. It is scoped as **Phase 2** rather than Phase 1 only because it
  targets an already-committed instance (so the rolled-back-*start* leak does not
  apply) and because the worker's `update-instance-status` activity already
  re-applies the authoritative `cancelled` status, making its divergence
  transient. The `SECURITY DEFINER` enqueue entrypoint should be generalized to
  carry an arbitrary work item (e.g. `client_enqueue(instance, work_item,
  visible_at)`) so it serves cancel directly.
- **`df.signal()` is not a dual-write** (it writes only `_duroxide`), so it
  creates no cross-store inconsistency. It can ride on the same entrypoint for
  "don't deliver if my tx rolls back" semantics, but that is a nice-to-have, not
  a consistency fix — lowest priority.

## Complementary backstop — Option 4 (in scope, Phase 3)

As part of the chosen approach, a lightweight **reconciler** — ideally a built-in
durable function (a `@>` loop + `df.wait_for_schedule`) — sweeps for residual
divergence that an atomic start cannot prevent (crashes mid-execution,
not-yet-migrated signal/cancel paths, `status` mirror drift), using existing
`_duroxide` read functions (`list_instances`, `get_instance_info`,
`get_queue_depths`) and `delete_instances_atomic`. It complements Option 3 rather
than replacing it, and is sequenced as Phase 3 (see Phasing).

## Upgrade & Migration

**B1 — binary backward compatibility (new `.so` vs all prior schemas).** The new
`.so` calls the enqueue entrypoint via SPI.
- If the entrypoint is the **duroxide-pg-provided** `SECURITY DEFINER` function,
  the BGW applies the duroxide migration at startup (`ApplyAll`,
  src/worker.rs), and the function exists for every running worker. Backends
  detect readiness via `_worker_ready` (existing gate) before enqueuing.
  Versioning: bump the pinned `duroxide`/`duroxide-pg` pair together (see
  docs/upgrade-testing.md "Updating duroxide-pg") and run `cargo update`. **No
  `pg_durable` extension upgrade script is required** for duroxide-schema changes
  (docs/bgw-applies-migrations.md).
- If the entrypoint is the **`df`-schema fallback wrapper**, it is a `df` schema
  object and **does** require an extension upgrade script
  `sql/pg_durable--<prev>--<current>.sql` (CREATE FUNCTION + GRANT), plus the
  fresh-install SQL, and a "Version-Specific Changes" entry in
  docs/upgrade-testing.md. The new `.so` must still operate against older `df`
  schemas that predate the wrapper: gate the SPI path on the wrapper's existence
  (catalog probe) and **fall back to the existing out-of-band client enqueue**
  when absent. This preserves B1 while the upgrade rolls out.

**Runtime schema detection.** Reuse the existing `_worker_ready` /
`backend_duroxide_schema()` resolution. Add a one-time probe (cached per session)
for the enqueue entrypoint; if missing (old worker), fall back to the legacy
path. This makes the change safe under mixed binary/worker versions.

**Data migration.** None. No `df.*` or `_duroxide` table shapes change. Existing
in-flight instances are unaffected (their queue items were already enqueued).

**Rollback.** Reverting the `.so` restores the out-of-band enqueue; the optional
`df` wrapper, if added, is inert when unused.

## Testing

E2E (tests/e2e/sql/) and unit coverage:

- **Atomic rollback (the leak):** `BEGIN; df.start(...); ROLLBACK;` then assert
  **both** `df.instances` and `_duroxide.instances`/`orchestrator_queue` have no
  row for the instance. (Today this fails: `_duroxide` keeps an orphan.)
- **Atomic commit:** `BEGIN; df.start(...); COMMIT;` runs to completion exactly
  as before.
- **Subtransaction abort:** a `df.start()` inside a `BEGIN/EXCEPTION` block that
  raises leaves no `_duroxide` orphan.
- **PK collision (existing repro):** the short-id collision aborts cleanly with
  no `_duroxide` residue (extends the manual `short_id_collision` repro).
- **Worker-not-ready:** `df.start()` before `_worker_ready` errors as today.
- **Privilege/hardened config:** a non-superuser caller (and, for the fallback
  wrapper, a distinct `worker_role`) can start successfully and cannot insert
  into `_duroxide.orchestrator_queue` directly.
- **No 5 s waits:** worker logs contain no "transaction may have been rolled
  back" entries during normal start/rollback flows.

## Phasing

1. **Phase 1 (this spec):** atomic `df.start()` via the `SECURITY DEFINER`
   enqueue entrypoint; readiness gate + legacy fallback; simplify the
   `load-function-graph` retry; docs + tests.
2. **Phase 2:** apply the same in-transaction enqueue to `df.signal()` /
   `df.cancel()`.
3. **Phase 3:** ship the reconciler backstop (Option 4).

## Open questions / risks

- **Entrypoint placement:** duroxide-pg (clean layering, coordinated release) vs
  a `df` fallback wrapper (no duroxide-pg release, but cross-role grants in
  hardened setups). Recommendation: duroxide-pg, with the `df` fallback retained
  for B1 during rollout.
- **Contract stability:** pg_durable now depends on the enqueue entrypoint
  signature and the `WorkItem` JSON. Mitigated by reusing the `duroxide`
  `WorkItem` type and the version-locked duroxide/duroxide-pg pair.
- **`visible_at` clock:** use `now()` (server time) for immediate starts to match
  the duroxide-pg provider's behavior; confirm no reliance on the Rust-side
  `now_ms` for ordering at start.
- **Idempotency:** `enqueue_orchestrator_work` is a bare INSERT (no dedup); the
  `df.instances`/`df.nodes` PKs already prevent duplicate instance ids within the
  transaction, so no additional dedup is required.
