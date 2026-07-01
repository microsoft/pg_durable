# Start Reconciliation Specification

## The problem, in plain terms

pg_durable stores two copies of "what workflows exist":

- The **`df` schema** — pg_durable's own bookkeeping (`df.instances`, `df.nodes`),
  written by `df.start()` in the caller's transaction.
- The **duroxide schema** — the workflow engine's runtime state (its queue and
  instance history), which actually makes a workflow run.

These are two separate systems. Historically `df.start()` wrote the `df` rows in
your transaction but told the engine to run the workflow **on a separate
connection**, which commits independently. That split caused two failure modes:

1. **Ghost workflow (rollback leak).** You call `df.start()` and then your
   transaction rolls back. Your `df` rows vanish — but the engine was already
   told to run the workflow on that other connection, so it keeps running with no
   `df` record behind it.

2. **Stuck workflow (lost start).** The `df` rows commit, but the message telling
   the engine to run never lands (worker was down, connection dropped). Now there
   is a workflow "on paper" in `df.instances` that never executes.

Both come from the same root cause: **the `df` write and the engine start happen
in two different transactions, with nothing reconciling them afterward.**

## The approach

Stop trying to force both writes into one transaction, and stop reaching into the
engine's internal SQL. Instead, treat the committed `df` row as the **source of
truth (the intent)** and let the background worker converge the engine to match,
going only through duroxide's **Rust API** (`Client::start_orchestration`,
`Client::get_orchestration_status`).

`df.start()` now:

1. Writes the instance rows **and a `start_input` payload** (the vars snapshot +
   label captured at start time) into `df` — all in the caller's transaction.
2. Issues a transactional `NOTIFY pg_durable_start` (delivered **only** if the
   transaction commits).
3. Does **not** start the engine itself.

The background worker converges the engine two ways:

- **Instant path.** It `LISTEN`s on `pg_durable_start`. On a notification it starts
  the just-committed instance immediately (typically single-digit milliseconds).
- **Backstop sweep.** Every `reconcile_interval` seconds it scans for `pending`
  instances older than `reconcile_grace` that the engine still does not know about
  (`get_orchestration_status == NotFound`) and starts them. This covers a missed
  notification (worker restart, dropped connection).

Why this fixes both modes:

- **Ghost:** the engine is only ever started by the worker from a *committed* `df`
  row. A rolled-back `df.start()` leaves no row and delivers no notification, so
  nothing is ever started. No ghost is possible.
- **Stuck:** even if the instant notification is lost, the sweep eventually finds
  the committed-but-unstarted row and starts it. Convergence is guaranteed.

### Why go through the Rust API instead of the engine's SQL

The engine's SQL schema is an internal implementation detail, not its contract.
Its contract is "start an orchestration." Driving it through
`Client::start_orchestration` keeps pg_durable decoupled from how duroxide happens
to store state, and it works against any duroxide provider. The philosophical
framing (per review discussion): duroxide's model is async, at-least-once,
converge-later; Postgres's model is synchronous and transactional. pg_durable
lives on Postgres but follows duroxide's model, so it records intent
transactionally and converges the async engine afterward rather than pretending
the two can share one transaction.

### Exactly-once start

The instant path and the sweep can both notice the same instance. Start-once is
guaranteed by an atomic claim: the worker flips the row `pending -> running` with
`UPDATE ... WHERE status = 'pending' RETURNING start_input`. Only the one caller
that observes the row still `pending` proceeds to call the engine. If that engine
call fails, the claim is rolled back to `pending` so a later sweep retries.

## Schema changes (0.2.4)

- `df.instances.start_input JSONB` (nullable) — the `FunctionInput` captured at
  `df.start()` time so the worker can replay the exact start payload. Rows written
  before this column existed replay with an empty vars set.
- Added to the `df.grant_usage()` / `df.revoke_usage()` INSERT column list; the
  upgrade script backfills `GRANT INSERT (start_input)` to existing df-usage roles.

### GUCs (Postmaster-context)

| GUC | Default | Purpose |
|-----|---------|---------|
| `pg_durable.reconcile_interval` | `15` | Seconds between backstop sweeps. `0` disables the sweep (instant path stays on). |
| `pg_durable.reconcile_grace` | `300` | Minimum age a pending instance must reach before the sweep starts it. |

## Upgrade & Migration

- **Backward compatibility (B1).** The new `.so` must run against un-upgraded
  0.2.2 / 0.2.3 schemas that lack `start_input`. `df.start()` gates on the
  installed extension version: `>= 0.2.4` uses the new intent path; older uses the
  legacy inline start. The worker checks for the `start_input` column before
  running any reconciliation, and re-checks it on each sweep so an in-place
  `ALTER EXTENSION UPDATE` (which does not restart the worker) enables
  reconciliation mid-epoch. The `LISTEN` is always established because `df.start()`
  only sends the notification once the column exists.
- **Upgrade script.** `sql/pg_durable--0.2.3--0.2.4.sql` adds the column (appended
  last, matching the fresh-install column order), updates the grant/revoke, and
  backfills the column grant to existing df roles.
- **No duroxide schema change** — this feature only uses the duroxide Rust API, so
  it requires no changes to the embedded duroxide migrations.

## Scope

This change fixes the **start** direction (df has it, engine does not). The reverse
directions (`df.cancel()` / `df.signal()` rollback leaks, or engine-has-it /
df-does-not orphan cleanup) are out of scope and remain on the existing client
path.

## Testing

`tests/e2e/sql/25_reconcile_start.sql` exercises both failure modes end-to-end:

- **Scenario 1 (ghost):** `BEGIN; SELECT df.start(...); ROLLBACK;` then assert the
  duroxide runtime has no residue for that instance. (Verified RED on `main`.)
- **Scenario 2 (stuck):** commit a backdated `pending` instance directly (no
  notification), then assert the worker's sweep starts and completes it.
