# Keeping the control plane and the runtime consistent

**Status:** Implemented and validated. Atomic `df.start`/`df.cancel`/`df.signal`,
plus a reconciler that repairs leftover drift.
**Author:** pg_durable team
**Date:** June 2026

## The problem

A durable function lives in two stores that are written separately:

- the **pg_durable control plane** — `df.nodes` and `df.instances`, written on the
  caller's transaction; and
- the **duroxide runtime** — `_duroxide.orchestrator_queue`, where the orchestration
  is enqueued.

Originally `df.start()` wrote the first on the caller's transaction but enqueued the
second out-of-band, on a separate connection pool that committed on its own. The two
were never atomic, so they could disagree.

The common failure was an **orphaned orchestration**: a `df.start()` whose
surrounding transaction rolled back (or whose batch aborted on a primary-key
collision) left a row in `_duroxide` with no matching `df.*` rows. The background
worker then kept trying to load a graph that did not exist, failed after a 5-second
timeout, and the orphan stayed behind. Under load these orphans accumulated and
saturated the worker's two threads.

We observed this directly: a `df.start()` inside a rolled-back transaction left
`_duroxide.instances` row `48819f12` with zero rows in `df.instances`, surviving the
rollback.

## What we did

Two complementary changes:

1. **Prevent** the drift at the source. `df.start()`, `df.cancel()`, and
   `df.signal()` now enqueue their runtime work on the **caller's transaction**, so
   the control-plane writes and the runtime enqueue commit or roll back together.
2. **Repair** what prevention cannot cover. A reconciler periodically deletes
   leftover orphans and marks stuck instances failed — catching drift from crashes
   mid-execution and from the legacy fallback path.

Both are pg_durable-only. No `duroxide` / `duroxide-pg` or `Cargo.*` changes.

## Designs we considered

Four approaches were weighed for keeping the two stores in agreement.

