# Wait For Condition Specification

**Status:** Proposal
**Date:** 2026-08-19
**Target version:** 0.2.6 (unreleased)
**Related:** [spec-failure-policy.md](spec-failure-policy.md)

## Overview

Today the only way to trigger recurring work is `df.wait_for_schedule()` with a
cron expression, so you have to guess a rate.

Take the background compactor for a bm25 index. Writes land as small segments,
and queries slow down until something merges them. The work is due when the
segment count crosses a threshold, which has nothing to do with the clock. Run
the merge every minute and almost every run finds nothing to do. Run it hourly
and the index stays bloated in between.

`df.wait_for_condition()` waits on a SQL predicate instead of a clock. It
re-checks on a backstop interval, and an optional `NOTIFY` from whatever
changes the data makes it fire sooner.

## Background

PostgreSQL has one push mechanism reachable from SQL: `LISTEN`/`NOTIFY`, sent
with `pg_notify()`. It is transactional, delivered at commit and discarded on
rollback. It reaches only the sessions listening at that moment and is never
replayed, so a notification sent while nothing is listening is gone. Triggers
are the usual place to call it from, having no way to signal anything
themselves.

The durable alternative is an ordinary table. A producer can record the change
in the same transaction that makes it, and the row survives a restart, but
nothing pushes, so something has to poll for it. Nothing else in core closes
the gap: logical replication slots are durable and also pull-based, and neither
advisory locks nor background worker latches can carry a notification from
ordinary SQL. No primitive is both durable and prompt.

## API

The compactor written as a condition instead of a schedule. The `tp_` functions
belong to pg_textsearch; pg_durable only ever sees opaque SQL.

```sql
SELECT df.start(
    @> ( df.wait_for_condition(
             $$SELECT count(*) > 8 FROM tp_segments('docs_idx')$$,
             max_check_interval => '1min',
             notify_key         => 'tp:segments_changed:docs_idx')
         ~> df.sql($$SELECT tp_force_merge('docs_idx')$$) ),
    'compactor');
```

**Parameters:**
- `condition` - SQL returning exactly one boolean column. See Predicate rules
  below.
- `max_check_interval` - Required. The longest the node will go without
  re-checking. A notification triggers a check sooner. Must be at least
  1 second.
- `notify_key` - Optional. Any string the waiter and the producer agree on.
  Without it the timer is the only thing that triggers a check.

To make it fire sooner, notify from wherever the data changes:

```sql
SELECT pg_notify('pg_durable_condition', 'tp:segments_changed:docs_idx');
```

Both sides just have to use the same string. Naming it after the data lets
unrelated waiters share one key. Several workflows might watch a `jobs` table,
one for a high-priority job appearing and another for the backlog passing a few
hundred; a single `jobs_changed` on the insert path wakes both, and each
applies its own predicate. Naming it after the condition works too.

Nothing validates the string. If the producer never notifies, or spells the key
differently, the wait falls back to `max_check_interval` with no error.
pg_durable can't derive the key or install the trigger for you, because the
predicate is opaque SQL.

### Filtering on the producer side

Notifying isn't free on either end. Committing a transaction that issued
`NOTIFY` takes a cluster-wide `AccessExclusiveLock` on PostgreSQL 15 through
18, serializing it against every other notifying commit in the instance. A
per-row trigger on a heavily written table puts every write behind that lock.
And every notification costs the waiter a predicate evaluation, so notifying
per flush during ingest checks far more often than the backstop would.

So notify where segments are flushed rather than per row, and filter before
notifying.

```sql
IF (SELECT count(*) FROM tp_segments('docs_idx')) > 8 THEN
    PERFORM pg_notify('pg_durable_condition', 'tp:segments_changed:docs_idx');
END IF;
```

That duplicates the threshold, which is safe as long as the producer's filter
is looser than or equal to the predicate. Notify too often and you pay a wasted
re-evaluation; notify too rarely and the condition waits for
`max_check_interval`.

A producer that filters is reporting the condition rather than the data, so
`tp:compaction_due:docs_idx` fits better at that point, at the cost of no
longer suiting a waiter with a different threshold. Where several waiters share
a key, filter on the loosest of their conditions.

