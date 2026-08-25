# Node Failure Policy Specification

**Status:** Implemented in 0.2.7
**Date:** 2026-08-19 (revised 2026-08-23 against the code)
**Target version:** 0.2.7 (unreleased). The design was written against an
unreleased 0.2.6; that version shipped on 2026-08-23 (tag `v0.2.6`), so the
work lands in 0.2.7 and every "0.2.6" boundary below reads 0.2.7.
**Related:** #155 (resilience gap); the wait-for-condition design

## Overview

Nothing is retried today, and one failed node fails the whole instance. Any
workflow that runs long enough will hit a deadlock, a lock timeout, or a
dropped connection. A background compactor for a bm25 index, meant to run
indefinitely, gets marked `failed` on the first bad night, and nothing runs
again until a human notices.

This adds retries, and a policy for what happens when retrying doesn't help.
The policy only matters inside a loop, since a loop is the only case where the
workflow has somewhere to go other than `failed`.

## API

Three new arguments on `df.start()`. The example is that compactor: every five
minutes it merges the index's segments and records what it merged.

```sql
SELECT df.start(
    @> (
        df.wait_for_schedule('*/5 * * * *')
        ~> df.sql($$SELECT tp_force_merge('docs_idx')$$) |=> 'merged'
        ~> df.sql($$UPDATE compaction_log SET last_run = now(), segs = $merged$$)
    ),
    'compactor',
    max_attempts => 5,
    max_backoff  => '16s'::interval,
    on_failure   => 'continue'
);
```

**Parameters:**
- `max_attempts` - Tries per node, including the first. Defaults to `1`.
- `max_backoff` - Cap on the delay between tries. Defaults to `'16s'`. Taken as
  an `interval` and converted with pgrx's `Interval::as_micros()`, which counts
  a month as 30 days, so the conversion is deterministic.
- `on_failure` - What to do once the tries are spent. `'continue'` or
  `'fail'`. Defaults to `'fail'`.

The defaults reproduce the pre-0.2.7 behavior — one try, then fail the instance
— so the feature is opt-in and upgrading changes nothing. The example above
therefore has to name all three.

## Alternatives: where the policy attaches

This design puts the policy on `df.start()`, which is the coarsest of several
options. That choice was inherited from the first draft rather than argued for,
so it is set out here against the alternatives.

The DSL builds a tree: leaves are operations (`df.sql()`, `df.http()`,
`df.http_multipart()`), interior nodes are composition (`~>`, `df.loop()`,
`df.join()`), and the root is the instance. A policy can attach at any of the
three.

**A. Root — the instance. What this design implements.**

One policy set once and inherited by every node, propagated through
`ExecutionContext.retry` and `SubtreeInput.retry`. There is one place to look
and nothing to thread through the DSL. The cost is a single lever for the whole
graph: a flaky vendor API and a local `INSERT` are treated identically, and
nested loops cannot differ from each other.

**B. Leaf — the individual node.**

```sql
df.http('https://vendor.example/api', max_attempts => 10)
  ~> df.sql($$INSERT INTO local ...$$, max_attempts => 1)
```

The policy sits on the thing that actually fails, which is where the knowledge
lives. Two costs. Auto-wrap means the idiomatic form of a SQL node is a bare
string, so configuring one forces the explicit `df.sql(...)` call and gives up
the terser form. And a graph with thirty SQL nodes that should all retry has to
say so thirty times. Only the three node types that perform I/O would take the
arguments; the other nine are control flow, sleep, and signal, and a
`max_attempts` on `df.sleep()` would mean nothing.

**C. Interior — a scoped region.**

A wrapper setting the policy for everything beneath it:

```sql
df.loop(
    df.retry($$CALL fetch_from_vendor()$$ ~> $$CALL parse_response()$$,
             max_attempts => 10, max_backoff => '1 minute')
    ~> $$CALL store_locally()$$,        -- outside the region, not retried
    'SELECT more_work()'
)
```

This is the most native to a composition DSL. It reads in the same direction as
`~>`, has the shape of a `try`/`with` block, and expresses "retry this *phase*"
without annotating every leaf. It is also cheap to build: the policy is already
threaded down the tree in `ExecutionContext.retry`, so a scope node replaces
that value for its subtree and changes nothing else. Its cost is a new node type
and a third place a reader must look to know what policy a node runs under.

**D. No knobs — classify and fix the schedule.**

