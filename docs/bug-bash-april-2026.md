# pg_durable Bug Bash — April 2026

**Date:** April 2026

**Duration:** ~90–120 minutes

**Audience:** Internal team (familiar with PostgreSQL)

**Environment:** GitHub Codespaces (pg_durable pre-installed)

---

## Goals

1. **Validate core scenarios** — Run 5 real-world patterns end-to-end and confirm they work as documented
2. **Assess developer experience** — Is the DSL intuitive? Are monitoring/debugging tools helpful?
3. **Test AI agent experience** — Can Copilot generate correct pg_durable SQL from natural language?
4. **Find bugs** — Surface edges cases, confusing behaviors, and errors before GA
5. **Collect feedback** — Gather structured input on ergonomics, difficulty, and gaps

---

## How It Works

| Step | What You Do | Time |
|------|-------------|------|
| **Setup** | Open Codespace, verify extension, load test data | 10 min |
| **Scenarios 1–3** (required) | Getting Started, ETL Pipeline, Variables | 30–40 min |
| **Scenarios 4–6** (optional) | Parallel Aggregation, Loops, Scheduling | 20–30 min |
| **Cross-Cutting** (pick 2+) | Monitoring, Branching, Signals, Replay/Restart | 20–30 min |
| **AI Agent Experience** | Use Copilot to generate pg_durable SQL | 10–15 min |
| **Feedback** | Fill out the feedback section at the bottom | 5–10 min |

> 📖 **Reference:** Keep the [User Guide](../USER_GUIDE.md) open in a second tab for DSL reference and troubleshooting.

---

## Environment Setup

### 1. Open Your Codespace

Open the pg_durable Codespace. The extension is pre-built and PostgreSQL is configured with `pg_durable` in `shared_preload_libraries`.

### 2. Start PostgreSQL and Connect

```bash
# Start the test server (builds extension + starts PG)
./scripts/pg-start.sh

# Connect to the test database
~/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -d postgres
```

### 3. Verify pg_durable Is Working

Run these in `psql` to confirm everything is healthy:

```sql
-- Verify pg_durable is in shared_preload_libraries
SHOW shared_preload_libraries;
-- Expected: includes 'pg_durable'

-- Create the extension (idempotent)
CREATE EXTENSION IF NOT EXISTS pg_durable;

-- Smoke test: start a durable function and check it completes
SELECT df.start('SELECT ''pg_durable is working!''');
-- Returns an 8-character instance ID, e.g. 'a1b2c3d4'

-- Wait a moment, then check it completed
SELECT instance_id, label, status FROM df.list_instances();
-- Expected: status = 'Completed'
```