### Predicate rules

The predicate is evaluated as `(<condition>) IS TRUE`, so PostgreSQL's scalar
subquery rules apply: one boolean column, no rows or NULL reads as false, more
than one row is an error. Use `SELECT EXISTS (...)` for existence checks rather
than `SELECT true FROM t WHERE ...`, which starts erroring as soon as two rows
match.

That also rejects what `df.if()` would coerce. `df.if()` reads
`SELECT count(*)` as true for any nonzero count, tolerable for a branch
evaluated once but not for a predicate that would then fire on every check and
never stop. `IS TRUE` rejects it during parse analysis, before the condition
runs.

The predicate runs with `default_transaction_read_only`, so a condition with
side effects fails instead of performing them a million times. The activity
uses the extended query protocol, one statement per call, and the subquery
wrapper narrows it further: anything that isn't a single `SELECT` fails to
parse.

The condition has to describe a state that persists until the work runs. Every
check re-reads the predicate, so a condition that goes true and then false
again between checks is missed entirely, notification or not. "More than eight
segments" persists until something compacts them. "A segment was just written"
doesn't.

### Choosing max_check_interval

There is no default. You have to state how stale you're willing to let the
condition get, because we can't guess it and a bad guess is invisible. The
floor is one second, which `LOOP_MIN_ITER_DURATION` enforces anyway by holding
every loop iteration to a second of wall clock.

A check is one timer plus one `execute_sql`. At 5 seconds a single waiter runs
17k checks a day, negligible for a row-existence test. Raise it if your
predicate is expensive.

With a `notify_key` the interval is only a safety net for conditions that
become true without anyone notifying: another writer, a restore, a producer
whose filter is stricter than the predicate. Minutes are reasonable there, and
cost fewer checks and fewer continuations.

## Behavior

The node registers and subscribes before it evaluates, so the two overlap:
evaluation catches anything that became true earlier, the subscription catches
anything from then on, and nothing falls between them.

A condition that is already true fires without waiting. If it's false, the node
waits for whichever comes first: an event raised from a matching `NOTIFY`, or
`max_check_interval`. Then it evaluates again. It returns
`{"condition_met": true}`, in the same style as `df.wait_for_schedule()`
returning `{"scheduled": true}`.

Two properties of duroxide 0.1.30 make that ordering work.
`ctx.dequeue_event()` emits its action when the future is created rather than
when it's awaited, so the subscription is durable before the predicate runs.
And it's a mailbox, so an event arriving while the instance isn't parked is
buffered until consumed, and unconsumed events survive `continue_as_new` (up to
100, past which the oldest are dropped with a warning). `schedule_wait` would
discard both.

A third property decides how the loop holds its subscription. Naively,
recreating the subscription each iteration also works: the one created before a
predicate that returns true is dropped at `break`, and the one that loses
`select2` to the timer is dropped too, and neither loses a buffered
notification, because `DurableFuture::drop` marks the token cancelled and
duroxide skips cancelled subscriptions when matching arrivals in FIFO order.
But it's the wrong shape. Each recreation writes a subscribe/cancel pair to
history, and duroxide computes an arrival index by scanning every prior
subscription for that name, so a long wait becomes quadratic in the number of
checks. Instead the node holds one subscription across iterations and recreates
it only after it has actually delivered. Measured over 34 checks, that takes a
condition wait from 6 history events per check to 4 and from 35 subscriptions
to 1.

`DurableFuture` is `Unpin`, so `&mut fut` is itself a future and the
subscription survives the `select2` that borrows it.

One loss window remains: a notification sent while the worker is reconnecting
is gone before duroxide sees it. So the contract is the backstop. The condition
fires within `max_check_interval` of becoming true, which is the latency to set
for the case where no notification arrives, whether because the worker was
reconnecting, the producer filtered too aggressively, or whatever made the
condition true doesn't notify at all.

The predicate runs as `submitted_by` through the existing `execute_sql`
activity. A predicate that errors is an ordinary node failure, so the
`on_failure` policy in the failure policy spec applies unchanged.