Retry on transient errors, never on permanent ones, with a single built-in
backoff. The SQLSTATE rules under "What does not retry" are already half of
this. The argument for going further is that most callers cannot pick good
numbers, and every knob is a way to get it wrong.

### These compose

A, B, and C are a cascade, not a contest: the instance sets a default, a region
overrides it, a node overrides that — the relationship a GUC has with a
per-statement `SET`. **A can therefore ship first without foreclosing the
others.** Adding C or B later is additive, because a narrower scope only
overrides a default that already exists, and a graph that names neither behaves
exactly as it does today.

One caveat if either is added later: a per-node or per-region policy lives in
the graph, and the graph is serialized into `FunctionInput` and `SubtreeInput`.
That is the same replay break class described under "Upgrade & Migration" — the
new fields must be omitted from the serialized form when they hold the inherited
value, or in-flight instances fail with a nondeterminism error.

### `on_failure` is a separate question

`max_attempts` and `max_backoff` answer "how hard do I try this operation",
which is a property of the operation. `on_failure` answers "what happens to the
enclosing iteration when it gives up", which is a property of the **loop**.
Fusing them onto one object is why `on_failure` has no effect outside a loop,
where the instance fails either way — recorded under "Behavior" below as a
consequence, but really a sign that the argument is attached to the wrong
thing. `df.loop(body, condition,
on_failure => 'continue')` would put it where it applies, and would let an outer
loop over batches fail while an inner loop over items skips a bad one, which A
cannot express at all.

Unlike the retry scope, this one does not compose. Moving `on_failure` from
`df.start()` to `df.loop()` after release is a breaking change to a shipped
argument, so it is worth settling before 0.2.7 rather than after.

## Behavior

A failing `df.sql()`, `df.http()`, or `df.http_multipart()` node is retried
with exponential backoff, capped at `max_backoff`, up to `max_attempts` tries.
With `max_attempts => 5` that's four delays (1s, 2s, 4s, 8s), and the cap
doesn't bind until `max_attempts` goes past 5. Succeed on any try and the
workflow proceeds normally.

When the tries run out, `'continue'` abandons the rest of the current loop
iteration and starts the next one. That's `continue` in the ordinary
loop-control sense, and the counterpart to the `df.break()` the DSL already
has.

The next iteration begins at the top of the body, so what happens next is
whatever the body starts with. In the compactor that's
`df.wait_for_schedule()`, which computes the next tick strictly after the
current time, so the failed run's tick is skipped: the `UPDATE compaction_log`
never runs, the workflow parks until the next tick, and the log correctly
records no run for that tick. A body that doesn't open with a wait re-enters
right away, held to one iteration per second by `LOOP_MIN_ITER_DURATION`.

Why abandon the whole iteration rather than skip just the failed node? In the
compactor, `tp_force_merge()` binds `$merged` and the next step writes it to
`compaction_log`. Skipping only the failed node would run that `UPDATE` with
`$merged` unbound, recording a compaction that never happened. Unwinding to the
loop means no step ever runs on a result its producer failed to compute.

With no enclosing loop there is no next iteration, so `on_failure` has no
effect: the instance fails once the tries run out either way. A one-shot
workflow behaves as it does today, with retries added.

`'fail'` moves the instance to `failed` as soon as the tries run out,
preserving the node's error. `'fail'` with `max_attempts => 1` is exactly the
pre-0.2.6 behavior.

The two work in sequence: `max_attempts` and `max_backoff` govern the retries,
and `on_failure` takes over once they're spent.

| | `'continue'` | `'fail'` |
|---|---|---|
| A retry succeeds | workflow proceeds | workflow proceeds |
| Tries exhausted, inside a loop | next iteration | instance fails |
| Tries exhausted, no loop | instance fails | instance fails |

### Removing the iteration cap

A `'continue'` policy is pointless if the loop has a deadline, and today it
does. `execute_function_graph.rs` fails any loop once `loop_iteration` reaches
`MAX_LOOP_ITERATIONS` (100,000), which at a five-minute cron is 347 days. The
constant and its check are removed.

The comment on it says it prevents runaway loops from consuming resources
indefinitely, but `LOOP_MIN_ITER_DURATION` already does that, holding every
iteration to a second of wall clock with a compensating timer. The cap runs
after that guard, so it doesn't bound the rate of anything; it just sets an
expiry. A loop that busy-spins is already rate-limited, and a loop that
legitimately runs forever gets killed with a message telling the operator to
call `df.break()`. A genuinely runaway workflow is better served by
`df.cancel()` and by watching activity, both of which work from the first
iteration rather than 27 hours in.

