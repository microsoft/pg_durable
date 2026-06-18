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

This spec proposes making the duroxide start-enqueue part of the caller's
backend transaction (design **Option 3** from the design exploration), so that
`df.start()` is atomic: either everything commits, or nothing does.

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

`submitted_by` is a **security boundary**: it is captured as `current_user` at
`df.start()` time and pinned by a composite FK; the worker re-checks the
superuser policy (src/activities/load_function_graph.rs). Any change must keep it
unforgeable.

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

## Considered alternatives (summary)

1. **Single source of truth in `_duroxide`** — remove `df.*`, serialize the graph
   into the orchestration input, re-expose reads as views over `_duroxide`.
   Strongest invariant but large; security/RLS/read-API rework and a destructive
   migration. Rejected for this change.
2. **duroxide-pg runs pg_durable's SQL inside *its* sqlx transaction** — makes
   `df.*` ↔ `_duroxide` atomic but on the worker-pool connection, so `df.start`
   stops participating in the caller's transaction, and the `df.*` writes run as
   the pool role (breaks `current_user` capture). Strictly weaker than Option 3.
3. **Run the enqueue inside the caller's backend transaction via SPI (this
   spec)** — smallest change, strongest guarantee, keeps `df.*` and identity
   capture intact.
4. **Tolerate divergence + async GC/reconciler** — additive safety net; does not
   prevent transient inconsistency. Recommended as a *complementary* backstop,
   not a replacement.

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

`df.signal()` (ExternalRaised) and `df.cancel()` (CancelInstance) are also single
orchestrator enqueues and can use the same in-transaction SPI path for the same
consistency benefit. They are **out of scope** here (signal/cancel target
already-committed instances, so the rolled-back-start leak does not apply), but
the `SECURITY DEFINER` enqueue entrypoint should be designed to serve them too
(generalize to `client_enqueue(instance, work_item, visible_at)`).

## Complementary backstop (optional, recommended)

Independently of this change, a lightweight **reconciler** — ideally a built-in
durable function (a `@>` loop + `df.wait_for_schedule`) — should sweep for
residual divergence that an atomic start cannot prevent (crashes mid-execution,
not-yet-migrated signal/cancel paths, `status` mirror drift), using existing
`_duroxide` read functions (`list_instances`, `get_instance_info`,
`get_queue_depths`) and `delete_instances_atomic`. Tracked separately as
"Option 4"; not required for this spec but cheap insurance.

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
3. **Phase 3 (optional):** ship the reconciler backstop (Option 4).

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
