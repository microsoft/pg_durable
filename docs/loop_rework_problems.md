# Open Problems in the Loop Rework

Findings from the review of the `df.loop()` child-sub-orchestration rework in
PR #228 (`1320f65`) that are **still unresolved** on `main` as of `560a639`,
after the loop follow-up fixes in #306 (`7ee7f43`), #307 (`09e08f0`), and #311
(`560a639`).

Resolved findings are not repeated here. In particular, the follow-ups fixed
replay-deterministic map serialization, root/non-root loop semantic drift,
loop-child startup status coverage, the missing #230 regression shape, nested
and failed-loop coverage, and stale loop documentation. #311 also replaced the
dedicated loop orchestration with the shared `execute-subtree` path and stopped
reloading `df.nodes` on every loop generation.

`0.2.5` is still **Unreleased**, so replay-breaking fixes can still land inside
the drain boundary already declared for this release.

---

## Summary

Ordered by severity.

| # | Short name | Applies to | Severity | Status |
|---|---|---|---|---|
| 1 | [Loop history repeatedly persists full state](#1-loop-history-repeatedly-persists-full-state) | non-root and parallel-branch loops | 🔴 Blocking | Open |
| 2 | [Clock failures disable loop rate limiting](#2-clock-failures-disable-loop-rate-limiting) | all loops | 🔴 Blocking | Open |
| 3 | [Replay failures strand extension instances](#3-replay-failures-strand-extension-instances) | all replay-breaking changes | 🔴 Blocking | Open |
| 4 | [Node-status write failures are discarded](#4-node-status-write-failures-are-discarded) | all nodes | 🟡 Medium | Open |
| 5 | [Parent fallback stamps assume child generation 1](#5-parent-fallback-stamps-assume-child-generation-1) | cancelled or failed loop children | 🟡 Medium | Open |
| 6 | [Composed child ids block orphan reclamation](#6-composed-child-ids-block-orphan-reclamation) | loop and parallel children | 🟡 Medium | Open |
| 7 | [Stamp grammar is duplicated and fails open](#7-stamp-grammar-is-duplicated-and-fails-open) | status write fence and inference | 🟡 Medium | Open |
| 8 | [Nested loops have no cumulative iteration budget](#8-nested-loops-have-no-cumulative-iteration-budget) | nested loops | 🟡 Medium | Open |
| 9 | [Signals inherit the sub-orchestration startup race](#9-signals-inherit-the-sub-orchestration-startup-race) | non-root loops | 🟡 Medium | Open |
| 10 | [The 0.2.5 drain guidance is not an executable runbook](#10-the-025-drain-guidance-is-not-an-executable-runbook) | 0.2.4 → 0.2.5 upgrade | 🟡 Medium | Open |
| 11 | [The status-write fence holds a row lock across round trips](#11-the-status-write-fence-holds-a-row-lock-across-round-trips) | schemas with `status_details` | 🟢 Low | Open — measure before changing |
| 12 | [Status capability and inference paths repeat parsing work](#12-status-capability-and-inference-paths-repeat-parsing-work) | status writes and reads | 🟢 Low | Open — measure before changing |

---

## 1. Loop history repeatedly persists full state

**Severity: 🔴 Blocking — primarily affects non-root loops and loops inside
JOIN/RACE branches.**

The shared `execute-subtree` path removed the database reload that PR #228 did
on every child-loop generation, but it did not bound persisted input size.
Every `continue_as_new` still serializes the complete `FunctionGraph`, workflow
variables, and accumulated named-results map into the next input:

```rust
let graph_json = serde_json::to_string(graph)?;
let new_input = SubtreeInput {
    graph: graph_json,
    results: string_map_to_json(results)?,
    vars: Some(string_map_to_json(&exec_ctx.vars)?),
    // ...
};
```

The graph snapshot is also copied into every JOIN/RACE child input. A large
graph or named result is therefore persisted repeatedly across loop generations
and child histories. `MAX_LOOP_ITERATIONS` limits generations to 100,000, but
that is not a meaningful byte bound: a 1 MB carried result can still produce
storage measured in tens of gigabytes before the iteration guard trips.

Child engine records also remain until the root instance is retired. A nested
loop can create a child under each outer generation, so the retained child
population grows with execution shape even though each individual child uses
`continue_as_new`.

### Suggested fix

Design a bounded persistence model before changing runtime behavior. The design
must preserve all three named-result visibility rules: values created before a
loop are readable inside it, values created in one iteration are readable in a
later iteration, and values created inside the loop are returned to the parent.
Candidate designs include bounded external state or a delta/checkpoint protocol.
Set and test a numerical engine-storage bound as payload size and iteration count
vary; merely removing fields from the input is not sufficient.

---

## 2. Clock failures disable loop rate limiting

**Severity: 🔴 Blocking — applies to all loops.**

The one-second loop floor fails open. Both deterministic-clock reads discard
their errors in `execute_loop_node`:

```rust
let iter_started = ctx.utc_now().await.ok();

if let Some(started) = iter_started {
    if let Ok(now) = ctx.utc_now().await {
        // schedule the rate-limit timer
    }
}
```

`ctx.utc_now()` is a fallible duroxide syscall, not an infallible local clock
read. If either call fails, the orchestration immediately executes
`continue_as_new` with no compensating timer. A persistent engine/store problem
therefore removes the guard intended to prevent an empty-bodied loop from
busy-spinning, amplifying load during the failure.

### Suggested fix

Choose one fail-closed behavior: schedule a fixed durable delay through an API
that does not require a second clock read, or fail the loop with an explicit
diagnostic. Because changing the syscall sequence changes recorded history,
land the fix before `v0.2.5` or version the orchestration.

---

## 3. Replay failures strand extension instances

**Severity: 🔴 Blocking — applies to replay-breaking upgrades and code changes.**

When duroxide rejects replay as nondeterministic, the orchestration does not
re-enter `execute()`. Its normal `update_instance_status(..., "failed")`
activity therefore never runs, and the corresponding `df.instances` row can
remain `pending` or `running` indefinitely.

This is already acknowledged in `CHANGELOG.md` and
`docs/upgrade-testing.md`. The maintenance reconciliation in `worker.rs` only
removes expired rows that are already terminal and reclaims failed engine
records that have no `df.instances` row. It does not compare authoritative
engine failures with non-terminal extension rows. Consequences include:

- `df.status()` and `df.await_instance()` can wait forever.
- The row never becomes eligible for terminal retention pruning.
- Operators must recognize and cancel stale rows manually after an upgrade.

### Suggested fix

Add a reconciliation pass that identifies an authoritative duroxide terminal
failure after a short grace period and compare-and-sets the matching
`df.instances` row from `pending`/`running` to `failed`, preserving the engine
diagnostic. A normal completion or cancellation racing the sweep must win and
must never be overwritten.

---

## 4. Node-status write failures are discarded

**Severity: 🟡 Medium — applies to every executed node.**

Callers schedule `update-node-status` and discard the returned `Result` with
`let _ =`. This includes ordinary running/terminal transitions, loop fallback
stamps, and subtree startup failures. The activity now has more failure points
than a plain update: pool acquisition, transaction start, row locking, update,
rollback, and commit.

A failed status activity does not fail the owning orchestration and is not
retried by caller policy. The workflow can report success while `df.nodes`
contains stale `running` or `pending` state, and read-side inference then treats
that stale state as authoritative input.

### Suggested fix

Define bounded, idempotent retry for status writes. A legitimate supersession
fence should remain a successful no-op, while transport, transaction, and row
identity failures need distinct diagnostics. If retries are exhausted, prevent
the owning orchestration from reporting success or persist a reconciliation
marker that the worker can repair.

---

## 5. Parent fallback stamps assume child generation 1

**Severity: 🟡 Medium — affects cancelled or failed loop children that have
already continued as new.**

PR #228 moved ownership of a non-root loop node's status into its child
orchestration. The parent still needs a terminal fallback when the child never
gets far enough to stamp itself, when the child future fails, or when a live
loop loses a RACE. #307 implemented the latter two paths by constructing a
child execution stamp with a hard-coded generation 1:

```rust
let child_stamp = format!("{}::1", subtree_instance_id(ctx, loop_node_id));
```

The same assumption appears in `cancel_losing_loop_branch`. It is valid only
before the child completes its first `continue_as_new`. If the loop has reached
generation 2 or later, its node can already carry a stamp such as
`{child_instance_id}::2`. The parent's terminal `::1` write is then correctly
classified as older by `incoming_stamp_is_superseded` and fenced out. A fenced
write returns `Ok`, so the parent cannot distinguish it from an applied
terminal update; the completed parent instance can retain a physically
`running` loop node.

The existing losing-RACE test does not exercise this case. It races
`df.sleep(1)` against `df.loop(df.sleep(30))`, guaranteeing cancellation during
the first child generation, and explicitly asserts a trailing `::1` stamp.
There is no test in which a loop completes at least one `continue_as_new` before
losing the RACE.

`fail_loop_child_future` has the same stale-fallback problem. A normal child
failure usually stamps its own current generation before returning, but the
generation-1 fallback cannot repair a missing or failed child-owned stamp after
the child has advanced.

### Suggested fix

Do not synthesize a child generation the parent cannot know. Define an explicit
terminal parent-override operation, use authoritative child execution metadata
if it can be obtained without violating orchestration determinism, or record
cancellation separately from execution-lineage ownership. Any design must keep
later stale child writes from reopening terminal state. Add a regression that
lets the losing loop reach generation 2 or later, then asserts that both its
physical and inferred node statuses are terminal.

---

## 6. Composed child ids block orphan reclamation

**Severity: 🟡 Medium — affects composed loop and parallel child ids.**

**Tracking:** [#312 — Reconciler misclassifies explicitly named
sub-orchestrations as root orphans](https://github.com/microsoft/pg_durable/issues/312)

`worker::is_sub_orchestration` recognizes only ids that start with `sub::` or
contain `::sub::`:

```rust
fn is_sub_orchestration(id: &str) -> bool {
    id.starts_with("sub::") || id.contains("::sub::")
}
```

The loop/subtree code instead creates explicit child ids shaped as
`{root}::{generation}::{node}`. Those ids are classified as roots and enter
`select_orphans` when they are failed and have no `df.instances` row. The
worker truncates that candidate list to `RECLAIM_BATCH` before asking duroxide
to delete it; duroxide's root-only deletion then skips records with a parent.

This is a concrete mismatch between #263 and #283. #263 replaced pg_durable's
use of duroxide-generated child ids with explicit composed ids for JOIN/RACE;
#283 later introduced the `sub::` classifier and tests based on the obsolete
generated-id convention. PR #228 then materially increased the affected
population by putting non-root loops on the explicit child path, and #311
retained that naming model.

Once enough composed children occupy the batch, the same undeletable ids can
be selected every tick and prevent genuine root orphans from being reached.

### Suggested fix

Parse composed child instance ids and exclude them before batching. Keep
support for the legacy `sub::` forms. The parser should be shared with the
execution-stamp grammar described below so reclamation does not introduce a
third interpretation of the same lineage.

---

## 7. Stamp grammar is duplicated and fails open

**Severity: 🟡 Medium — affects node-status fencing and inferred status.**

The write and read sides still implement the composed lineage independently:

- `activities/update_node_status.rs::stamp_lineage` requires an even token
  count and parses `gen (node gen)*`.
- `node_status.rs::stamp_of` accepts any string with a numeric final token, and
  `is_superseded` recursively interprets the remaining tokens as a parent id.
- `worker.rs::is_sub_orchestration` uses substring matching instead of either
  grammar.

Malformed stamps disable protection. `incoming_stamp_is_superseded` returns
`false` when either stamp fails to parse, including malformed non-legacy data.
The current tests explicitly pin odd-token and nonnumeric stamps as “fence
disabled.” Read-side parse failures likewise produce `None`/`false`, causing
stale physical status to be shown rather than an observable error.

The unequal-depth rule is also only a convention: parent and descendant stamps
at tied generations do not fence one another in either direction, leaving the
outcome to write order.

### Suggested fix

Introduce one typed lineage module with separate entry points for execution
stamps (`{root}::{gen}::{node}::{gen}...`) and composed instance ids
(`{root}::{gen}::{node}...`). Use one supersession predicate on both fence
sides. Preserve the inert path only for an absent `status_details` column or an
explicitly recognized legacy value; malformed current-format data should fail
closed with an observable diagnostic.

---

## 8. Nested loops have no cumulative iteration budget

**Severity: 🟡 Medium — applies to nested loops.**

`MAX_LOOP_ITERATIONS` is enforced per orchestration instance. A non-root inner
loop starts in its own child and receives its own counter, while an outer loop
can spawn a new inner child under every outer generation. Two loops that each
stay under the 100,000-iteration cap can therefore produce a combinatorial
amount of work and retained child state.

The one-second floor limits the rate of each individual loop but does not place
a workflow-wide bound on nested work. The existing nested-loop E2E test proves
correctness for a small 3 × 2 case; it does not establish a resource budget.

### Suggested fix

Define whether the public limit is per loop, per nesting lineage, or per root
workflow. If a cumulative budget is intended, carry a deterministic remaining
budget into child inputs and decrement it at a clearly specified boundary.
Document the semantics and test nested loops near the limit before changing the
runtime input shape.

---

## 9. Signals inherit the sub-orchestration startup race

**Severity: 🟡 Medium — applies to `df.wait_for_signal()` inside non-root loops.**

A non-root loop body executes in an `execute-subtree` child. It therefore
inherits the existing #154 limitation: a signal raised before the child
sub-orchestration reaches `Running` is not redelivered to that child. Moving
loops behind the child boundary widened the set of workflows exposed to the
race; neither #307 nor the #311 unification changes signal delivery.

### Suggested fix

Fix #154 at the engine/sub-orchestration boundary or add a durable signal inbox
whose delivery is independent of child startup timing. Until then, document the
limitation specifically in the loop section of `USER_GUIDE.md`; upgrade/replay
notes are not sufficient guidance for authors of new workflows.

---

## 10. The 0.2.5 drain guidance is not an executable runbook

**Severity: 🟡 Medium — applies to the 0.2.4 → 0.2.5 upgrade.**

The release artifacts now correctly warn that loops and parallel branches are
replay-breaking, and the warning is attached to the open 0.2.4 → 0.2.5 upgrade
path. The planned operational half is still missing.

`docs/upgrade-testing.md` says to “quiesce and drain” or inspect/cancel stale
instances, but supplies no all-tenant query, role requirement, timeout/cancel
policy, zero-row check, worker restart verification, or post-upgrade health
check. This matters because tenant roles are RLS-scoped: a tenant can see zero
non-terminal rows while another tenant still has active work.

### Suggested fix

Add a complete administrative runbook: stop new `df.start()` submissions;
connect as the documented role that bypasses tenant isolation; list every
non-terminal instance with a static schema-qualified query; wait to a declared
timeout; cancel or defer for unfinished work; verify zero rows; apply the
extension update; restart/verify the worker; and confirm scheduling and status
health. State explicitly that tenant-scoped execution is insufficient.

---

## 11. The status-write fence holds a row lock across round trips

**Severity: 🟢 Low — measure before changing.**

On schemas with `status_details`, every node transition performs
`BEGIN → SELECT ... FOR UPDATE → application-side lineage comparison → UPDATE
→ COMMIT`. The lock is a single composite-primary-key row and there is no
nested lock acquisition, so this is not the previously documented duroxide
deadlock. It is nevertheless several round trips on every node transition,
holds a pooled connection and row lock across Rust-side work, and has no
explicit lock-timeout behavior.

The management pool is intentionally small as a DoS control and must not be
enlarged as a shortcut.

### Suggested fix

Measure status-write throughput and lock latency under concurrent stale/current
writers. Then compare the current transaction with an atomic SQL predicate or a
bounded CAS design. Preserve the exact sibling/ancestor semantics and surface a
lock/CAS timeout as a retryable activity failure.

---

## 12. Status capability and inference paths repeat parsing work

**Severity: 🟢 Low — measure before changing.**

Two small costs remain in status-heavy paths:

1. `status_details_present` caches a positive schema probe permanently, but an
   absent column is re-probed through `information_schema.columns` on every
   status write. Scenario B1 intentionally supports a new binary against an old
   schema, so this is the deployment where every node transition pays the
   metadata query.
2. `infer_statuses` parses each node's `status_details` JSON once while building
   `scope_max`, then up to twice again during the graph walk.

### Suggested fix

For the schema probe, use a bounded negative-cache expiry or an invalidation
mechanism that notices an in-place extension upgrade; a worker-lifetime negative
cache could leave the fence disabled after the column appears. For inference,
parse each stamp once into a temporary typed structure and reuse it in both
passes. Benchmark first and keep output byte-for-byte equivalent over nested
lineage fixtures.