Watching `df.instances` alone isn't enough, though. Its `status` reads
`'running'` for a healthy eternal loop, for one blocked on a signal that never
arrives, and for one retrying a broken node forever — and `'continue'` makes
that last case reachable. So this design also adds `df.instance_activity()`, a
`LANGUAGE SQL STABLE` function over `df.instances` and `df.nodes` returning, for
each non-terminal instance, the timestamp of its last node transition, the
seconds since, its running and failed node counts, and its most recent node
error. `df.instance_activity('10 minutes')` is then "show me what has stopped
moving". It is a function rather than a view because view-level RLS
pass-through needs `security_invoker`, which is PostgreSQL 15+, while this
extension supports 13; an ordinary SECURITY INVOKER function inherits the
existing policies on both tables.

`loop_iteration` stays in `FunctionInput` and `SubtreeInput`. It still
increments and is still carried across `continue_as_new`, and it remains useful
in traces; nothing reads it for control flow any more.

### What does not retry

Retry and the `on_failure` policy cover `df.sql()`, `df.http()`, and
`df.http_multipart()`. Graph errors (unknown node type, undeserializable child,
failed graph load) fail the instance immediately under both policies. Retrying
a malformed graph can't succeed, and looping on it forever would hide the
defect.

Within those three node types the retry is *nearly* unconditional. Errors that
are a property of the statement rather than of the moment are not retried at
all, because a retry reproduces them byte for byte: SQLSTATE classes 42 (syntax
or access rule violation), 23 (integrity constraint violation), 28 (invalid
authorization), 3D (invalid catalog name), and 3F (invalid schema name). These
fail on the first try however high `max_attempts` is, and `on_failure` then
applies as usual.

Everything else is retried: classes 40, 08, 53, 57, anything unclassified, and
every `df.http()` / `df.http_multipart()` error, which carries no SQLSTATE at
all. Class 22 (data exception, e.g. division by zero) is retried deliberately —
it describes the *data*, which another node can change between tries.

Classification is by SQLSTATE, not by error text. `execute_sql` reads
`sqlx::Error::as_database_error()?.code()` and stamps `[SQLSTATE xxxxx]` into
the message before it is stringified into the activity error; the orchestration
matches on the two-character class. duroxide's
`schedule_activity_with_retry` retries every error with no predicate hook, so
the retry loop is hand-rolled — it emits the identical sequence of durable
operations (one `schedule_activity` per try, a timer between) but can break out
early. That equivalence is what preserves replay compatibility.

### Relation to df.break()

Both unwind to the nearest enclosing loop: `df.break()` exits it, a continue
starts the next iteration. The unwind passes through compound nodes, so a
failure in one branch of `df.join()` continues the iteration containing the
join.

Two consequences of routing a continue through a parallel node are worth
stating, since both are deterministic and neither is a replay hazard:

- **`df.join()` honours the first branch that carries a continue.** Branch
  results are inspected in fixed input order, so if an earlier branch returns a
  continue and a later one returns a genuine failure (a malformed graph, say),
  the iteration is abandoned and the failure is not surfaced that iteration. It
  reappears the moment the earlier branch stops continuing.
- **`df.race()` treats an exhausted branch as a completed one.** A branch whose
  retries ran out under `'continue'` returns *successfully* with a continue
  marker, so it can win the race and abandon the iteration even though the
  other branch might have succeeded; the loser is cancelled as usual. Under
  `'continue'` this is benign — the next iteration retries both — but it means
  a fast-failing branch can starve a slow-succeeding one.

### Validation

`df.start()` rejects `max_attempts < 1`, a non-positive `max_backoff`, and any
`on_failure` other than `'continue'` or `'fail'`.

## Observability

An abandoned node is recorded `failed` with its error. The instance stays
`running`.

A retried node is stamped once, after the retries settle: node status is
written by `execute_function_node_with_vars` around the whole handler, so
`df.instance_nodes()` shows `completed` for a node that failed twice and
succeeded on the third try. The individual attempts are visible in the
duroxide history and in the worker log (`~/.pgrx/17.log`), where duroxide
traces `Activity '<name>' attempt N/M failed: ... Retrying...`.

```sql
SELECT node_id, node_type, status, error
FROM df.instance_nodes('a1b2c3d4')
WHERE status = 'failed';
```