### Bounded history

Each check appends a timer and an activity to duroxide history, and history is
replayed on every event, so waiting in place forever at a short interval would
grow history without bound.

So it doesn't. After 100 checks the node abandons the current loop iteration,
using the same unwind the failure policy spec introduces. The loop continues as
new, history is truncated, and the node re-evaluates on entry. At a 5-second
interval that's one continuation every 8 minutes.

The cost is a short window during the continuation with nothing registered to
receive a notification. Nothing is lost: the node registers and evaluates again
on re-entry, overlapping the same way it does on first entry. Continuations are
unbounded, since the failure policy spec removes `MAX_LOOP_ITERATIONS`.

## Registry and worker

Waiting itself needs no state: `ctx.dequeue_event()` is a single history entry
that can block indefinitely without holding resources. State is needed only to
route a notification to the instances waiting on it.

```sql
CREATE TABLE df.condition_waiters (
    instance_id TEXT NOT NULL,
    node_id     TEXT NOT NULL,
    notify_key  TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now(),
    PRIMARY KEY (instance_id, node_id)
);

CREATE INDEX idx_condition_waiters_notify_key ON df.condition_waiters(notify_key);
```

`instance_id` is the duroxide instance id from `ctx.instance_id()`, not the
8-char `df` instance id. A node inside a loop body runs in a subtree child
instance, whose id `subtree_instance_id()` composes as
`{parent}::{execution}::{root_node}`. The `df` instance id is the first `::`
segment, which is what the cleanup sweep matches on.

A row exists only while a wait with a `notify_key` is outstanding, and a wait
without one registers nothing. That is also what keeps the mailbox short: while
the loop body is running there is no row, so no event is raised.

Registration and removal are two new activities. The node registers, creates
the wait future, then evaluates, and removes the row once the predicate is
true. Both are idempotent (`ON CONFLICT DO NOTHING`, delete by primary key), so
at-least-once execution is harmless.

### Listener

The worker holds one `sqlx::postgres::PgListener` on the single channel
`pg_durable_condition`, for the extension database. One fixed channel means the
worker never has to issue `LISTEN` or `UNLISTEN` as waiters come and go; it
filters on the payload instead.

`PgListener` is a protocol-level client over host/port, which is what makes
this work at all: a background worker that issued `LISTEN` through SPI would
get only a latch wake, with the payload logged rather than delivered.

On a notification with payload `K`, the worker selects waiters where
`notify_key = K` and calls `client.enqueue_event(instance_id, 'df:condition:'
|| K, '')` for each. It must be `enqueue_event`, not `raise_event`:
`ctx.dequeue_event()` consumes `WorkItem::QueueMessage`, which only
`enqueue_event` produces, and only that path gives the mailbox buffering the
ordering argument above depends on. `raise_external_event()` is doubly wrong,
since it also fans out to child instances. That's signal semantics.

The worker wakes on the first notification for a key, then suppresses that key
for one second. An idle system gets its wake immediately; a system notifying
thousands of times a second still evaluates each predicate at most once a
second. That costs no trigger latency, since `LOOP_MIN_ITER_DURATION` already
stops a loop from firing more than once a second, and it bounds the cost of an
unfiltered producer. The suppression map drops entries older than the window,
so an unbounded stream of distinct keys doesn't grow it.

On reconnect the worker wakes every registered waiter.
Notifications during the gap can't be recovered, and this bounds the catch-up
to the number of waiters rather than leaving every one of them to its backstop.

### Cleanup

The existing reconcile sweep (`src/worker.rs`, `pg_durable.reconcile_interval`)
deletes waiter rows whose instance is no longer running, so a cancelled or
crashed instance can't leak rows.

### notify_key is not a permission

Any role can `pg_notify` any payload. The worst that does is re-evaluate a
predicate early, which is what the backstop does on its own schedule anyway.
Don't treat `notify_key` as an access control boundary.

### Out of scope

One listener, on the extension database. Condition waits against other
databases are not covered here; see `docs/multi-database.md` for the existing
constraint that the duroxide runtime is tied to a single database.

