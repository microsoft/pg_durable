# Break-It Plan for pg_durable

> **Goal:** Systematically test pg_durable the way a real user (or adversarial user) might, finding limits, bugs, logical errors, and failure modes that aren't covered by current E2E tests.
>
> **Out of scope:** SQL injection and other security vulnerabilities (addressed separately).

## Table of Contents

1. [Testing Categories](#testing-categories)
2. [Category A: Stress & Overload](#category-a-stress--overload)
3. [Category B: Bugs & Logical Errors](#category-b-bugs--logical-errors)
4. [Category C: Misuse & Unintended Usage](#category-c-misuse--unintended-usage)
5. [Category D: Chaos / Fault Injection](#category-d-chaos--fault-injection)
6. [Category E: Data Integrity & State Corruption](#category-e-data-integrity--state-corruption)
7. [Category F: Concurrency & Race Conditions](#category-f-concurrency--race-conditions)
8. [Existing Coverage Analysis](#existing-coverage-analysis)
9. [Priority & Sequencing](#priority--sequencing)

---

## Testing Categories

"Breaking it the way a user might" decomposes into six distinct testing dimensions:

| Category | What it tests | Examples | Current coverage | Priority |
|---|---|---|---|---|
| **A. Stress & Overload** | System behavior under extreme load, large data, deep nesting | 100+ concurrent instances, 10K loop iterations, million-row results, deep graph nesting | **None** | High |
| **B. Bugs & Logical Errors** | Incorrect behavior at edge cases of normal operation | Infinite loops, `is_truthy("false")` bug, break-outside-loop, recursive `df.start()` | **Partial** (happy-path only) | **Highest** |
| **C. Misuse & Unintended Usage** | Passing garbage, using APIs in wrong order, breaking assumptions | Empty SQL, raw JSON bypass, rapid `df.status()` polling, crafted Durofut payloads | **Minimal** (2 tests: 32, 33) | Medium |
| **D. Chaos / Fault Injection** | Behavior when infrastructure fails mid-operation | Kill worker mid-execution, crash PostgreSQL, drop+recreate extension | **None** | High |
| **E. Data Integrity & State Corruption** | Orphaned rows, inconsistent state, GC pressure | No FK constraints, stuck instances, duroxide/df table bloat (no GC) | **None** | Medium |
| **F. Concurrency & Race Conditions** | Parallel sessions, competing operations on shared state | Shared variable races, concurrent start/cancel/signal, parallel status polling | **Minimal** (test 22) | Medium |

---

## Category A: Stress & Overload

These tests find resource exhaustion bugs and missing limits. The goal is to discover what happens when a user (or a runaway loop) pushes the system past its design point.

### A1. Many concurrent active instances

**What:** Start N instances simultaneously from a single session, then from multiple sessions.

**Why:** The background worker is single-threaded with a 5-connection pool. With enough instances queued, the worker may fall behind, the connection pool may starve, or the DB may spike in connections/memory.

```sql
-- Start 100 instances at once
DO $$
BEGIN
  FOR i IN 1..100 LOOP
    PERFORM df.start(df.sql('SELECT pg_sleep(0.1)'), 'burst-' || i);
  END LOOP;
END $$;

-- Monitor: how long until all complete?
-- Watch for: worker crash, OOM, stuck instances
```

**Variants:**
- 10, 100, 500, 1000 instances
- Mix of fast (SELECT 1) and slow (pg_sleep(5)) instances
- Concurrent sessions each starting instances

### A2. Very deep graph nesting

**What:** Build deeply nested THEN chains (A ~> B ~> C ~> ... ~> Z × 100).

**Why:** `execute_function_node_with_vars` is recursive via `Box::pin`. Deep graphs risk stack overflow. Node insertion in `df.start()` is also recursive. There is no depth limit anywhere in the code.

```sql
-- Generate a chain of 500 sequential SQL nodes
SELECT df.start(
  df.seq(df.seq(df.seq(df.seq(df.seq(
    'SELECT 1', 'SELECT 2'), 'SELECT 3'), 'SELECT 4'), 'SELECT 5'), 'SELECT 6')
  -- ... programmatically nest to depth 500
);
```

**Variants:**
- Depth 50, 100, 200, 500
- Deeply nested IF inside IF inside IF
- Deeply nested LOOP inside LOOP

### A3. Very wide graph (many parallel branches)

**What:** Use `join3` nested to create 10+, 50+, 100+ parallel branches.

**Why:** Each JOIN branch spawns a sub-orchestration. Many parallel sub-orchestrations may overwhelm the duroxide runtime or exhaust the connection pool.

```sql
-- Nest join3 calls to get 9+ parallel branches
SELECT df.start(
  df.join3(
    df.join3('SELECT 1', 'SELECT 2', 'SELECT 3'),
    df.join3('SELECT 4', 'SELECT 5', 'SELECT 6'),
    df.join3('SELECT 7', 'SELECT 8', 'SELECT 9')
  )
);
```

### A4. Very long execution history (loop iterations)

**What:** Run a loop that iterates 1,000+ times.

**Why:** Each loop iteration calls `continue_as_new`, which creates a new orchestration execution in Duroxide's history. The orchestration history tables (`duroxide.*`) may grow unboundedly. The background worker has no iteration cap.

```sql
CREATE TABLE loop_counter (n INT DEFAULT 0);
INSERT INTO loop_counter VALUES (0);

SELECT df.start(
  df.loop(
    'UPDATE loop_counter SET n = n + 1',            -- body
    'SELECT n < 10000 FROM loop_counter'              -- condition
  )
);
-- Watch: duroxide.* table sizes, memory, execution time
```

### A5. Large SQL result sets

**What:** Execute a SQL node that returns millions of rows.

**Why:** `execute_sql` activity calls `fetch_all()`, deserializes every row into a `serde_json::Value`, and returns the entire result as a single JSON string. This is unbounded — a large result set will OOM the background worker.

```sql
-- Generate a table with 1M rows, then select all of them in a durable function
CREATE TABLE big_table AS SELECT generate_series(1, 1000000) AS id;

SELECT df.start(df.sql('SELECT * FROM big_table'));
-- Expected: OOM or extreme memory pressure
```

**Variants:**
- 1K, 10K, 100K, 1M rows
- Wide rows (many columns, large TEXT values)
- Result passed through variable substitution (`$name`) to the next node

### A6. Very large SQL query text

**What:** Pass an extremely long SQL string (100KB+) as a node query.

**Why:** The query is stored in `df.nodes.query` (TEXT column, no length limit), serialized into JSON for the orchestration, and logged. Very large queries may cause serialization failures or memory pressure.

```sql
-- Build a query string with 100K characters
SELECT df.start(df.sql('SELECT ' || repeat('1,', 50000) || '1'));
```

### A7. Rapid fire start/cancel cycles

**What:** Start an instance and immediately cancel it, in a tight loop.

**Why:** Tests the race between the worker picking up an instance and the cancel signal arriving. May expose incomplete cleanup or stuck state.

```sql
DO $$
DECLARE inst TEXT;
BEGIN
  FOR i IN 1..100 LOOP
    inst := df.start('SELECT pg_sleep(10)', 'cancel-test-' || i);
    PERFORM df.cancel(inst);
  END LOOP;
END $$;
-- Check: are all instances properly canceled? Any stuck?
```

### A8. Large variable payloads

**What:** Set a variable to a very large string (1MB+) and use it in a workflow.

**Why:** Variables are stored in `df.vars` (TEXT column), captured at `df.start()`, serialized into the orchestration input JSON, and substituted into queries via string replacement. Large vars may cause serialization failures or memory issues.

```sql
SELECT df.setvar('big_val', repeat('x', 1048576));  -- 1MB
SELECT df.start(df.sql('SELECT ''{big_val}'''));
```

---

## Category B: Bugs & Logical Errors

These tests are designed to expose incorrect behavior in normal-ish usage, targeting edge cases the happy-path tests don't cover.

### B1. Loop with always-true condition (infinite loop)

**What:** Create a while-loop whose condition never becomes false.

**Why:** There is no iteration limit. The worker will spin forever on `continue_as_new`, bloating duroxide history tables. This is a realistic user mistake.

```sql
SELECT df.start(
  df.loop('SELECT 1', 'SELECT true')
);
-- Expected: runs forever. How do you detect and stop this?
-- Can df.cancel() stop it? How fast?
```

### B2. Unconditional infinite loop

**What:** `df.loop('SELECT 1')` with no condition and no break.

**Why:** Same as B1 but even simpler to accidentally create.

### B3. Loop condition with ambiguous truthiness

**What:** Test edge cases of `evaluate_condition()`:

```sql
-- What does each of these mean to the loop?
df.loop('SELECT 1', 'SELECT 0')           -- falsy (stops)
df.loop('SELECT 1', 'SELECT ''''')        -- empty string: truthy or falsy?
df.loop('SELECT 1', 'SELECT NULL')        -- NULL: truthy or falsy?
df.loop('SELECT 1', 'SELECT ''false''')   -- string "false": truthy in is_truthy!
df.loop('SELECT 1', 'SELECT ''no''')      -- string "no": ???
df.loop('SELECT 1', 'SELECT 0.0')         -- float zero
df.loop('SELECT 1', 'SELECT ''{}'':jsonb') -- empty object
df.loop('SELECT 1', 'SELECT ''[]''::jsonb') -- empty array
```

**Why:** `is_truthy()` in types.rs has some surprising behavior — e.g., the string `"false"` is truthy if it doesn't match the exact list `"true" | "t" | "yes" | "1"`, but then falls through to `parse::<i64>` which fails, then `!s.is_empty()` which is true. A user writing `SELECT 'false'` as a condition would expect it to be falsy.

### B4. Variable substitution edge cases

**What:** Test variable names that collide with system vars or result names:

```sql
-- Variable named same as system var
SELECT df.setvar('sys_instance_id', 'hacked');
SELECT df.start(df.sql('SELECT ''{sys_instance_id}'''));
-- Does the user var win? Or the system var?

-- Variable name with special characters
SELECT df.setvar('name with spaces', 'value');
SELECT df.setvar('name{with}braces', 'value');
SELECT df.setvar('', 'empty name');

-- Result name collision with variable
-- (result $foo vs variable {foo})
```

**Why:** `substitute_all_with_options` does system vars first, then user vars, then results. A user var named `sys_instance_id` would be substituted after the system var, so `{sys_instance_id}` gets the system value. But this ordering is not documented.

### B5. SQL node that returns no rows

**What:** Execute a SQL node whose query returns 0 rows, then try to use the result.

```sql
SELECT df.start(
  df.sql('SELECT 1 WHERE false') |=> 'empty_result'
  ~> df.sql('SELECT $empty_result')
);
```

**Why:** The result JSON will be `{"rows":[],"row_count":0}`. When substituted as `$empty_result`, the literal JSON string gets embedded into the next query. Is that what the user expects?

### B6. SQL node that runs DML (INSERT/UPDATE/DELETE)

**What:** A SQL node that modifies data but returns nothing (no RETURNING clause).

```sql
SELECT df.start(
  df.sql('INSERT INTO some_table VALUES (1)')
  |=> 'insert_result'
  ~> df.sql('SELECT $insert_result')
);
```

**Why:** DML without RETURNING returns 0 rows. The result would be `{"rows":[],"row_count":0}`. Does `$insert_result` substitution produce something useful?

### B7. SQL node with multiple statements

**What:** Pass multiple SQL statements separated by semicolons.

```sql
SELECT df.start(df.sql('SELECT 1; SELECT 2; DROP TABLE important'));
```

**Why:** `sqlx::query().fetch_all()` behavior with multiple statements is driver-dependent. It may execute only the first, execute all, or error. This should be tested and documented.

### B8. RACE where both branches fail

**What:** Both branches of a RACE node raise errors.

```sql
SELECT df.start(
  df.race(
    'SELECT 1/0',   -- division by zero
    'SELECT 1/0'    -- division by zero
  )
);
```

**Why:** `execute_race_node` uses `ctx.select2` — does it report the first failure or wait for the second? What status does the instance end up in?

### B9. JOIN where one branch fails

**What:** One branch of a JOIN succeeds, the other fails.

```sql
SELECT df.start(
  df.join(
    'SELECT 1',     -- succeeds
    'SELECT 1/0'    -- fails
  )
);
```

**Why:** `execute_join_node` iterates results and returns `Err` on the first failed branch. But the successful branch's side effects (DML) are already committed. Is this the desired behavior? Does the instance status reflect partial completion?

### B10. Break outside a loop

**What:** Use `df.break()` as a standalone node, not inside a loop.

```sql
SELECT df.start(df.break('done'));
```

**Why:** The break sentinel `{"__break__": true, "value": "done"}` will be returned as the top-level result. The THEN handler propagates break signals upward. But without an enclosing loop, the break sentinel becomes the final result. Is this correct?

### B11. Using df.start() inside a workflow

**What:** A SQL node that calls `df.start()` recursively.

```sql
SELECT df.start(
  df.sql('SELECT df.start(df.sql(''SELECT 1''))')
);
```

**Why:** The code has `df.in_workflow` check for setvar/unsetvar/clearvars, but `df.start()` itself does NOT check `is_in_workflow_context()`. Recursive invocation could cause unbounded spawning.

### B12. Signal to non-existent or already-completed instance

```sql
-- Signal to a garbage ID
SELECT df.signal('nonexist', 'approve', '{}');

-- Start and complete, then signal
-- Does the signal silently succeed? Error? Get lost?
```

### B13. Multiple signals with same name

**What:** Send the same signal multiple times to an instance waiting for it.

**Why:** How does duroxide handle duplicate external events? Does the second one get queued, ignored, or cause an error?

### B14. Result name conflicts

**What:** Multiple nodes named the same thing with `|=>`.

```sql
SELECT df.start(
  df.sql('SELECT 1') |=> 'result'
  ~> df.sql('SELECT 2') |=> 'result'
  ~> df.sql('SELECT $result')
);
-- Which value does $result get?
```

---

## Category C: Misuse & Unintended Usage

These test what happens when users do something the API wasn't designed for.

### C1. Empty or whitespace-only SQL

```sql
SELECT df.start(df.sql(''));
SELECT df.start(df.sql('   '));
SELECT df.start(df.sql(NULL));  -- if possible
```

### C2. Non-SQL query text

```sql
SELECT df.start(df.sql('this is not sql at all'));
SELECT df.start(df.sql('{"json": "object"}'));
```

### C3. Calling df.status/df.result on someone else's instance

**Why:** RLS should prevent this, but verify the error message is sensible.

### C4. Using pg_durable operators on non-Durofut strings

```sql
SELECT 'hello' ~> 'world';    -- what happens?
SELECT 'not json' & 'also not';
```

**Why:** The operators accept TEXT. Non-Durofut strings should auto-wrap as SQL nodes, but tests should verify this behavior explicitly.

### C5. Extremely rapid polling of df.status()

```sql
-- Poll status in a tight loop with no sleep
DO $$
DECLARE s TEXT;
BEGIN
  FOR i IN 1..10000 LOOP
    SELECT df.status('some-id') INTO s;
  END LOOP;
END $$;
```

**Why:** Each `df.status()` creates a new tokio runtime and duroxide provider connection. Rapid polling may leak resources or cause connection exhaustion.

### C6. Calling DSL functions after df.start()

**What:** Call `df.setvar()`, `df.clearvars()` while instances are running.

**Why:** Variables are captured at `df.start()` time and are immutable during execution. But the user might not know this and expect changes to take effect. Is the behavior clearly communicated?

### C7. Using df.start() with manually crafted JSON

```sql
-- Bypass the DSL entirely and craft raw Durofut JSON
SELECT df.start('{"node_type": "SQL", "query": "SELECT 1"}');

-- Unknown fields in the JSON
SELECT df.start('{"node_type": "SQL", "query": "SELECT 1", "evil_field": "pwned"}');

-- Malformed nested structures
SELECT df.start('{"node_type": "THEN", "left_node": "not an object"}');
```

### C8. DROP EXTENSION while instances are running

```sql
-- Start a long-running instance, then drop the extension
SELECT df.start(df.sql('SELECT pg_sleep(60)'));
DROP EXTENSION pg_durable CASCADE;
-- What happens to the background worker? The running instance? The tables?
```

### C9. Instance ID collision

**Why:** IDs are 8-char substrings of UUIDs. With enough instances, collisions are theoretically possible (birthday problem at ~77K instances for 50% probability with 36^8 space, though the actual space is hex = 16^8 = ~4.3 billion). Test what happens if an ID collides.

---

## Category D: Chaos / Fault Injection

> **Does chaos testing make sense here?** Yes — pg_durable promises **durability** (it's in the name). Users will rely on it to survive crashes. If the worker crashes mid-execution, what happens to in-flight instances? Do they resume? Do they get stuck in "running" forever? Chaos testing is how you validate the durability guarantee.

### D1. Kill the background worker mid-execution

**What:** Start a long-running instance, then kill the worker process.

```bash
# Find and kill the worker
kill -9 $(pgrep -f pg_durable_worker)
```

**Why:** The worker has `set_restart_time(Some(Duration::from_secs(5)))` — it should restart after 5s. But:
- Does the interrupted instance resume or get stuck?
- Is the duroxide execution history intact?
- Does the runtime re-initialize cleanly?

### D2. Kill PostgreSQL mid-execution

**What:** `pg_ctl stop -m immediate` while instances are running, then restart.

**Why:** Tests recovery after an unclean shutdown. Duroxide uses PostgreSQL for persistence — are transactions consistent after crash recovery?

### D3. Disk full / Write failure

**What:** Fill the disk (or use a test fixture) while the worker is executing.

**Why:** If WAL/table writes fail, how does the worker behave? Does it crash? Retry? Corrupt state?

### D4. Network partition to database (multi-database scenario)

**What:** Start an instance targeting a remote database, then break the connection.

**Why:** The `connect_as_user` function in activities will fail. Does the activity error propagate cleanly? Does the instance fail gracefully?

### D5. Clock skew / Time jumps

**What:** Jump the system clock forward or backward while instances are running.

**Why:** `wait_for_schedule` computes wait duration at DSL time using `Utc::now()`. But `df.sleep()` uses duroxide's `schedule_timer`. If the system clock jumps, timers may fire at unexpected times. (The orchestration itself is deterministic — this mostly affects activity-level timestamps and completed_at.)

### D6. Extension drop + recreate while worker is running

**What:** Drop and immediately recreate the extension during execution.

**Why:** The epoch sentinel mechanism is designed to handle this. Verify it actually works — does the worker detect the recreate and re-initialize?

---

## Category E: Data Integrity & State Corruption

### E1. Orphaned nodes

**What:** Delete an instance row but leave its nodes, or vice versa.

```sql
-- Direct delete bypassing normal flow (as superuser)
DELETE FROM df.instances WHERE id = 'sometest';
-- Are the nodes still there? Do they cause problems?
```

**Why:** There are no FK constraints between `df.nodes` and `df.instances`. Nodes don't cascade-delete.

### E2. Instance stuck in "pending" forever

**What:** Start an instance but ensure the background worker never picks it up (e.g., wrong database, broken worker).

**Why:** There is no timeout on pending instances. A pending instance will sit forever. Users need a way to detect and clean up stale instances.

### E3. Instance stuck in "running" forever

**What:** An instance whose orchestration hangs (e.g., waiting on a signal that never comes, with no timeout).

```sql
SELECT df.start(df.wait_for_signal('never_coming'));
-- This will wait forever. No default timeout.
```

### E4. Duroxide history table bloat

**What:** After running thousands of instances, check the size of `duroxide.*` tables.

**Why:** There is no GC/maintenance for completed orchestration history. Over time, these tables will grow without bound.

```sql
-- After running many tests:
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename))
FROM pg_tables WHERE schemaname = 'duroxide'
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC;
```

### E5. df.nodes table bloat

**What:** Same as E4 but for `df.nodes` and `df.instances`. Completed instances leave their nodes in the table forever.

### E6. Tampering with df.nodes while instance is running

```sql
-- As a user with RLS bypass, modify a running instance's nodes
UPDATE df.nodes SET query = 'SELECT evil()' WHERE instance_id = 'running1';
```

**Why:** The function graph is loaded once at the start of execution. Modifications after loading have no effect — but is this guaranteed? What if the graph is reloaded on `continue_as_new`?

---

## Category F: Concurrency & Race Conditions

### F1. Concurrent df.start() from multiple sessions

**What:** Multiple PostgreSQL sessions calling `df.start()` simultaneously.

**Why:** Node/instance IDs are generated per-session. With enough concurrency, two sessions might generate the same 8-char ID (unlikely but testable as a correctness concern). Also tests that the worker handles multiple new instances appearing simultaneously.

### F2. df.signal() concurrent with instance completion

**What:** Send a signal at the exact moment an instance completes.

**Why:** Race between the signal delivery and the instance status update. What state does the instance end up in?

### F3. df.cancel() concurrent with instance completion

**What:** Cancel at the exact moment a workflow completes naturally.

**Why:** Similar race. Does the instance end up "completed" or "canceled"?

### F4. Shared variable mutation during df.start()

**What:** From two sessions: session A calls `df.setvar('x', 'A')` then `df.start(...)`, while session B calls `df.setvar('x', 'B')` then `df.start(...)`.

**Why:** `df.vars` is a global table (not per-session, not per-instance). Two sessions setting the same variable will overwrite each other. The captured value at `df.start()` time depends on who wrote last.

### F5. Many sessions polling df.status() simultaneously

**What:** 20+ concurrent sessions all polling `df.status()` in a loop.

**Why:** Each call creates a fresh tokio runtime and duroxide provider. This is expensive and may exhaust resources.

---

## Existing Coverage Analysis

The 39 existing E2E tests cover **happy-path functionality**:

| Area | Tests | Gap |
|---|---|---|
| Basic SQL execution | 01 | No error cases |
| Sequences | 02 | No deep nesting |
| Variables | 03, 20 | No edge cases (empty, special chars, collisions) |
| Parallel (JOIN) | 04, 12, 16 | No branch-failure cases |
| Conditionals (IF) | 05, 06, 13 | No ambiguous truthiness |
| Sleep | 07 | No large/zero values |
| Loop | 08, 24 | No infinite loops, no iteration limits |
| Monitoring | 09 | No concurrent monitoring |
| Explain | 10, 31 | Happy path only |
| Scenarios | 11, 14, 15 | Realistic but small-scale |
| RACE | 17 | No both-fail case |
| HTTP | 18, 19 | No timeout, no large response |
| Signals | 21 | No edge cases |
| Cross-connection | 22 | Basic only |
| Transactions | 23 | Basic only |
| Security/RLS | 25, 26, 27, 37 | Good coverage |
| Worker lifecycle | 28 | Basic only |
| Error handling | 29, 32, 33 | Validation errors only, no runtime failures |
| Graph reuse | 30 | Basic only |
| Multi-database | 34 | Basic only |
| Heartbeat | 35 | Basic only |
| SSRF | 36 | Good coverage |

**Major gaps:**
- Zero stress/load tests
- Zero resource exhaustion tests
- Zero chaos/fault injection tests
- Zero concurrency/race condition tests (beyond basic cross-connection)
- Zero data integrity/cleanup tests
- Minimal edge case coverage for DSL functions

---

## Priority & Sequencing

### Phase 1: High-value, easy to write (find real bugs fast)

1. **B1/B2** — Infinite loops (will definitely expose missing safeguards)
2. **B3** — Truthiness edge cases (likely bugs in `evaluate_condition`)
3. **B5/B6** — Empty/DML result handling
4. **B10** — Break outside loop
5. **B11** — Recursive df.start() (likely unguarded)
6. **C1** — Empty/null SQL
7. **C7** — Manually crafted JSON

### Phase 2: Stress tests (find resource limits)

8. **A1** — Many concurrent instances (10, 100, 500)
9. **A4** — Long loop history (100, 1000, 10000 iterations)
10. **A5** — Large result sets (1K, 10K, 100K rows)
11. **A2** — Deep graph nesting (50, 100, 200 depth)
12. **A7** — Rapid start/cancel cycles

### Phase 3: Chaos & durability (validate the "durable" promise)

13. **D1** — Kill worker mid-execution
14. **D6** — Drop+recreate extension
15. **D2** — PostgreSQL crash recovery
16. **E2/E3** — Stuck instances detection

### Phase 4: Concurrency & data integrity

17. **F1** — Concurrent df.start()
18. **F4** — Shared variable races
19. **E4/E5** — Table bloat measurement
20. **E1** — Orphaned nodes

### Phase 5: Additional misuse & edge cases

21. **C5** — Rapid status polling
22. **A3** — Wide parallel graphs
23. **A6** — Large query text
24. **A8** — Large variable payloads
25. **B4** — Variable name collisions
26. Remaining B, C items

---

## Implementation Notes

- **Stress tests need timeouts:** Each stress test should have a hard timeout (e.g., 60s) and a way to clean up if it hangs.
- **Monitoring during stress:** Capture `pg_stat_activity`, table sizes, and worker logs during stress tests to diagnose failures.
- **Idempotent cleanup:** Each test must clean up after itself, including killing stuck instances.
- **Structured as E2E SQL:** Follow the existing `tests/e2e/sql/NN_*.sql` pattern where possible. Chaos tests (D) may need shell scripting or custom Rust test harness.
- **Worker logs are critical:** Most failures manifest in `~/.pgrx/17.log` — tests should check logs for errors/panics.