This is the cost of `'continue'`. A compactor whose target table has been
dropped keeps looping and keeps failing without ever changing status.
Monitoring has to watch for failed nodes under running instances, because a
healthy instance status no longer means a healthy workflow.

## Implementation

The retry policy travels in `FunctionInput` (`src/types.rs`, built in
`src/dsl.rs`), threaded into `SubtreeInput` so sub-orchestrations inherit it,
and carried across `continue_as_new` with the rest of the input. Inside the
orchestration it rides on `ExecutionContext` alongside `vars` and
`loop_iteration`, which is what puts it in reach of the three activity call
sites and of `build_subtree_input`.

One `RetryPolicySpec { max_attempts: u32, max_backoff_micros: i64, on_failure:
OnFailure }` type carries all three arguments, so `df.start()`,
`FunctionInput`, `SubtreeInput`, and `ExecutionContext` all thread a single
field rather than three parallel ones. It stores microseconds rather than a
`Duration` so the serialized form is a plain integer that round-trips through
history exactly.

It must not come from a GUC. Orchestration code is replayed, and a GUC read at
execution time would produce different durable operations on replay. Carrying
the policy in the recorded input is why these are per-instance arguments and
not server settings.

The three activity call sites in `src/orchestrations/execute_function_graph.rs`
move from `ctx.schedule_activity()` to `ctx.schedule_activity_with_retry()`.
duroxide 0.1.30 spells the policy as a `RetryPolicy` struct, not the
`Backoff`/`initial`/`coefficient` names this design first used:

```rust
duroxide::RetryPolicy {
    max_attempts,                       // u32, from FunctionInput
    backoff: duroxide::BackoffStrategy::Exponential {
        base: Duration::from_secs(1),
        multiplier: 2.0,
        max: max_backoff,
    },
    timeout: None,
}
```

`RetryPolicy::new()` asserts `max_attempts >= 1` and would panic inside the
orchestration, so the struct is built literally and the bound is enforced at
`df.start()`. `delay_for_attempt(n)` is `base * multiplier^(n-1)` capped at
`max`, which is the 1s/2s/4s/8s sequence above. duroxide schedules each backoff
as a durable timer, so a workflow waiting to retry survives a restart, and it
retries on any activity error (`timeout: None` means the timeout path, which is
deliberately not retried, never engages).

A new `NodeError::Continue(String)` joins `Break` and `Failure`, produced at
those three call sites when the tries run out under `'continue'`. Compound
nodes propagate it through `?` with no new code, the same way they already
propagate `Break`. Six sites match on `NodeError` explicitly and need a new
arm, in four groups:

| Site | Behavior |
|---|---|
| Loop body (`run_loop_iteration`, both the body and the while-condition arms) | Warn, discard the iteration, run the next one |
| Node status (`execute_function_node_with_vars`) | Record the node `failed` with its error |
| Subtree envelope encode (`execute_subtree`) / decode (`parse_subtree_envelope`) | New `SubtreeControl::Continue`, so it crosses the sub-orchestration boundary |
| Top level (`execute`) | Instance `failed`, original error preserved |

The unit test at the bottom of `execute_function_graph.rs` that asserts on
`NodeError::Break` matches with a catch-all `other =>` arm and compiles
unchanged; it is not one of the six.

`run_loop_iteration` needs no signature change. It already returns
`Result<Option<...>>`, where `Ok(None)` means "run the next iteration", so a
`Continue` is handled by tracing a warning and returning `Ok(None)` from both
arms. The while-condition is deliberately *skipped* when the body continues,
rather than being evaluated against a half-finished iteration: the condition
typically reads named results (`$extracted.count`) that the abandoned iteration
never produced, so evaluating it would replace a clear "this iteration failed"
with an unrelated substitution error. The consequence, which the Observability
section states outright, is that a `while` loop whose body fails on every
iteration never terminates.

`MAX_LOOP_ITERATIONS` and the `next_iteration >= MAX_LOOP_ITERATIONS` check in
`execute_loop_node` are deleted. The constant has no other reader, so it goes
with the check rather than being left behind unused. The doc comment on
`FunctionInput::loop_iteration` in `src/types.rs` says "Used to enforce a
maximum iteration safeguard" and needs updating with it.

## Upgrade & Migration

No `df` table changes. The policy lives in duroxide history, not in
`df.instances`.