**Option 1 — One store.** Drop `df.nodes` / `df.instances` entirely and keep all
state in `_duroxide`, exposing what pg_durable needs through views.
*Strongest guarantee* (only one store can't diverge) but the most disruptive: it
moves the `submitted_by` security boundary, rebuilds per-user row security over
runtime-owned tables, re-exposes every read path, and needs a destructive migration.
A possible long-term direction, not this change.

**Option 2 — Run our writes inside duroxide's transaction.** Extend duroxide-pg so
the enqueue also performs the `df.*` writes, on duroxide's worker-pool connection.
This makes the two stores atomic — but on the *worker's* connection, so `df.start()`
no longer joins the *caller's* transaction and the `df.*` writes run as the pool
role, breaking identity capture and row security. Strictly worse than Option 3.

**Option 3 — Run duroxide's enqueue inside the caller's transaction.** Keep both
stores; call the runtime's enqueue over SPI on the caller's transaction, next to the
`df.*` writes. Everything commits or rolls back together, identity capture and the
read paths are untouched, and the 5-second load race disappears. The only cost is a
`SECURITY DEFINER` wrapper, because the runtime queue is writable by its owner only.
**Chosen as the primary fix.**

**Option 4 — Tolerate drift, repair it later.** Accept a brief inconsistency window
and add a reconciler that finds and fixes mismatches. Adds no guarantee on its own,
but it is the only option that also catches drift from crashes *mid-execution* —
something no start-time atomicity can prevent. **Chosen as a backstop.**

| Option | Atomic with `df.*` | Atomic with caller's tx | Removes 5 s race | Fixes crash-time drift | Effort |
|--------|:--:|:--:|:--:|:--:|:--:|
| 1 — one store | n/a | no | yes | yes | Large |
| 2 — our writes in duroxide's tx | yes | **no** | yes | no | Medium |
| 3 — enqueue in caller's tx | yes | **yes** | **yes** | no | Small |
| 4 — async reconciler | repairs | — | no | **yes** | Small |

We implemented **Option 3 (prevent) plus Option 4 (repair)**. Options 1 and 2 were
rejected: Option 1 is out of proportion to the problem, and Option 2 is a weaker
version of Option 3.

## How a start is written

`df.start()` (`src/dsl.rs`) runs these steps on the caller's transaction:

1. Pick an instance id (`short_id()` — eight hex characters).
2. Validate (database exists, caller can log in, superuser policy).
3. Insert the graph rows into `df.nodes`.
4. Insert the instance row into `df.instances`.
5. Snapshot the caller's `df.vars`.
6. Enqueue the orchestration.

The fix is small because the start is **a single enqueue**: one
`StartOrchestration` row in `_duroxide.orchestrator_queue`. The worker builds the
`_duroxide.instances` and history rows later. And because duroxide-pg exposes every
operation as a SQL function in the `_duroxide` schema, that enqueue can run over SPI
on the caller's transaction — no separate pool needed.

### What each store owns

The fix must not move any of these boundaries.

| Data | Source of truth | Notes |
|------|-----------------|-------|
| Graph (`df.nodes`) | `df.*` | The worker loads it; duroxide does not store it. |
| Execution history | `_duroxide.history` | Runtime-internal; transactional per turn. |
| Control plane (`root_node`, `submitted_by`, `database`, `label`) | `df.instances` | The worker needs it to load and authenticate. |
| `df.instances.status` | best-effort mirror | Written by the worker; self-heals, not atomic with the runtime. |
| `df.nodes.status/result/error` | best-effort mirror | Same as above. |

`submitted_by` is a **security boundary**: it is captured as the calling role at
start time and must stay unforgeable. The worker re-checks the superuser policy when
it loads the graph.

### Where the two stores were written together

Auditing every writer, the cross-store paths are bounded. All three now enqueue on
the caller's transaction:

| Caller | `df.*` write | `_duroxide` write | On caller's tx now? |
|--------|------|------|:--:|
| `df.start()` | insert `df.nodes` + `df.instances` | enqueue `StartOrchestration` | yes |
| `df.cancel()` | update `df.instances.status` | enqueue `CancelInstance` | yes |
| `df.signal()` | none (only a row-security read) | enqueue `ExternalRaised` (+ fan-out) | yes |

- **`df.cancel()`** was a genuine dual-write: it enqueued the cancel, then updated
  the status mirror. The status update is only an optimistic hint — the worker
  re-applies the authoritative `cancelled` status when it processes the cancel — so
  any disagreement was already transient. Both now commit together.
- **`df.signal()`** writes only `_duroxide`, so it never created cross-store drift.
  Moving it onto the caller's transaction simply gives it the same rule as the
  others: *if my transaction rolls back, the signal is not delivered.*

The worker also keeps the `df.*` status columns in sync as activities run. Those
writes are eventually consistent and self-healing by design; the reconciler cleans
up any lasting drift.

## The mechanism

Step 6 of `df.start()` is now an SPI call on the caller's transaction, right after
the `df.instances` insert:

```text
INSERT INTO df.nodes ...                              -- step 3
INSERT INTO df.instances ...                          -- step 4
SELECT df._enqueue_orchestrator_start($id, $name, $input);  -- step 6 (SPI)
```

Because the enqueue is an ordinary SPI statement, it shares the caller's
transaction: a rollback drops the queue row along with the `df.*` rows, and a commit
makes them visible together. `df.cancel()` and `df.signal()` work the same way
through their own wrappers.

### Why this reaches into duroxide-pg directly (and needs the PG provider)

Everywhere else, pg_durable talks to the runtime through duroxide's Rust
provider/client API — the out-of-band start/cancel/signal fallback (`src/client.rs`)
and the monitoring/explain reads (`src/monitoring.rs`, `src/explain.rs`) all go
through `Client`/`Provider` methods, which are provider-agnostic at the API level.
The in-transaction enqueue and `df.reconcile()` are the **first places pg_durable
calls duroxide-pg's SQL surface directly**: `enqueue_orchestrator_work` and
`delete_instances_atomic`, plus reads of `_duroxide.orchestrator_queue`,
`instances`, and `executions`. They therefore depend on duroxide-pg's table shapes
and function signatures, not just on the runtime existing.

This is deliberate, and it is the whole point of the change: only direct SQL (via
SPI) can run inside the **caller's** transaction. The Rust client uses a separate
connection pool, so it can never be atomic with the backend's SPI work. The trade is
a deeper coupling to duroxide-pg in exchange for atomicity.

It would not work for a non-PostgreSQL provider — there would be no SQL functions to
call — but pg_durable already assumes a duroxide-pg provider in a known schema: it
places its own `_worker_ready` table inside `_duroxide`, resolves the schema via
`df.duroxide_schema()`, and relies on duroxide-pg applying its migrations at startup.
In the pg_durable context — a PostgreSQL extension whose runtime state lives in the
same database — there is no real use case for another provider. The probe-and-
fallback (below) keeps any non-PG provider working, non-atomically, rather than
broken.

### Why a privileged wrapper is needed

`_duroxide.orchestrator_queue` is writable by its owner only (the worker role), so a
normal caller cannot insert into it. The enqueue therefore runs through a
`SECURITY DEFINER` wrapper in the `df` schema, owned by the extension owner. Each
wrapper pins `search_path` and schema-qualifies every reference (per CVE-2018-1058,
enforced by `scripts/pgspot-gate.sh`).

The wrappers resolve the runtime schema at call time via `df.duroxide_schema()`
(`_duroxide` on current installs, legacy `duroxide` on older ones) and quote it
with `%I`. They are revoked from `PUBLIC` and granted through `df.grant_usage()`.

Because a `SECURITY DEFINER` function runs as its owner, the wrappers cannot trust
the caller. Two safeguards make them safe to grant to every user:

- **The work item is built inside the wrapper**, from validated arguments — never
  passed in. A caller cannot choose the work-item type or smuggle in a foreign
  target. `df.start` only accepts the public root graph-executor orchestration and
  requires the input JSON's `instance_id` to match the target id; `df.cancel` builds
  `CancelInstance`; `df.signal` builds `ExternalRaised`. All three use
  `json_build_object`, matching duroxide's wire format.
- **The caller is authorized before any enqueue**, by two different rules:
  - *Start* targets a brand-new instance, so it authorizes by *state*: it permits
    the enqueue only for a `pending` `df.instances` row that has no queue entry and
    no runtime instance yet. Under the atomic path a committed instance always has
    its queue row in the same transaction, so this state is reachable only for the
    row the caller just inserted — never someone else's instance.
  - *Cancel* and *signal* target an already-committed instance, so they authorize by
    *ownership*: `pg_has_role(session_user, <instance owner>, 'MEMBER')`.
    `session_user` is the real authenticated role (it cannot be spoofed inside a
    `SECURITY DEFINER` function), and checking membership rather than an exact name
    means a role that owns the instance through `SET ROLE` still qualifies. A
    non-member is rejected before anything is enqueued — the same gate `df.cancel` /
    `df.signal` already enforce through row security.

### Signal fan-out

A signal must reach the root instance **and** every running sub-orchestration,
because a child (a `JOIN`/`RACE` branch or a loop generation) may be the one waiting
on it. Duroxide does not buffer external events until an orchestration has a pending
subscription, so `df.signal` first requires the root runtime row to exist; a signal
sent in the same transaction as `df.start()` is rejected instead of returning `OK`
and being skipped before the workflow can observe it. Once the root is materialized,
the wrapper walks the instance tree (`_duroxide.instances.parent_instance_id`) and
enqueues one event for the root plus each running descendant — all on the caller's
transaction, so the whole fan-out is atomic.

### Worker readiness and ordering

- The existing readiness gate still applies: if the worker has not initialized the
  runtime schema yet, `df.start()` fails clearly (and atomically — the `df.*`
  inserts roll back).
- The enqueue is the last write in `df.start()`. A primary-key collision on
  `df.nodes` / `df.instances` still aborts before it, now cleanly inside one
  transaction.

### The 5-second load race is gone (on the atomic path)

The worker's `load-function-graph` activity used to wait up to five seconds for the
`df.*` rows to appear, because it could dequeue a start before they committed. On
the atomic path the queue row becomes visible only *after* those rows commit in the
same transaction, so that wait can't trigger. The retry is kept for the
non-atomic fallback path, where it remains a no-op on the atomic path.

## The reconciler

`df.reconcile(p_grace_seconds integer DEFAULT 60)` is a `SECURITY DEFINER`,
admin-only function that repairs leftover drift:

- It deletes orphaned **root** runtime instances — those with no parent, no matching
  `df.instances` row, and older than the grace window — gathering each orphan's full
  subtree so the delete is accepted. Sub-orchestrations (branches and loop
  generations) have no `df.instances` row of their own and are excluded by the root
  filter, so they are never collected on their own.
- It marks `df.instances` rows that are stuck non-terminal — no live runtime
  instance and no queued start — as `failed`.

Each pass is wrapped so a single failure never aborts the reconcile or stops the
loop.

The background worker runs the reconciler as a **built-in durable cron loop**,
keeping exactly one instance per cluster. It reads the schedule, connects as the
`df_reconciler` role (`SET ROLE`), and starts:

```sql
-- $1 = the pg_durable.reconciler_cron value, $2 = 'df_reconciler'
SELECT df.start(
  df.loop(df.seq('SELECT * FROM df.reconcile()', df.wait_for_schedule($1))),
  $2);
```

`worker::ensure_reconciler` starts it, skips if one is already pending or running,
and restarts it if it died. It is driven by the `pg_durable.reconciler_cron` setting
(default `*/5 * * * *`; empty disables it) and submitted by a dedicated
**non-superuser** role, `df_reconciler` (so `submitted_by` is `df_reconciler`). A
non-superuser identity keeps it clear of the superuser-instance guard and limits what
the instance can do to "run the reconciler" even if it were somehow forged.

## Behavior change for users

`df.start()` now takes part in the caller's transaction:

```sql
BEGIN;
SELECT df.start('SELECT 1');   -- enqueued on THIS transaction
ROLLBACK;                      -- fully undone; nothing runs
```

Previously the `df.*` rows rolled back but the orchestration still ran. The new
behavior is the least surprising one and is the deliberate decision of this spec,
but it *is* a change from "fires the moment the statement runs." `df.cancel()` and
`df.signal()` gain the same property. This should be called out in `USER_GUIDE.md`.

## Implementation notes

- The atomic path requires the duroxide-pg provider (see *Why this reaches into
  duroxide-pg directly* above). `df.start` / `df.cancel` / `df.signal` each probe for
  its SQL surface (`enqueue_orchestrator_work` in the resolved schema); when it is
  absent — a different provider, or a schema predating the wrappers — they log and
  fall back to the old out-of-band path, so the change never breaks another provider
  or contaminates `SELECT df.start(...)` output with client-visible warnings.
- `visible_at = now()` (transaction time) is enough for immediate starts.
- The work items are byte-compatible with duroxide's `WorkItem` JSON, so the worker
  behaves exactly as before.

### Hardening applied during review

- **Cross-tenant enqueue (high).** The start wrapper first accepted an opaque work
  item and was granted to everyone, which would let a caller forge a cancel or
  signal against another instance. Fixed by building the work item inside the
  wrapper and authorizing only a brand-new instance.
- **Reconciler deleting live work (high).** The runtime refuses to delete a parent
  without its children, so deleting only orphan roots failed on any parallel-workflow
  orphan. Fixed by gathering the full subtree and isolating each pass so one failure
  can't stop the loop.
- **Suppressing the reconciler (high).** Its single-instance check first keyed on the
  user-writable label, so a user could park a same-labelled instance to block it.
  Fixed by keying on the unforgeable `df_reconciler` submitter.
- **Cron busy-loop (medium).** `df.wait_for_schedule` baked a fixed delay at build
  time that the loop replayed every generation. Fixed so the wait node recomputes the
  delay each generation from the orchestration's recorded clock (deterministic on
  replay). Note: this changes the recorded history shape, so a wait-in-loop instance
  in flight across the upgrade may need a restart.