> ⚠️ **If workflows don't complete**, check the background worker logs:
> ```bash
> tail -f ~/.pgrx/17.log
> ```
> Look for lines starting with `pg_durable:` — see [Troubleshooting](../USER_GUIDE.md#troubleshooting) for common issues.

### 4. Load Test Data

Copy-paste this into `psql` to create the `playground` schema with sample data:

```sql
-- Create playground schema
CREATE SCHEMA IF NOT EXISTS playground;

-- Users table
CREATE TABLE IF NOT EXISTS playground.users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT now()
);

-- Orders table
CREATE TABLE IF NOT EXISTS playground.orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES playground.users(id),
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(50) DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT now(),
    processed_at TIMESTAMP
);

-- Task queue for job processing examples
CREATE TABLE IF NOT EXISTS playground.task_queue (
    id SERIAL PRIMARY KEY,
    payload JSONB NOT NULL,
    status VARCHAR(50) DEFAULT 'pending',
    priority INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT now(),
    started_at TIMESTAMP,
    completed_at TIMESTAMP
);

-- Logs table
CREATE TABLE IF NOT EXISTS playground.logs (
    id SERIAL PRIMARY KEY,
    msg TEXT NOT NULL,
    level VARCHAR(20) DEFAULT 'info',
    created_at TIMESTAMP DEFAULT now()
);

-- Heartbeats table (for loop/cron examples)
CREATE TABLE IF NOT EXISTS playground.heartbeats (
    id SERIAL PRIMARY KEY,
    ts TIMESTAMP NOT NULL,
    source VARCHAR(100) DEFAULT 'pg_durable'
);

-- Staging table (for ETL examples)
CREATE TABLE IF NOT EXISTS playground.staging (
    id SERIAL PRIMARY KEY,
    data JSONB,
    source_id INTEGER,
    processed_at TIMESTAMP
);

-- Target table (for ETL examples)
CREATE TABLE IF NOT EXISTS playground.target (
    id SERIAL PRIMARY KEY,
    data JSONB,
    source_id INTEGER,
    processed_at TIMESTAMP,
    loaded_at TIMESTAMP DEFAULT now()
);

-- Insert sample users
INSERT INTO playground.users (name, email, active) VALUES
    ('Alice Johnson', 'alice@example.com', true),
    ('Bob Smith', 'bob@example.com', true),
    ('Carol White', 'carol@example.com', true),
    ('David Brown', 'david@example.com', false),
    ('Eve Davis', 'eve@example.com', true)
ON CONFLICT (email) DO NOTHING;

-- Insert sample orders
INSERT INTO playground.orders (user_id, amount, status) VALUES
    (1, 99.99, 'pending'),
    (1, 149.50, 'completed'),
    (2, 75.00, 'pending'),
    (3, 200.00, 'processing'),
    (3, 50.00, 'pending'),
    (5, 125.00, 'completed')
ON CONFLICT DO NOTHING;

-- Insert sample tasks
INSERT INTO playground.task_queue (payload, status, priority) VALUES
    ('{"type": "email", "to": "alice@example.com", "subject": "Welcome!"}', 'pending', 1),
    ('{"type": "email", "to": "bob@example.com", "subject": "Order Confirmation"}', 'pending', 2),
    ('{"type": "report", "name": "daily_sales"}', 'pending', 0),
    ('{"type": "cleanup", "target": "temp_files"}', 'completed', 0),
    ('{"type": "sync", "source": "external_api"}', 'pending', 3)
ON CONFLICT DO NOTHING;

-- Insert staging data for ETL
INSERT INTO playground.staging (data, source_id) VALUES
    ('{"product": "Widget A", "qty": 10}', 1001),
    ('{"product": "Widget B", "qty": 25}', 1002),
    ('{"product": "Gadget X", "qty": 5}', 1003)
ON CONFLICT DO NOTHING;

SELECT 'Playground data loaded!' AS status;
SELECT 'Users: ' || COUNT(*) FROM playground.users;
SELECT 'Orders: ' || COUNT(*) FROM playground.orders;
SELECT 'Tasks: ' || COUNT(*) FROM playground.task_queue;
```

---

# Part 1: Core Scenarios (Required: 1–3, Optional: 4–6)

---

## Scenario 1: Getting Started

**Goal:** Run your first durable function and learn the basic monitoring commands.

### Steps

**Step 1 — Start a durable function**

```sql
SELECT df.start(
    'SELECT ''Hello, durable world!'' AS message',
    'my-first-function'
);
-- Save the returned instance ID (e.g. 'a1b2c3d4')
```

**Step 2 — Check the status**

```sql
-- Check status by label
SELECT instance_id, label, status
FROM df.list_instances()
WHERE label = 'my-first-function';

-- Or directly by instance ID (replace with yours)
SELECT df.status('REPLACE_ME');
```

**Step 3 — Get the result**

```sql
SELECT df.result('REPLACE_ME');
-- Expected: JSON containing {"message": "Hello, durable world!"}
```

**Step 4 — Visualize the execution graph**

```sql
SELECT df.explain('REPLACE_ME');
-- Shows a tree with status markers: ✓ Completed, ✗ Failed, ⏳ Running, ○ Pending
```

**Step 5 — See detailed instance info**

```sql
SELECT * FROM df.instance_info('REPLACE_ME');
SELECT * FROM df.instance_nodes('REPLACE_ME');
```

### What to Observe

- [ ] `df.start()` returned an 8-character instance ID
- [ ] Status transitioned to `Completed` (may take 1–3 seconds)
- [ ] `df.result()` returned the query output as JSON
- [ ] `df.explain()` showed a readable tree with a ✓ marker
- [ ] `df.instance_nodes()` showed the SQL node with status and result

### Exploration

Try these and note what happens:

```sql
-- What happens when SQL has an error?
SELECT df.start('SELECT * FROM nonexistent_table_xyz', 'error-test');
-- Check: SELECT df.status('...'); SELECT df.explain('...');

-- Start a function without a label
SELECT df.start('SELECT 42 AS answer');
-- Check: how does it appear in df.list_instances()?

-- Run df.explain() on a DSL expression (dry-run, no execution)
SELECT df.explain('SELECT 1' ~> 'SELECT 2' ~> 'SELECT 3');
```

---

## Scenario 2: ETL Pipeline

**Goal:** Chain multiple SQL steps sequentially using the `~>` operator and verify data flows through each stage.

### Steps

**Step 1 — Reset test tables**

```sql
-- Clear any previous data
TRUNCATE playground.staging, playground.target;

-- Re-insert staging data
INSERT INTO playground.staging (data, source_id) VALUES
    ('{"product": "Widget A", "qty": 10}', 1001),
    ('{"product": "Widget B", "qty": 25}', 1002),
    ('{"product": "Gadget X", "qty": 5}', 1003);
```

**Step 2 — Start the 3-step ETL pipeline**

```sql
SELECT df.start(
    -- Step 1: Cleanup old target rows
    'DELETE FROM playground.target WHERE loaded_at < now() - interval ''7 days'''
    -- Step 2: Mark staging rows as processed
    ~> 'UPDATE playground.staging SET processed_at = now() WHERE processed_at IS NULL'
    -- Step 3: Load into target
    ~> 'INSERT INTO playground.target (data, source_id)
        SELECT data, source_id FROM playground.staging WHERE processed_at IS NOT NULL',
    'etl-pipeline'
);
```

**Step 3 — Wait and verify**

```sql
-- Poll status (should be Completed within a few seconds)
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'etl-pipeline' LIMIT 1)
);

-- Verify data arrived in target
SELECT COUNT(*) AS loaded_rows FROM playground.target;
-- Expected: 3

-- Verify staging rows were marked
SELECT COUNT(*) AS processed FROM playground.staging WHERE processed_at IS NOT NULL;
-- Expected: 3
```

**Step 4 — Inspect the execution**

```sql
-- Visualize the pipeline
SELECT df.explain(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'etl-pipeline' LIMIT 1)
);

-- See per-node details (status, timing)
SELECT node_type, query, status, result, updated_at
FROM df.instance_nodes(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'etl-pipeline' LIMIT 1)
);
```

### What to Observe

- [ ] Pipeline completed all 3 steps in order
- [ ] Target table has 3 rows loaded from staging
- [ ] Staging rows have `processed_at` set
- [ ] `df.explain()` shows a SEQUENCE graph with 3 ✓ nodes
- [ ] `df.instance_nodes()` shows each step's status and timing

### Exploration

```sql
-- What happens if a middle step fails?
-- Try an ETL with a bad SQL step in the middle:
SELECT df.start(
    'DELETE FROM playground.target'
    ~> 'SELECT * FROM this_table_does_not_exist'    -- This will fail
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Should not reach here'')',
    'etl-broken-middle'
);
-- Check: Does the 3rd step execute? What does df.explain() show?
-- Check: SELECT df.status('...'); SELECT df.explain('...');
```

---

## Scenario 3: Order Processing with Variables

**Goal:** Capture results from one step and use them in subsequent steps via `|=>` (named results) and `$variable` substitution.

### Steps

**Step 1 — Reset orders to pending**

```sql
UPDATE playground.orders SET status = 'pending', processed_at = NULL;
```

**Step 2 — Start the order processing pipeline**

```sql
SELECT df.start(
    -- Capture the first pending order's ID
    'SELECT id FROM playground.orders WHERE status = ''pending'' ORDER BY id LIMIT 1'
        |=> 'order_id'

    -- Mark it as processing
    ~> 'UPDATE playground.orders SET status = ''processing''
        WHERE id = $order_id'

    -- Simulate some work
    ~> df.sleep(2)

    -- Mark it as completed
    ~> 'UPDATE playground.orders SET status = ''completed'', processed_at = now()
        WHERE id = $order_id',
    'process-order'
);
```

**Step 3 — Wait and verify**

```sql
-- Check the function completed
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'process-order' LIMIT 1)
);

-- Verify the order was processed
SELECT id, status, processed_at FROM playground.orders ORDER BY id;
-- Expected: First pending order now has status = 'completed' and processed_at set
```

**Step 4 — Inspect variable substitution**

```sql
-- Look at the node results — you should see the captured order_id
SELECT node_type, query, result_name, status, result
FROM df.instance_nodes(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'process-order' LIMIT 1)
);

-- Visualize the graph
SELECT df.explain(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'process-order' LIMIT 1)
);
```

### What to Observe

- [ ] `|=> 'order_id'` captured the result of the first query
- [ ] `$order_id` was substituted correctly in subsequent steps
- [ ] The order transitioned: `pending` → `processing` → `completed`
- [ ] `df.instance_nodes()` shows the captured variable in the result column
- [ ] `df.explain()` shows the NAME node with the variable binding

### Exploration

```sql
-- Try durable function variables with {varname} syntax
SELECT df.setvar('min_amount', '100');

SELECT df.start(
    'SELECT id, amount FROM playground.orders
     WHERE amount >= {min_amount}::decimal
     ORDER BY amount DESC LIMIT 1' |=> 'big_order'
    ~> 'INSERT INTO playground.logs (msg)
        VALUES (''Found large order: '' || $big_order)',
    'var-test'
);

-- Check: Did {min_amount} substitute correctly?
SELECT df.result(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'var-test' LIMIT 1)
);

-- Clean up
SELECT df.unsetvar('min_amount');

-- Also try system variables:
SELECT df.start(
    'INSERT INTO playground.logs (msg)
     VALUES (''Instance '' || ''{sys_instance_id}'' || '' with label '' || ''{sys_label}'')',
    'sysvar-test'
);
```

---

## Scenario 4: Parallel Aggregation (Optional)

**Goal:** Run multiple queries in parallel using the `&` operator and `df.join()`, and verify they execute concurrently.

### Steps

**Step 1 — Start parallel counts using the `&` operator**

```sql
SELECT df.start(
    (
        'SELECT COUNT(*) AS user_count FROM playground.users'
        &
        'SELECT COUNT(*) AS order_count FROM playground.orders'
        &
        'SELECT SUM(amount) AS total_revenue FROM playground.orders'
    )
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Dashboard data collected'')',
    'parallel-counts'
);
```

**Step 2 — Try the same with `df.join()` function**

```sql
SELECT df.start(
    df.join(
        'SELECT COUNT(*) FROM playground.users',
        'SELECT COUNT(*) FROM playground.orders'
    )
    ~> 'SELECT ''Join complete'' AS status',
    'join-function'
);
```

**Step 3 — Try `df.join3()` for three branches**

```sql
SELECT df.start(
    df.join3(
        'SELECT COUNT(*) FROM playground.users',
        'SELECT COUNT(*) FROM playground.orders',
        'SELECT COUNT(*) FROM playground.task_queue'
    ),
    'join3-test'
);
```

**Step 4 — Inspect parallel execution**

```sql
-- Check that parallel branches had overlapping execution times
SELECT node_type, query, status, updated_at
FROM df.instance_nodes(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'parallel-counts' LIMIT 1)
);

-- Visualize the JOIN graph
SELECT df.explain(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'parallel-counts' LIMIT 1)
);
```

### What to Observe

- [ ] All parallel branches completed
- [ ] `df.explain()` shows a JOIN graph with parallel branches marked `║`
- [ ] `df.instance_nodes()` shows branches executed concurrently (similar timestamps)
- [ ] The sequential step (`~>`) ran only after all parallel branches finished

### Exploration

```sql
-- Try the RACE operator: first to complete wins
SELECT df.start(
    df.race(
        'SELECT ''fast'' AS winner',
        (df.sleep(10) ~> 'SELECT ''slow'' AS winner')
    ),
    'race-test'
);
-- Check: Which branch won?
SELECT df.result(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'race-test' LIMIT 1)
);

-- Also try the | (pipe) operator syntax for race:
SELECT df.start(
    'SELECT ''branch-a'' AS result' | 'SELECT ''branch-b'' AS result',
    'race-pipe'
);
```

---

## Scenario 5: Loops (Optional)

**Goal:** Create loops that repeat forever or until a condition is met, and test cancellation and `df.break()`.

### Steps

**Step 1 — Start an eternal heartbeat loop**

```sql
-- Clear previous heartbeats
TRUNCATE playground.heartbeats;

-- Start a loop that inserts heartbeats every 2 seconds
SELECT df.start(
    @> (
        'INSERT INTO playground.heartbeats (ts) VALUES (now())'
        ~> df.sleep(2)
    ),
    'heartbeat-loop'
);
```

**Step 2 — Watch it run**

```sql
-- Wait a few seconds, then check heartbeats accumulating
SELECT pg_sleep(5);
SELECT COUNT(*) AS heartbeats FROM playground.heartbeats;
-- Expected: 2-3 rows (depending on timing)

-- Check the loop is still running
SELECT instance_id, label, status
FROM df.list_instances()
WHERE label = 'heartbeat-loop';
-- Expected: status = 'Running'
```

**Step 3 — Cancel the loop**

```sql
SELECT df.cancel(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'heartbeat-loop' LIMIT 1),
    'Bug bash test — stopping heartbeat loop'
);

-- Verify it stopped
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'heartbeat-loop' LIMIT 1)
);
-- Expected: 'Cancelled'

-- Check final heartbeat count
SELECT COUNT(*) AS final_count FROM playground.heartbeats;
```

**Step 4 — Try a while-loop with a condition**

```sql
-- Create a counter table
CREATE TABLE IF NOT EXISTS playground.counter (val INT DEFAULT 0);
TRUNCATE playground.counter;
INSERT INTO playground.counter VALUES (0);

-- Loop: increment counter while it's less than 5
SELECT df.start(
    df.loop(
        'UPDATE playground.counter SET val = val + 1',
        'SELECT val < 5 FROM playground.counter'   -- condition: continue while true
    ),
    'while-loop'
);

-- Wait and check
SELECT pg_sleep(5);
SELECT val FROM playground.counter;
-- Expected: 5 (loop ran 5 times then stopped)

SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'while-loop' LIMIT 1)
);
-- Expected: 'Completed'
```

**Step 5 — Try `df.break()` to exit a loop early**

```sql
TRUNCATE playground.counter;
INSERT INTO playground.counter VALUES (0);

SELECT df.start(
    df.loop(
        'UPDATE playground.counter SET val = val + 1'
        ~> df.if(
            'SELECT val >= 3 FROM playground.counter',
            df.break('{"reason": "reached 3"}'),
            'SELECT ''continuing...'''
        )
    ),
    'break-loop'
);

-- Wait and check
SELECT pg_sleep(5);
SELECT val FROM playground.counter;
-- Expected: 3

SELECT df.result(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'break-loop' LIMIT 1)
);
-- Expected: contains {"reason": "reached 3"}
```

### What to Observe

- [ ] Eternal loop (`@>`) kept inserting heartbeats until cancelled
- [ ] `df.cancel()` successfully stopped the loop, status became `Cancelled`
- [ ] While-loop exited when condition became false
- [ ] `df.break()` exited the loop early and returned the break value
- [ ] `df.explain()` shows LOOP nodes with `↻ body:` markers

### Exploration

```sql
-- Try combining a loop with variable capture
TRUNCATE playground.counter;
INSERT INTO playground.counter VALUES (0);

SELECT df.start(
    df.loop(
        'UPDATE playground.counter SET val = val + 1 RETURNING val' |=> 'current_val'
        ~> df.if(
            'SELECT $current_val >= 4',
            df.break('$current_val'),
            'SELECT ''still going: '' || $current_val'
        )
    ),
    'loop-with-vars'
);

-- Check: Did the loop stop at 4? Was the break value captured?
SELECT pg_sleep(5);
SELECT val FROM playground.counter;
SELECT df.result(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'loop-with-vars' LIMIT 1)
);
```

---

## Scenario 6: Scheduling & Cron Jobs (Optional)

**Goal:** Use `df.wait_for_schedule()` with cron expressions to run jobs on a schedule, and verify timing behavior.

### Steps

**Step 1 — Start a cron job that runs every minute**

```sql
-- Clear previous heartbeats
TRUNCATE playground.heartbeats;

-- Start a scheduled loop: insert a heartbeat every minute
-- NOTE: This runs forever — you MUST cancel it when done
SELECT df.start(
    @> (
        'INSERT INTO playground.heartbeats (ts) VALUES (now())'
        ~> df.wait_for_schedule('* * * * *')  -- every minute
    ),
    'cron-every-minute'
);
```

**Step 2 — Verify the schedule fires**

```sql
-- The first heartbeat should appear quickly (beginning of the loop)
-- Then wait_for_schedule pauses until the next minute boundary
SELECT pg_sleep(5);
SELECT COUNT(*) AS initial_heartbeats FROM playground.heartbeats;
-- Expected: 1 (first iteration ran immediately)

-- Check that the instance is Running (waiting for next schedule tick)
SELECT instance_id, label, status
FROM df.list_instances()
WHERE label = 'cron-every-minute';
-- Expected: status = 'Running'
```

**Step 3 — Wait for the next tick**

```sql
-- Wait ~70 seconds to see the second tick
SELECT pg_sleep(70);
SELECT COUNT(*) AS after_one_minute FROM playground.heartbeats;
-- Expected: 2 (one more heartbeat after the minute boundary)

-- Check timestamps to verify ~1 minute spacing
SELECT ts FROM playground.heartbeats ORDER BY ts;
```

**Step 4 — Cancel the cron job**

```sql
SELECT df.cancel(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'cron-every-minute' LIMIT 1),
    'Bug bash — done testing cron'
);

-- Verify it stopped
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'cron-every-minute' LIMIT 1)
);
-- Expected: 'Cancelled'
```

**Step 5 — Try a scheduled job with work + logging**

```sql
-- A more realistic cron job: archive old logs every minute
SELECT df.start(
    @> (
        'INSERT INTO playground.logs (msg, level)
         VALUES (''Cron tick at '' || now()::text, ''info'')'
        ~> 'DELETE FROM playground.task_queue
            WHERE status = ''completed''
            AND completed_at < now() - interval ''1 hour'''
        ~> df.wait_for_schedule('* * * * *')
    ),
    'cron-cleanup'
);

-- Let it run for ~70 seconds to see one full cycle
SELECT pg_sleep(70);

-- Check the log entries
SELECT msg, created_at FROM playground.logs
WHERE msg LIKE 'Cron tick%'
ORDER BY created_at DESC;

-- Inspect the execution graph
SELECT df.explain(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'cron-cleanup' LIMIT 1)
);

-- Cancel when done
SELECT df.cancel(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'cron-cleanup' LIMIT 1),
    'Done testing'
);
```

### Cron Expression Quick Reference

| Expression | Meaning |
|------------|-------|
| `* * * * *` | Every minute |
| `*/5 * * * *` | Every 5 minutes |
| `0 * * * *` | Every hour (on the hour) |
| `0 0 * * *` | Daily at midnight |
| `0 9 * * 1-5` | Weekdays at 9am |

### What to Observe

- [ ] First loop iteration ran immediately, then `df.wait_for_schedule()` paused until next minute
- [ ] Heartbeat timestamps are spaced ~1 minute apart
- [ ] Instance stayed in `Running` status between ticks
- [ ] `df.cancel()` stopped the scheduled job cleanly
- [ ] `df.explain()` shows WAIT_SCHEDULE node in the loop body

### Exploration

```sql
-- Visualize a cron schedule without running it (dry-run)
SELECT df.explain(
    @> (
        'SELECT ''tick'' AS status'
        ~> df.wait_for_schedule('*/5 * * * *')
    )
);

-- Try df.wait_for_schedule() outside a loop (one-shot delayed execution)
-- This runs once, at the next minute boundary, then completes
SELECT df.start(
    df.wait_for_schedule('* * * * *')
    ~> 'INSERT INTO playground.logs (msg) VALUES (''One-shot scheduled task ran!'')',
    'one-shot-schedule'
);

SELECT pg_sleep(70);
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'one-shot-schedule' LIMIT 1)
);
-- Expected: 'Completed' (ran once and finished)
```

---

# Part 2: Cross-Cutting Testing (Pick 2 or More)

---

## Cross-Cutting A: Monitoring & Debugging

**Goal:** Explore all the monitoring and debugging tools available.

### Monitoring Functions

```sql
-- List all instances (yours only — RLS enforced)
SELECT instance_id, label, status FROM df.list_instances();

-- Filter by status
SELECT * FROM df.list_instances('Completed');
SELECT * FROM df.list_instances('Failed');
SELECT * FROM df.list_instances('Running');

-- Detailed instance info
SELECT * FROM df.instance_info('REPLACE_WITH_AN_INSTANCE_ID');

-- Node-level execution details (the graph nodes)
SELECT node_type, query, result_name, status, result
FROM df.instance_nodes('REPLACE_WITH_AN_INSTANCE_ID');

-- For loops: see execution history (last 5 iterations)
-- Use an instance ID from a loop scenario:
SELECT * FROM df.instance_executions('REPLACE_WITH_LOOP_INSTANCE_ID');

-- System-wide metrics
SELECT * FROM df.metrics();
```

### Background Worker Health

```sql
-- Check background worker heartbeat
SELECT epoch_id, started_at, last_seen_at,
       now() - last_seen_at AS heartbeat_age
FROM df._worker_epoch;
-- Healthy: heartbeat_age < 15 seconds
```

```bash
# View background worker logs (run in terminal, not psql)
tail -f ~/.pgrx/17.log
```

### df.explain() — Dry-Run vs Live

```sql
-- DRY-RUN: Preview a graph without executing it
SELECT df.explain(
    'SELECT 1' |=> 'a'
    ~> 'SELECT 2' |=> 'b'
    ~> df.if(
        'SELECT $a > 0',
        'SELECT ''condition true''',
        'SELECT ''condition false'''
    )
);

-- LIVE: See execution status of an already-running instance
SELECT df.explain('REPLACE_WITH_AN_INSTANCE_ID');
```

### Checklist

- [ ] `df.list_instances()` shows all your completed scenarios
- [ ] Status filter works (Completed, Failed, Running)
- [ ] `df.instance_nodes()` shows per-node timing and results
- [ ] `df.metrics()` returns system-wide counts
- [ ] Background worker heartbeat is recent (< 15s)
- [ ] `df.explain()` dry-run shows graph structure without executing
- [ ] `df.explain()` live shows ✓/✗/⏳/○ status markers

---

## Cross-Cutting B: Conditionals & Branching

**Goal:** Test conditional execution with `df.if()` and the `?>` / `!>` operators.

### Steps

```sql
-- Test: condition is TRUE → then-branch executes
SELECT df.start(
    df.if(
        'SELECT true',
        'INSERT INTO playground.logs (msg) VALUES (''then-branch ran'')',
        'INSERT INTO playground.logs (msg) VALUES (''else-branch ran'')'
    ),
    'if-true-test'
);

-- Test: condition is FALSE → else-branch executes
SELECT df.start(
    df.if(
        'SELECT false',
        'INSERT INTO playground.logs (msg) VALUES (''then-branch ran'')',
        'INSERT INTO playground.logs (msg) VALUES (''else-branch ran'')'
    ),
    'if-false-test'
);

-- Wait and check which branches ran
SELECT pg_sleep(3);
SELECT msg, created_at FROM playground.logs ORDER BY created_at DESC LIMIT 4;
```

```sql
-- Test with a realistic condition against real data
SELECT df.start(
    'SELECT COUNT(*) > 3 FROM playground.task_queue WHERE status = ''pending'''
        ?> 'INSERT INTO playground.logs (msg) VALUES (''Many pending tasks — alert!'')'
        !> 'INSERT INTO playground.logs (msg) VALUES (''Task queue looks healthy'')',
    'task-check'
);

-- Visualize the IF graph
SELECT df.explain(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'task-check' LIMIT 1)
);
```

```sql
-- Test truthiness rules: numeric condition
SELECT df.start(
    df.if(
        'SELECT 0',                                     -- falsy (zero)
        'SELECT ''should not run'' AS result',
        'SELECT ''zero is falsy'' AS result'
    ),
    'truthiness-test'
);

SELECT pg_sleep(2);
SELECT df.result(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'truthiness-test' LIMIT 1)
);
-- Expected: "zero is falsy"
```

### Checklist

- [ ] True condition → then-branch executed
- [ ] False condition → else-branch executed
- [ ] `?>` and `!>` operator syntax works
- [ ] `df.explain()` shows IF tree with `✓ then:` and `✗ else:` labels
- [ ] Numeric truthiness works (0 = falsy, non-zero = truthy)

---

## Cross-Cutting C: Signals (Human-in-the-Loop)

**Goal:** Test `df.wait_for_signal()` and `df.signal()` for event-driven coordination.

> **Requires two psql sessions.** Open a second terminal and connect:
> ```bash
> ~/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -d postgres
> ```

### Steps

**Session 1 — Start a workflow that waits for approval**

```sql
SELECT df.start(
    'INSERT INTO playground.logs (msg) VALUES (''Requesting approval...'')'
    ~> df.wait_for_signal('approval', 120)  -- Wait up to 120 seconds
        |=> 'approval_result'
    ~> 'INSERT INTO playground.logs (msg)
        VALUES (''Approval received: '' || $approval_result)',
    'signal-test'
);

-- Note the instance ID
SELECT instance_id FROM df.list_instances() WHERE label = 'signal-test' LIMIT 1;
-- Should show status = 'Running' (waiting for signal)
```

**Session 2 — Send the approval signal**

```sql
-- Replace with the instance ID from Session 1
SELECT df.signal(
    'REPLACE_ME',
    'approval',
    '{"approved": true, "approver": "tester@example.com"}'
);
```

**Session 1 — Verify the workflow resumed**

```sql
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'signal-test' LIMIT 1)
);
-- Expected: 'Completed'

-- Check the signal data was received
SELECT msg FROM playground.logs WHERE msg LIKE '%Approval%' ORDER BY created_at DESC LIMIT 2;

-- Look at the captured result
SELECT df.result(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'signal-test' LIMIT 1)
);
```

### Checklist

- [ ] Workflow paused at `df.wait_for_signal()` (status = Running)
- [ ] `df.signal()` from another session woke the workflow
- [ ] Signal data was correctly passed through `|=> 'approval_result'`
- [ ] Workflow completed after receiving the signal

### Exploration

```sql
-- Test signal timeout: start a signal wait with 5-second timeout, DON'T send signal
SELECT df.start(
    df.wait_for_signal('never-sent', 5) |=> 'timeout_result'
    ~> 'INSERT INTO playground.logs (msg)
        VALUES (''Timed out: '' || $timeout_result)',
    'signal-timeout-test'
);

-- Wait 8 seconds and check
SELECT pg_sleep(8);
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'signal-timeout-test' LIMIT 1)
);
-- What does the timeout result look like? Check:
SELECT df.result(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'signal-timeout-test' LIMIT 1)
);
```

---

## Cross-Cutting D: Replay & Restart (Bonus)

**Goal:** Verify that durable functions survive extension drop/recreate (simulating crash recovery).

> ⚠️ **This is destructive** — it will cancel all running instances. Only do this after completing other scenarios.

### Steps

```sql
-- Step 1: Start a long-running loop
TRUNCATE playground.heartbeats;

SELECT df.start(
    @> (
        'INSERT INTO playground.heartbeats (ts) VALUES (now())'
        ~> df.sleep(2)
    ),
    'durability-test'
);

-- Step 2: Wait for a few heartbeats
SELECT pg_sleep(6);
SELECT COUNT(*) AS before_restart FROM playground.heartbeats;
-- Note this number

-- Step 3: Drop and recreate the extension
DROP EXTENSION pg_durable CASCADE;
-- Wait 20 seconds for the background worker to fully shut down
SELECT pg_sleep(20);
CREATE EXTENSION pg_durable;
-- Wait for the background worker to reinitialize
SELECT pg_sleep(5);

-- Step 4: Check — what happened to the loop?
SELECT * FROM df.list_instances();
-- Note: instances from before the drop are gone (clean slate)

-- Step 5: Start a new instance to verify the system works
SELECT df.start('SELECT ''Extension recovered!'' AS msg', 'recovery-test');
SELECT pg_sleep(3);
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'recovery-test' LIMIT 1)
);
-- Expected: 'Completed'
```

### Checklist

- [ ] Extension drop stopped all running functions
- [ ] Extension recreate initialized a fresh background worker
- [ ] New functions work correctly after recreation
- [ ] No errors in background worker logs during the process

---

# Part 3: AI Agent Experience

**Goal:** Test whether Copilot (or another AI assistant) can generate correct pg_durable SQL, and evaluate the developer experience of AI-assisted workflow creation.

### Step 1 — Ask Copilot to Generate a Workflow

Open Copilot Chat in VS Code and try one or more of these prompts:

**Prompt A** (ETL):
> "Write a pg_durable durable function that: reads all pending orders from playground.orders, marks them as 'processing', waits 3 seconds, then marks them as 'completed'. Use the ~> operator for sequencing and |=> to capture the order count."

**Prompt B** (Parallel):
> "Create a pg_durable workflow that counts rows in playground.users, playground.orders, and playground.task_queue in parallel using df.join3(), then logs a completion message to playground.logs."

**Prompt C** (Conditional):
> "Write a pg_durable durable function that checks if there are more than 2 pending tasks in playground.task_queue. If yes, log 'High load detected' to playground.logs. If no, log 'System healthy'. Use the ?> and !> operators."

**Prompt D** (Loop):
> "Create a pg_durable durable function that loops, incrementing a counter in a table each iteration, and breaks out of the loop when the counter reaches 5. Return a JSON result with the final count."

### Step 2 — Review the Generated SQL

Before running, check:
- [ ] Does it use `df.start()` to execute the workflow?
- [ ] Are operators (`~>`, `|=>`, `&`, `?>`, `!>`, `@>`) used correctly?
- [ ] Is the SQL syntax valid (proper quoting of strings with `''`)?
- [ ] Did it use function variants (`df.seq()`, `df.join()`, etc.) or operator variants?

### Step 3 — Run It

Paste the generated SQL into `psql` and verify:
- [ ] It starts without errors
- [ ] It completes successfully (`df.status()` → Completed)
- [ ] The result is correct (`df.result()`, query the affected tables)
- [ ] `df.explain()` shows the expected graph structure

### What to Note

- Did Copilot produce **correct** pg_durable syntax on the first try?
- What mistakes did it make (if any)?
- Was the generated code easy to understand?
- Would you have written it differently?

---

# Part 4: Feedback

Please fill out this section after completing the bug bash. Be honest — critical feedback is the most valuable.

## Per-Scenario Ratings

| Scenario | Completed? | Difficulty (1=Easy, 5=Hard) | Notes |
|----------|-----------|---------------------------|-------|
| 1: Getting Started | ☐ | __ / 5 | |
| 2: ETL Pipeline | ☐ | __ / 5 | |
| 3: Variables | ☐ | __ / 5 | |
| 4: Parallel (optional) | ☐ | __ / 5 | |
| 5: Loops (optional) | ☐ | __ / 5 | |
| 6: Scheduling (optional) | ☐ | __ / 5 | |

## Cross-Cutting Ratings

| Area | Tried? | Rating (1=Poor, 5=Great) | Notes |
|------|--------|-------------------------|-------|
| Monitoring & Debugging | ☐ | __ / 5 | |
| Conditionals / Branching | ☐ | __ / 5 | |
| Signals | ☐ | __ / 5 | |
| Replay & Restart | ☐ | __ / 5 | |

## Developer Experience Questions

1. **Was the DSL syntax intuitive?** (operators like `~>`, `|=>`, `&`, `?>`)
   > _Your answer:_

2. **Was `df.explain()` output helpful for understanding what happened?**
   > _Your answer:_

3. **How was the debugging experience when something went wrong?**
   > _Your answer:_

4. **Were `df.list_instances()`, `df.status()`, `df.instance_nodes()` sufficient for monitoring?**
   > _Your answer:_

5. **Did the AI agent generate correct pg_durable syntax?** What mistakes (if any)?
   > _Your answer:_

6. **What was the most confusing part of the experience?**
   > _Your answer:_

7. **What would you change about the API?**
   > _Your answer:_

8. **Any features you wished existed?**
   > _Your answer:_

## Bugs Found

| # | Scenario | Description | Severity (Low/Med/High) | Instance ID | Steps to Reproduce |
|---|----------|-------------|------------------------|-------------|-------------------|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |
| 4 | | | | | |
| 5 | | | | | |

---

## Cleanup

When you're done, stop the test server:

```bash
./scripts/pg-stop.sh
```

---

*Thank you for participating in the bug bash! Your feedback directly shapes the pg_durable developer experience.*