`df.start()` gains three defaulted arguments, which changes its signature.
Follow the `transaction_mode` precedent in `sql/pg_durable--0.2.4--0.2.5.sql`:

1. Bump `Cargo.toml` to `0.2.7` and create `sql/pg_durable--0.2.6--0.2.7.sql`
   (the 0.2.6 release is already tagged, so 0.2.6's own upgrade script is
   immutable).
2. Add a Rust `start_v3` bound to `start_v3_wrapper`. Keep `start_v2` as
   `#[pg_extern(sql = false)]` so it emits no DDL but keeps its symbol —
   dropping its `name`/`schema` attributes and its `default!()` wrappers, the
   way `start()` was reduced when `start_v2` superseded it.
3. In `sql/pg_durable--0.2.6--0.2.7.sql`, drop
   `df.start(text, text, text, text)` and create the seven-argument function
   from the pgrx-generated DDL, copied verbatim so Scenario A sees identical
   fresh-install and upgrade schemas.
4. Add a "v0.2.6 → v0.2.7" section to `docs/upgrade-testing.md`.

The overloads can't coexist. With defaults on both, a four-argument call
matches both signatures and PostgreSQL raises "function is not unique".

**B1 (new `.so`, un-upgraded schema):** a 0.2.5/0.2.6 schema declares
`df.start(text, text, text, text)` against `start_v2_wrapper` and keeps
resolving to it (and a pre-0.2.5 schema its three-argument `start_wrapper`).
Those instances run `'fail'` and don't expose the new arguments.

**`transaction_mode => 'new'`:** that path re-issues the start on a loopback
session, and `client::start_on_new_session` deliberately calls
`df.start($1, $2, $3)` with three positional arguments so it also resolves on
pre-0.2.5 schemas. The retry arguments have to reach the inner start, but
adding them unconditionally would break that resolution under B1, where
`start_v2` is still the entry point. So the policy is passed as an `Option`:
`None` (the `start_v2` entry point) keeps the existing three-argument
statement verbatim, and `Some(policy)` — only reachable through `start_v3`,
which only exists on a 0.2.7+ schema — issues
`df.start($1, $2, $3, 'caller', $4, $5, $6)`.

**Instances started after an upgrade:** a caller who upgrades and keeps using
the four-argument `df.start()` resolves to the new function but picks up
defaults of `max_attempts => 1, on_failure => 'fail'`, which is exactly what
the four-argument function did. Nothing changes without an explicit opt-in.
This is deliberate: silently converting every existing workflow's fail-fast
semantics into retry-and-continue is not a change a caller should discover in
production. It is also why the existing E2E suite needed no edits — the five
tests that assert a node failure still see one.

**Replay of in-flight instances:** the new `FunctionInput` and `SubtreeInput`
fields are `#[serde(default)]`, defaulting to `'fail'` with
`max_attempts = 1`, so instances started by the old binary keep their old
behavior. The first attempt of `schedule_activity_with_retry` records the same
history operation as `schedule_activity` (duroxide's retry helper simply calls
`schedule_activity` in a loop, adding a timer only between attempts), so
existing activity histories replay unchanged.

A serde default alone is *not* sufficient, and the first draft of this design
got that wrong. A default only governs deserialization; the field is still
written on the way out, so the `execute-subtree` envelope a 0.2.7 parent emits
would no longer be byte-equal to the one a 0.2.6 parent recorded. duroxide
matches a sub-orchestration schedule with `name == en && input == ei`
(`replay_engine::action_matches_event_kind`), so that mismatch would have
failed every in-flight JOIN branch, RACE branch, and non-root loop child with a
nondeterminism error — precisely the break `docs/upgrade-testing.md` records for
v0.2.4 → v0.2.5, where adding `instance_id`, `vars`, `label`, and `iteration` to
the same envelope broke in-flight parallel branches unconditionally.

Both fields are therefore also declared
`skip_serializing_if = "RetryPolicySpec::is_legacy"`, so an instance carrying
the legacy policy serializes to exactly the pre-0.2.7 shape. The predicate keys
off the legacy value rather than `Default`, because an instance started under
0.2.7 with a real policy must still carry it into its subtrees. Two unit tests
pin both directions: a legacy envelope must contain no `retry` key, and a
non-legacy one must round-trip its policy.

Removing the iteration cap is safe on replay because it only ever turned a
continuation into a failure. An in-flight loop past 100,000 iterations would
already have failed under the old binary, so there is no history in which the
old code continued and the new code doesn't.

