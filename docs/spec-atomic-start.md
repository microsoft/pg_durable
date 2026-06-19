# Keeping the control plane and the runtime consistent

**Status:** Implemented and validated. Atomic `df.start` / `df.cancel` /
`df.signal`, plus a reconciler that repairs leftover drift.
**Author:** pg_durable team
**Date:** June 2026

## Problem

A durable function has state in two places:

- **pg_durable control plane** — `df.nodes` and `df.instances`, written on the
  caller's PostgreSQL transaction.
- **duroxide runtime** — `_duroxide` queue/history/instance state, previously
  written out-of-band through a separate connection.

Those writes were not atomic. The visible failure was a rolled-back `df.start()`:
`df.*` rows rolled back, but the duroxide enqueue survived. The worker then retried
an orchestration whose graph no longer existed, waited up to 5 seconds for rows that
would never appear, and left an orphan behind. We reproduced this with rolled-back
starts leaving `_duroxide.instances` rows that had no matching `df.instances` row.

`df.cancel()` and `df.signal()` had the same transaction-boundary problem for their
runtime enqueue: a rollback of the caller's transaction did not roll back the runtime
work.

## Decision

Implement **prevent + repair**:

1. **Prevent:** enqueue `df.start()`, `df.cancel()`, and `df.signal()` runtime work
   inside the caller's transaction via SPI. The control-plane writes and runtime
   enqueue now commit or roll back together.
2. **Repair:** run a lightweight reconciler that removes leftover runtime orphans
   and marks stuck control-plane rows failed. This catches legacy/fallback drift and
   crash-time drift that transaction-local enqueue cannot prevent.

## Alternatives considered

| Option | Summary | Decision |
|---|---|---|
| Single source of truth in `_duroxide` | Move all state into the runtime schema and rebuild pg_durable reads/security over it. | Too large and migration-heavy for this fix. |
| Run pg_durable writes inside duroxide's transaction | Let duroxide-pg perform the `df.*` writes on its worker-pool connection. | Atomic, but not with the caller's transaction; breaks identity capture and row security expectations. |
| Run duroxide enqueue inside the caller's transaction | Keep both stores and use SPI to enqueue runtime work next to `df.*` writes. | Chosen primary fix. |
| Async reconciler only | Tolerate drift and repair it later. | Useful backstop, but insufficient alone. |

## Design overview

`df.start()` still creates the graph and instance rows in `df.*`. The final enqueue
step now happens through SQL on the same transaction, so a rollback undoes both the
control-plane rows and the runtime queue row. `df.cancel()` and `df.signal()` follow
the same transaction rule.

The runtime queue is not writable by ordinary users, so the enqueue goes through
private `SECURITY DEFINER` wrappers in the `df` schema. These wrappers are granted
through `df.grant_usage()`, build the runtime work items themselves, and perform
their own authorization checks before writing to `_duroxide`.

The start wrapper is intentionally **not** a general-purpose privileged runtime
entrypoint. It only starts the root function-graph orchestration and validates that
the input targets the same instance id. Cancel/signal wrappers authorize against the
instance owner.

### Direct duroxide-pg coupling

This is the abstraction break in the design. Most pg_durable code talks to the
runtime through duroxide's Rust provider/client API. That API uses a separate
connection pool, so it cannot share the caller's backend transaction.

To get caller-transaction atomicity, this PR calls the duroxide-pg SQL surface
directly (`enqueue_orchestrator_work`, `delete_instances_atomic`, and selected
runtime tables). That only works with a PostgreSQL-backed provider. In practice,
pg_durable is itself a PostgreSQL extension whose runtime state lives in the same
database, so a non-PG provider is not a meaningful deployment target; still, the
code probes for the SQL surface and falls back to the old out-of-band path when it
is absent.

### Signals

`df.signal()` fans out to the root instance and any running sub-orchestrations,
because a child branch may be the one waiting on the signal.

Duroxide does not buffer external events until an orchestration is ready to receive
them. Therefore a signal sent before the root runtime row exists is rejected instead
of returning `OK` and being silently skipped. Once the runtime row exists, the
signal enqueue is atomic with the caller's transaction.

### Reconciler

`df.reconcile()` is an admin-only backstop. It:

- deletes orphaned runtime **root** instances whose full subtree has no matching
  `df.instances` row; and
- marks stuck `df.instances` rows failed when there is no live runtime instance and
  no queued start.

The background worker keeps one reconciler durable loop running per cluster on
`pg_durable.reconciler_cron` (default `*/5 * * * *`; empty disables it), submitted
by the dedicated non-superuser role `df_reconciler`.

## Behavior changes

- `df.start()`, `df.cancel()`, and `df.signal()` now participate in the caller's
  transaction. For example, `BEGIN; SELECT df.start(...); ROLLBACK;` no longer
  starts the workflow on the atomic path.
- If the duroxide-pg SQL surface or the `df` wrappers are missing, pg_durable logs
  and falls back to the previous non-atomic client path. The fallback is not emitted
  as a client-visible SQL `WARNING`, so scripts that capture `SELECT df.start(...)`
  output remain compatible.
- `df.wait_for_schedule` now records an `utc_now` event before the timer so repeated
  schedule waits compute the next cron tick each generation. This fixes a loop
  busy-loop bug, but changes the recorded replay event sequence.

## Upgrade and compatibility

The wrappers and `df.reconcile()` are `df`-schema objects, so they are included in
both fresh-install SQL and the `0.2.3 -> 0.2.4` upgrade script. The upgrade script
also updates `df.grant_usage()` / `df.revoke_usage()` and backfills wrapper EXECUTE
privileges to existing roles that already had explicit `USAGE` on schema `df`.

Binary backward compatibility is preserved for old schemas that have not yet run
`ALTER EXTENSION UPDATE`: the new binary uses the atomic path only when both the
duroxide-pg enqueue function and the `df._enqueue_orchestrator_*` wrappers exist;
otherwise it falls back to the old out-of-band client path.

There is no table data migration.

**Upgrade caveat:** drain or restart any in-flight instance already waiting in a
`WAIT_SCHEDULE` node during upgrade. Those histories may replay expecting the old
sequence and fail as nondeterministic after the `utc_now` change.

## Validation

Automated coverage added in this PR:

- `24_atomic_rollback` — rolled-back start/cancel/signal leave no runtime effect;
  signaling before runtime materialization is rejected.
- `25_enqueue_wrapper_authz` — wrapper authorization and start-wrapper hardening.
- `26_reconcile_orphan_gc` — orphan root with child sub-orchestrations is collected
  as a full subtree; healthy instances remain untouched.
- `scripts/test-upgrade.sh` — schema equivalence, binary compatibility, data
  compatibility, and existing-role wrapper-grant backfill.

Manual/targeted validation included signal fan-out, cancel consistency, reconciler
liveness, cron scheduling, formatting, clippy, pgspot, and upgrade tests.

## Remaining risks / follow-up

- The direct duroxide-pg SQL dependency is intentional but should remain small and
  well documented. Moving the privileged enqueue surface into duroxide-pg would be a
  cleaner long-term boundary.
- Reconciler grace/cadence and role provisioning may need tuning after operational
  experience.
