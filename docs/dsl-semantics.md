# pg_durable DSL — Operational Semantics

**Status:** normative contract. This document defines the *intended* runtime behaviour
of every DSL combinator, especially under nesting. It is the acceptance contract for
the structural-invariant oracle (issue #232 Phase 1) and the reference interpreter
(Phase 5), and it states explicitly the nesting contracts that bugs
[#227](https://github.com/microsoft/pg_durable/issues/227) and
[#230](https://github.com/microsoft/pg_durable/issues/230) violate.

For surface syntax/precedence see [grammar.md](grammar.md). This document is about
*meaning*, not parsing.

---

## 1. Execution model

A `df.start(expr, label)` call parses `expr` into a **function graph**: an immutable
tree of nodes persisted in `df.nodes`, rooted at `df.instances.root_node`. A background
worker then executes the tree to completion using the [duroxide](https://github.com/microsoft/duroxide)
durable runtime (`src/orchestrations/execute_function_graph.rs`).

Execution threads two environments through the tree:

| Environment | Symbol | Mutability | Flow |
|-------------|--------|------------|------|
| **Variables** | `V` | **immutable** for the life of the instance; captured from `df.setvar` at `df.start` time | passed *into* every node and sub-orchestration unchanged; never written back |
| **Named results** | `R` | **mutable**, forward-flowing | a node bound with `|=>`/`df.as` writes `R[name] := result`; later nodes read `$name` |

Substitution happens **at execution time**: `{name}` reads `V`, `$name` reads `R`,
plus system vars (`$df.instance_id`, etc.). A read of `$name` before the producing node
has run is an error.

### Node lifecycle

Every node row carries exactly one status from this set (CHECK constraint, `src/lib.rs:251`):

```
pending  →  running  →  completed
                     ↘  failed
```

- `pending` — created but not yet started (**includes nodes that are never reached**:
  the untaken `IF` branch, a `RACE` loser, the body of a loop that breaks before
  re-entering). There is **no** `skipped`/`cancelled` *node* status.
- A `df.nodes` row is **current state**, written in place by the `update-node-status`
  activity (`src/activities/update_node_status.rs`). It is **not** an append-only trace.
  On loop re-entry (`continue_as_new`) the body's nodes are re-executed and each node row is
  **overwritten in place as that node runs again** — there is **no blanket reset** of the body
  to `running`. A node an earlier iteration set `completed` therefore keeps that (stale) status
  until a later iteration overwrites it; if a later iteration takes a different path the node is
  never revisited and the stale value persists. To count executions/iterations you must use
  duroxide execution history (`df.instance_executions`), not `df.nodes`.
- A node that raised `Break` is recorded **`completed`** (carrying the break value as its
  `result`), not `failed` — including the compound nodes the break unwinds through. Only
  `Failure` marks a node `failed`. `result` is non-null only when status is
  `completed`/`failed` (`nodes_result_status_chk`).

Only the **instance** (`df.instances.status`) may end as `cancelled`.

### Control signals

A node evaluation yields either a **value** (`String`, the JSON/SQL result), or one of
two errors (`NodeError`, `execute_function_graph.rs:43`):

- **`Failure(msg)`** — a real error. Propagates up, marks nodes `failed`, fails the instance.
- **`Break(value)`** — *control flow*, not an error. Unwinds (via `?`) to the nearest
  enclosing `LOOP`, which catches it and exits normally with `value`. A `Break` with no
  enclosing loop reaches the root and fails the instance.

---

## 2. Notation

We write a small-step judgement

```
⟨n, R, V⟩  ⇓  r ⊣ R'
```

read: *node `n`, under results `R` and vars `V`, evaluates to result `r` and produces
updated results `R'`.* Effects on the durable store (status writes, activity
side-effects) are noted in prose. `R` is threaded left-to-right unless stated otherwise.
`bind(n, r, R)` means: if `n` has a `result_name = name`, return `R[name := r]`, else `R`.

---

## 3. Leaf nodes

Leaves perform one durable activity, timer, or wait. Among leaves, **only `SQL`, `HTTP`,
and `SIGNAL` bind** a `result_name`/`|=>`; `SLEEP` and `WAIT_SCHEDULE` currently **ignore**
`result_name` (their handlers have no bind step), so they never write `R`.

### SQL — `df.sql(q)`, bare `'...'`
```
⟨SQL q, R, V⟩ ⇓ r ⊣ bind(SQL, r, R)
  where r = execute-sql( substitute(q, R, V) )
```
Runs the substituted query as one durable activity. `r` is a JSON envelope
(`{row_count, rows, ...}`). Side-effecting SQL runs **exactly once** per node execution
(duroxide replays the recorded result, never the query).

### HTTP — `df.http(url, method, body, headers, timeout)`
Like SQL: substitutes `url`/`body`/`headers` from `R`,`V`, performs one HTTP activity,
binds result. Result is the response envelope.

### SLEEP — `df.sleep(secs)`
Durable timer of `secs`. Result is `{"slept":true,"seconds":N}`. Never writes `R`: a
`result_name` on a `SLEEP` is silently ignored (handler has no bind step).

### WAIT_SCHEDULE — `df.wait_for_schedule(cron)`
Durable timer of a **fixed `wait_seconds` pre-computed at `df.start` (DSL) time** from the
cron expression — it is *not* recomputed against the clock at run time, so under a loop
each iteration waits the same stored delay. Result is `{"scheduled":true}`. Also ignores
`result_name` (no bind step).

### SIGNAL — `df.wait_for_signal(name, timeout?)`
Waits for an external signal raised by `df.signal(instance_id, name, data)`. With
`timeout`, races the wait against a timer (`select2`). Result:
`{signal_name, timed_out, data}`; on timeout `timed_out=true`. Binds `result_name`.

---

## 4. Sequencing — `THEN` (`~>`, `df.seq`)

```
⟨THEN a b, R, V⟩ ⇓ r_b ⊣ bind(THEN, r_b, R₂)
  where  ⟨a, R,  V⟩ ⇓ _   ⊣ R₁
         ⟨b, R₁, V⟩ ⇓ r_b ⊣ R₂
```

- `a` runs to completion first; **its `R` updates are visible to `b`** (this is how
  `|=>` then `$name` works).
- The sequence's result is **`b`'s** result; `a`'s value is discarded (but its named
  result, if any, persists in `R`). A `result_name` on the `THEN` itself
  (`df.as(seq, name)`) binds `b`'s result.
- If `a` raises `Break`/`Failure`, `b` **does not run** and the signal propagates.
- `THEN` is right-result associative: `a ~> b ~> c` ≡ `(a ~> b) ~> c` and yields `c`'s
  result with `R` accumulated across all three.

---

## 5. Conditional — `IF` (`?> !>`, `df.if`, `df.if_rows`)

```
⟨IF cond then else, R, V⟩ ⇓ r ⊣ bind(IF, r, R')
  where  b = eval-cond(cond, R, V)
         ⟨ (b ? then : else), R, V⟩ ⇓ r ⊣ R'
```

- **Exactly one** branch is evaluated. The other branch's subtree is **never reached**
  and its node rows stay `pending`.
- `df.if`: `cond` is a SQL/condition node; truthiness via `evaluate_condition`
  (boolean `true`, non-zero, non-empty first column).
- `df.if_rows`: `cond` names a prior SQL result; true iff its `row_count > 0`.
- Result is the taken branch's result; bound to `result_name` if present.
- A reachability oracle must read the recorded condition result to decide which branch
  *should* be non-`pending`; it cannot assume both children run.

---

## 6. Loop — `LOOP` (`@>`, `df.loop`)

A `LOOP` has a **body** and an optional **while-condition** (stored as `condition_node`
inside the node's `query` JSON). It is a **do-while**: the body runs, *then* the condition
is checked.

```
                  ⟨body, R, V⟩ ⇓ r ⊣ R₁           ; one iteration
LOOP step:        if  body raised Break(v):  exit LOOP with v
                  elif condition present and eval-cond(false):  exit LOOP with r
                  else:  continue_as_new(V)      ; re-enter from a fresh execution
```

- **`continue_as_new`** ends the current duroxide execution and starts the next one,
  carrying **`V` only** (`FunctionInput { instance_id, label, vars }`,
  `execute_function_graph.rs:626`). The graph is reloaded and execution restarts at
  `root_node`. Named results `R` are **not** carried across iterations.
- An infinite loop (`@>`, no condition, no break) never reaches a terminal status by
  itself; it is exited by `df.break` or by losing a `RACE`.
- Each iteration is rate-limited to a minimum wall-time (`LOOP_MIN_ITER_DURATION = 1s`,
  `:527`) so a tight loop cannot spin the worker.
- The body result `r` (or break value `v`) is the loop's result and may be bound.

### `BREAK` — `df.break(value?)`
```
⟨BREAK value, R, V⟩ ⇓ ⊥ ⊣ —     ; raises Break(value)
```
`value` is a literal JSON string (no SQL is run). It unwinds to the nearest enclosing
`LOOP`. **Outside any loop it is a `Failure`** (uncaught break fails the instance).
A `BREAK` raised inside a `JOIN`/`RACE` branch is re-raised across the sub-orchestration
boundary (`parse_subtree_envelope`, `:783`) so it still reaches the enclosing loop.

---

## 7. Parallel — `JOIN` / `RACE`

Both run each operand as a **sub-orchestration** (`execute_subtree`) scheduled with
`ctx.schedule_sub_orchestration` and receiving a clone of `R` and the same `V`. Branches
do not see each other's `R` writes while running; results merge back as described.

### JOIN (`&`, `df.join`, `df.join3`) — wait for all
```
⟨JOIN b₁..bₖ, R, V⟩ ⇓ [r₁..rₖ] ⊣ bind(JOIN, [r₁..rₖ], R ⊕ ΔR₁ ⊕ … ⊕ ΔRₖ)
```
- All `k` branches run concurrently; `JOIN` completes only when **every** branch
  completes. (`join3`/N-ary store extra operands in `query.extra_nodes`.)
- Each branch's named-result delta is merged back into the parent, **in branch order**
  (later branch wins on a key collision — so two branches should not bind the same name).
- If **any** branch raises `Failure`, the JOIN fails. If any branch raises `Break`, it
  unwinds to the enclosing loop.
- Result is the JSON array of branch results, bindable via `|=>`.

### RACE (`|`, `df.race`) — first to complete wins
```
⟨RACE b₁ b₂, R, V⟩ ⇓ r_w ⊣ bind(RACE, r_w, R ⊕ ΔR_w)
```
- Both branches start; the **first to complete** is the winner `w`. Only the **winner's**
  result and named-result delta are kept; the loser is **abandoned** (not awaited) and
  makes no further progress (see C5 for the precise guarantee and its caveats).
- A winning `Break`/`Failure` propagates. Result is the winner's result string.
- Canonical loop-escape pattern: `(@> body) | df.wait_for_signal('shutdown')`.

---

## 8. Nesting contracts (normative)

These are the properties the oracle and reference interpreter enforce. **C1 and C2 are
currently violated** by open bugs (§9).

- **C1 — Loop-body locality.** A `LOOP` iteration re-executes **only the loop's own
  subgraph**. Any node *outside* the loop (a prefix `a ~> (@> body)`, or a sibling)
  executes **exactly once per instance**, never once per iteration. Side-effecting
  prefix SQL must not re-run when the body continues.
- **C2 — Per-iteration sub-orchestration identity.** A `JOIN`/`RACE` nested inside a
  `LOOP` must derive **distinct** sub-orchestration identities on each iteration, so
  child instances from iteration *i* never collide with iteration *i+1* after
  `continue_as_new`.
- **C3 — Break scope.** `Break` is caught by exactly the nearest enclosing `LOOP`;
  uncaught `Break` is a failure. `Break` is never observable as a normal result.
- **C4 — Result-name discipline.** Within a sequential path a name is **written before
  read**. Parallel branches of one `JOIN` must not bind the same name (merge order would
  otherwise decide the winner). A `RACE` only publishes the winner's bindings.
- **C5 — Race-loser abandonment.** When the `RACE` resolves, the losing branch is
  abandoned and makes **no further progress** — verified by `23_signal_in_race.sql`, where
  the loser's post-`sleep` SQL never runs. **Caveats (do not over-assert):** a loser node
  that *already* completed before resolution stays `completed`, and a photo-finish can
  complete *both* branch roots, so "exactly one branch completed" is **not** a sound
  structural invariant. The robust property is: ≥1 branch root completes, the `RACE`
  result equals a completed branch's result, and nodes still `pending`/`running` at
  resolution never later reach a terminal state.
- **C6 — Vars immutability.** `V` is fixed for the instance; no node mutates it. Sub-
  orchestrations receive `V` unchanged and cannot write it back.
- **C7 — Reachability.** A node is `completed`/`failed` only if it is on a **taken**
  path: the taken `IF` branch, all `JOIN` branches, the winning `RACE` branch, and the
  body of a loop that ran. Unreached nodes remain `pending`.

### Invariants implied (Phase 1 oracle)

| Invariant | Source contract | Checkable from `df.nodes` alone? |
|-----------|-----------------|----------------------------------|
| `every_reachable_node_completed` | C7 | ✅ |
| `join_all_branches_completed` | JOIN, C7 | ✅ |
| `race_at_least_one_branch_completed` | C5 | ✅ |
| `race_loser_no_late_completion` | C5 | ⚠️ temporal (post-resolution) — needs an event log, not a snapshot |
| `untaken_if_branch_pending` | IF, C7 | ✅ |
| `result_name_written_before_read` | C4 | ✅ (static, from tree) |
| `single_execution_outside_loop` | **C1** | ❌ needs an execution count → `df.node_events` log or duroxide history |
| `loop_body_iteration_count_matches` | **C2** | ❌ needs an iteration count → duroxide history |

The reachability walk must follow **query-embedded children** (loop `condition_node`,
`join3` `extra_nodes`), not just `left_node`/`right_node` — reuse the walk in
`src/explain.rs` (`collect_nodes:256`).

**Loop-body soundness limitation.** Because a `df.nodes` row is current state with no
blanket reset on `continue_as_new` (§1), the strict completeness rules are **unsound for
nodes inside a loop body** and the snapshot oracle deliberately *relaxes* (scopes), rather
than enforces, them there:

- `join_all_branches_completed` — a `break` can abandon an in-flight sibling under a
  `completed` JOIN, so for a JOIN under a loop a non-`failed` (running/pending) sibling is
  accepted; only a `failed` or missing branch is still flagged.
- `untaken_if_branch_pending` — an `IF` that takes different branches across iterations ends
  with **both** branches stale-`completed`, so the "exactly one branch taken / untaken subtree
  pending" rules are skipped for an `IF` under a loop (its `condition_node` is still required
  to be completed).
- `every_reachable_node_completed` — under a loop the walk descends only into a JOIN's
  *completed* branches.

The loop's **own** `condition_node` is a child of the `LOOP` node (not of the body) and stays
strict. Nodes outside every loop are unaffected. These relaxations cost some bug-catching power
inside loops but guarantee **no false positives** on a quiesced, terminal instance.

---

## 9. Known deviations (open bugs)

- **#227 — prefix re-runs once per iteration (violates C1).** When the `LOOP` is not the
  root, `continue_as_new` restarts execution at `root_node`, so any prefix before the
  loop runs again every iteration. Intended: prefix runs once.
- **#230 — JOIN/RACE-in-loop stalls on iteration ≥2 (violates C2).** `continue_as_new`
  resets duroxide's sub-orchestration id counter, so the iteration-2 child id collides
  with iteration-1's, deduplicating to the old (already-finished) result and stalling.
  Intended: per-iteration unique child identity.

Tests written against this document should treat C1/C2 as the **expected** behaviour
(i.e. they should fail until the bugs are fixed).