## Testing

**Unit** (`cargo test --features pg17 --no-default-features --lib`, and
`./scripts/test-unit.sh` for anything needing a live backend):
- Argument validation: `max_attempts < 1`, non-positive `max_backoff`, unknown
  `on_failure`. Validation is factored into a plain `parse_retry_policy()` that
  returns `Result<RetryPolicySpec, String>`, so these are ordinary `#[test]`s;
  `df.start()` only turns the `Err` into `pgrx::error!`. This follows the
  repository's existing split — `pgrx::error!` paths themselves are asserted
  from SQL (see `55_start_transaction_mode.sql`), not with `should_panic`.
- Backoff sequence derivation, including the `max_backoff` cap. This asserts on
  duroxide's `BackoffStrategy::delay_for_attempt`, pinning the sequence this
  design promises (1s, 2s, 4s, 8s) to the policy we actually construct.
- `FunctionInput` and `SubtreeInput` deserialize from pre-0.2.7 JSON with no
  retry field, yielding `'fail'` and `max_attempts = 1`. `SubtreeInput` is
  private to `execute_function_graph.rs`, so its test lives in that file's
  existing `#[cfg(test)] mod tests`, next to the break-propagation test.
- Round-trip: a `RetryPolicySpec` survives serialization into `FunctionInput`
  and back, so `continue_as_new` cannot silently reset the policy.

**E2E** (`tests/e2e/sql/68_failure_policy.sql` — 67 was taken by a branch in
flight):
1. **Transient recovery.** A node fails twice, then succeeds; the instance
   completes and the attempt count is exactly 3.
2. **Continue.** A loop whose body fails through the first iteration and
   succeeds in the second. The instance completes, the attempt count shows the
   abandoned iteration's tries, and the node downstream of the failure ran only
   once — proving the rest of the failing iteration was skipped.
3. **No enclosing loop.** A one-shot under `'continue'` runs out of tries and
   fails, the original SQL error surfaces in the instance output, and
   `df.instance_nodes()` reports the node failed.
4. **Fail.** `on_failure => 'fail', max_attempts => 1` inside a loop fails the
   instance after exactly one attempt.
5. **Defaults are legacy.** A plain `df.start()` with no policy arguments, on a
   loop whose body always fails, fails the instance after exactly one attempt —
   pinning "upgrading changes nothing" as a test rather than a claim.
6. **Validation.** `max_attempts => 0`, a negative `max_backoff`, and an
   unrecognised `on_failure` are each rejected by `df.start()`.

Plus `tests/e2e/sql/69_instance_activity.sql` for the monitoring function: a
busy instance is listed with a live `last_activity_at`; the `idle_for` argument
filters; a loop wedged under `'continue'` surfaces a non-zero
`failed_node_count` and its `last_error` while still reporting `'running'`;
terminal instances are excluded; and a second role sees none of it.

Attempts are counted with a **sequence**, not a counter table: the failing
attempt's transaction rolls back, taking any row it inserted with it, whereas
`nextval()` is non-transactional and survives. `SELECT 1 / (CASE WHEN
nextval('s') >= 3 THEN 1 ELSE 0 END)` both counts the attempt and decides
whether it fails, and `last_value` afterwards is an exact attempt count.

Retries cost wall clock and the E2E await helper gives up well before the
defaults would finish, so every case pins `max_attempts` (1, 2, or 5) and
`max_backoff => '1 second'`.

Two cases from the original plan are **not** covered by E2E. A graph-level
error (unknown node type) cannot be constructed through the DSL — the
`nodes_node_type_chk` constraint rejects it — so the "not retried" guarantee
for graph errors rests on where `NodeError::Continue` is produced (only the
three activity call sites) rather than on a test. The old iteration cap
likewise has no E2E: `loop_iteration` is an orchestration-input field with no
SQL surface, and its removal is a deletion with nothing left to assert against.

**Existing tests that assert a failure must opt out of the new default.** Five
E2E tests (`13_user_isolation`, `14_database`, `45_connection_limit_timeout`,
`61_loop_child_start_failure`, `64_loop_branch_failure`) were written when the
first node error was fatal. Under the new defaults they either time out waiting
for a failure that is still being retried, loop forever under `'continue'`, or
— in the connection-limit case — succeed on the retry. Each now passes
`max_attempts => 1, on_failure => 'fail'`, which is both the correct expression
of what they test and the first real use of the escape hatch the release notes
recommend.