- **Self-healing (medium).** The reconciler is re-checked from the steady-state poll
  loop, not only once per worker epoch, so a cancelled one comes back within the poll
  interval.
- **Silent fallback (medium).** `df.start` now logs when it uses the non-atomic
  fallback.
- **Kept `LOGIN` on `df_reconciler`** (debated): the worker runs the reconcile node
  by connecting *as* the role, like every other durable-function role, so `NOLOGIN`
  would break it.

> **Local-dev note:** `DROP EXTENSION pg_durable CASCADE` can leave the worker-owned
> `_duroxide` schema half-dropped (its migration row remains but functions are gone),
> which shows up as flaky `JOIN` behavior and a missing `_worker_ready`. Recover with
> `DROP SCHEMA _duroxide CASCADE` and a restart so the worker re-applies its
> migrations.

## Upgrade and migration

**New binary against an older schema.** The wrappers live in the `df` schema, so
they ship in the extension's install SQL and an upgrade script
(`sql/pg_durable--<prev>--<current>.sql`, `CREATE FUNCTION` + `GRANT`), with a
"Version-Specific Changes" entry in `docs/upgrade-testing.md`. A new binary running
against an older `df` schema that predates the wrappers must still work: each caller
uses the atomic path only when both the duroxide-pg SQL enqueue function **and** the
`df._enqueue_orchestrator_*` wrappers exist; otherwise it falls back to the old
out-of-band path. This keeps the binary compatible with every prior schema while
the upgrade rolls out.