## Upgrade & Migration

Unlike the failure policy spec, this one changes the `df` schema. Add to
`sql/pg_durable--0.2.5--0.2.6.sql`:

1. `CREATE TABLE df.condition_waiters` and its index, copied from the
   pgrx-generated fresh-install DDL so Scenario A sees identical fresh-install
   and upgrade schemas.
2. `CREATE FUNCTION df.wait_for_condition(...)`. It's a new function, so
   nothing needs dropping.
3. Drop and re-add `nodes_node_type_chk` and `nodes_structure_chk` to admit
   `WAIT_CONDITION`. Both are `NOT VALID`, so this doesn't rewrite existing
   rows.

The node type also has to be registered in `VALID_NODE_TYPES` (`src/types.rs`),
which is the canonical list the DDL mirrors, and in `src/explain.rs`. Missing it
from `VALID_NODE_TYPES` fails quietly rather than loudly: `Durofut::ensure()`
falls back to treating an unrecognized node's JSON as a plain SQL string, so the
graph builds and only misbehaves at run time.

**B1 (new `.so`, un-upgraded schema):** a pre-0.2.6 schema has no
`df.condition_waiters`. The registration activity probes
`information_schema.tables` (caching the result, re-probing while absent so an
in-place `ALTER EXTENSION UPDATE` is picked up) and continues without
registering, and the listener and cleanup sweep tolerate the table being
absent. `notify_key` then does nothing and the wait falls back to the interval
alone. The backstop is the contract, so a customer who never upgrades gets a
working, slower trigger.

**Replay of in-flight instances:** `df.wait_for_condition()` doesn't exist
before 0.2.6, so no in-flight instance can contain one. Nothing to preserve.
The predicate does reuse the existing `execute_sql` activity, though, so the
`read_only` flag it adds to that activity's input must be omitted from the
serialized form when false. Otherwise every pre-existing history would replay
against a changed activity input.

## Testing

**Unit** (`./scripts/test-unit.sh`):
- `max_check_interval` is required; omitting it is an error and a value below
  1 second is rejected. A valid interval round-trips into the node config.
- `notify_key` is optional and absent from the config when omitted.
- The node config serializes and deserializes with the predicate intact.
- `df.condition_waiters` has the expected columns and an index on `notify_key`.
- The `read_only` flag is absent from a serialized `execute_sql` input when
  false and defaults to false when missing.
- Notification suppression: the first notification for a key wakes, a repeat
  inside the window does not, a repeat after it does, keys are independent, and
  stale entries are evicted.
- The check interval rejects zero and negative values, which a hand-written
  node could carry and which would otherwise widen into an infinite timer.
- `condition_met` reads the wrapped boolean and rejects a missing, null, or
  non-boolean value, since `(<condition>) IS TRUE` can never produce one.

**E2E** (`tests/e2e/sql/67_wait_for_condition.sql`):
1. **Already true.** The predicate is true at start. The node completes without
   waiting a full interval.
2. **Becomes true.** Another statement makes the predicate true. The instance
   parks first, then completes, with no notification involved.
3. **Notification accelerates.** `max_check_interval => '5min'` with a
   `notify_key`. The waiter row appears while parked, a `pg_notify` completes
   the instance in seconds — proving the notification path fired rather than
   the backstop — and the waiter row is gone afterwards.
4. **Second notification.** The same shape, but the first `pg_notify` arrives
   with the predicate still false. The instance must stay parked, then complete
   on a second `pg_notify` — the case that fails if the node consumes its
   subscription without recreating it.
5. **Writing predicate.** A condition containing `INSERT` fails the node rather
   than writing a row.
6. **Non-boolean predicate.** `SELECT count(*)` fails the node rather than
   being coerced the way `df.if()` would coerce it.

The producer's write and its `pg_notify` have to be their own top-level
statements. Inside the `DO` block that polls for completion they would not
commit until the block ended, so the worker would never see either.

Deferred with the failure-policy work: a broken predicate under
`on_failure => 'continue'`, and the bounded-history unwind, both of which need
that spec's mechanism.
