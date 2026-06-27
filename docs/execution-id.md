# Execution IDs for Node State

## Principles

Each node row is written by a **single writer** (the orchestration that owns it). We keep changes **minimal**, and we **never materialize** implicit states (`skipped`, `cancelled`): they are *derived* at read time. This avoids extra writes, write contention, and conflict resolution.

## 1. `execution_id`

An `execution_id` is the **sub-orchestration path** from the root to the orchestration that last wrote a node, with an **execution number** per segment:

```
root:3:loopA:4:branchC:1
```

- A segment is added **only at a sub-orchestration boundary** — a loop iteration, or a join/race branch. Plain nodes (SQL, IF, sequencing, …) inherit their owning orchestration's `execution_id`; the path is therefore *coarser* than the full graph.
- Execution numbers: **1** for join/race branches; **1..N** for loop iterations (one per `continue_as_new`); the root counts root-level loop iterations.
- Two `execution_id`s that can ever write the **same** node share identical segment *identities* and length — they differ only in the **numbers**. This makes them **totally ordered**: at the first segment whose number differs, the larger number is more recent (“supersedes”).

## 2. `status_detail` column

Add `status_detail` to `df.nodes`. On every status write, the owning orchestration stamps the node's current `execution_id` there.

*(Incidental cleanup, not core to this proposal: `status_detail` lets us drop the unused `error` column and stop overloading `result` for non-result data.)*

## 3. Most-recent-execution wins

The status update becomes a **fenced conditional write**: apply only if the incoming `execution_id` is **not superseded** by the one already stored (`incoming >= stored`). A stale writer — e.g. a race loser still draining, or a previous loop iteration — cannot clobber a newer execution's state, and the row converges to the most-recent execution regardless of arrival order. The write stays single-writer-*effective* and order-independent; the orchestration never branches on whether the write landed.

## 4. Monitoring: it's enough for both tree walks

With `status` + `status_detail`, plus what we already store (the IF decision in `result`, and the race winner on the race node), a single `SELECT` of an instance's nodes supports both directions:

- **Leaf → root:** climb a node's ancestors; the first ancestor whose `execution_id` is not a prefix of the node's tells you the node's *effective* state (ancestor failed ⇒ skipped; running ⇒ pending in a new execution; completed ⇒ branch/iteration not taken ⇒ skipped).
- **Root → leaves:** descend carrying the live lineage; decisions at IF/RACE/LOOP paint whole sub-graphs at once (not-taken ⇒ skipped, race loser ⇒ cancelled, under-failure ⇒ skipped, unreached ⇒ pending).

Intuitively: structure tells you *what could run*, and `execution_id` tells you *which execution each node's status belongs to* — together enough to color the current state of **every sub-graph**, with no materialized transitions.

## Out of scope / dependencies

- **Loop boundary**: requires loops to run as a sub-orchestration rooted at the loop node so iterations get a clean `execution_id` segment — see separate note.
- **Race winner**: the root→leaves walk needs the race node to record its winning branch (small add if not already present).
- **Representation & upgrade**: `execution_id` ordering can be stored in a comparable form (implementation detail); `status_detail` is a new nullable column and the fenced `UPDATE` is compatible with pre-existing rows.