**Data migration.** None. No table shapes change, and already-enqueued work items
are left in place. One caveat: the `df.wait_for_schedule` fix changes the recorded
history shape for a wait-in-loop orchestration, so such in-flight instances may need
to be restarted after upgrade if they replay across the change.

**Rollback.** Reverting the binary restores the out-of-band enqueue; the wrappers, if
left in place, are simply unused.

**Future direction.** The privileged enqueue could move into duroxide-pg, owned by
the runtime schema owner — cleaner layering, at the cost of a coordinated
duroxide-pg release. The `df`-schema wrapper avoids that coordination and is what
ships today.

## Validation (PostgreSQL 17)

Prevent:

| Check | Result |
|-------|:--:|
| Committed `df.start()` runs to completion | pass |
| Rolled-back `df.start()` leaves no `df.*` and no `_duroxide` orphan | pass |
| Rolled-back `df.cancel()` leaves the instance running and rolls back the enqueue; committed cancel takes effect | pass |
| Rolled-back `df.signal()` rolls back the fan-out enqueue; committed signal delivers (incl. fan-out into a sub-orchestration) | pass |
| A caller cannot enqueue a start, cancel, or signal against a foreign or arbitrary instance; cancel/signal succeed for the owning role (incl. via `SET ROLE`) | pass |
| Schema resolved dynamically; atomicity holds | pass |
| E2E `07_signals`, `23_signal_in_race` (fan-out), `22_cancel_status_consistency` | 3/3 |
| Broader E2E subset (core, conditionals, loops, variables, join, race) | pass |

Repair:

| Check | Result |
|-------|:--:|
| `df.reconcile()` deletes an orphan root with children, leaves sub-orchestrations and live instances intact | pass |
| `df.reconcile()` marks a stuck instance failed | pass |
| Reconciler auto-starts as non-superuser `df_reconciler`, stays a single instance | pass |
| Reconciler fires on the cron schedule without spinning, and restarts after being cancelled | pass |
| E2E subset unaffected with the reconciler running | pass |
| `cargo fmt --check` clean; no new clippy warnings | pass |

## Open questions

- **Enqueue placement** — keep the `df`-schema wrapper, or move it into duroxide-pg
  (cleaner layering, but a coordinated release). The wrapper ships today; the move is
  a future option.
- **Contract stability** — pg_durable now depends on the enqueue function signature
  and the `WorkItem` JSON shape. Mitigated by the version-locked
  duroxide / duroxide-pg pair.
- **Reconciler policy** — the grace window and cron cadence still want tuning, and
  `df_reconciler` is created by the worker rather than provisioned externally.
