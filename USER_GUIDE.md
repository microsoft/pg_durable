# pg_durable User Guide

**Durable SQL Functions for PostgreSQL**

pg_durable is a PostgreSQL extension that brings durable, fault-tolerant function execution directly into your database. Define durable SQL functions using a SQL-native DSL, and let the extension handle persistence, retries, and scheduling.

---

## Table of Contents

1. [Overview](#overview)
2. [Getting Started](#getting-started)
3. [Test Data Setup](#test-data-setup)
4. [Core Concepts](#core-concepts)
5. [DSL Reference](#dsl-reference)
6. [Function Examples](#function-examples)
7. [Loops & Cron Jobs](#loops--cron-jobs)
8. [Visualizing Functions](#visualizing-functions)
9. [Monitoring](#monitoring)

---

## Overview

### What is pg_durable?

pg_durable enables you to define and execute **durable SQL functions** entirely within PostgreSQL. Unlike traditional job queues or external workflow engines, pg_durable:

- **Lives in your database** - No external services to manage
- **Uses SQL syntax** - Define functions with familiar SQL operators
- **Is fault-tolerant** - Functions survive crashes and restarts
- **Supports scheduling** - Built-in cron-style scheduling for recurring jobs
- **Provides visibility** - Monitor function status directly via SQL queries

### Key Features

| Feature | Description |
|---------|-------------|
| **SQL DSL** | Define functions using plain SQL strings with `~>`, `\|=>` operators |
| **Sequential Execution** | Chain steps with `~>` operator |
| **Parallel Execution** | Run steps concurrently with `durable.join()` |
| **Conditional Logic** | Branch with `durable.if()` |
| **Timers & Delays** | Sleep with `durable.sleep()` |
| **Cron Scheduling** | Schedule with `durable.wait_for_schedule()` |
| **Eternal Loops** | Create forever-running jobs with `durable.loop()` |
| **Variable Substitution** | Pass results between steps using `$name` |
| **Labels** | Tag functions with friendly names |
| **Visualization** | Preview function structure with `durable.explain()` |
| **Monitoring** | Query function status, history, and metrics |

---

## Getting Started

### Enable the Extension

```sql
CREATE EXTENSION pg_durable;
```

### Your First Durable Function

```sql
-- Execute a simple SQL query as a durable function
SELECT durable.start('SELECT ''Hello, durable world!''');
-- Returns: a1b2c3d4 (8-character instance ID)
```

### Check the Result

```sql
-- List all functions
SELECT * FROM durable.list_instances();

-- Get result of a specific instance
SELECT durable.result('a1b2c3d4');
```

---

## Test Data Setup

Copy and paste this script into `psql` to create test schemas and sample data for the examples in this guide:

```sql
-- ============================================================================
-- pg_durable Test Data Setup
-- Run this script to create sample schemas and data for testing functions
-- ============================================================================

-- Create a playground schema for testing
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

-- Logs table for function output
CREATE TABLE IF NOT EXISTS playground.logs (
    id SERIAL PRIMARY KEY,
    msg TEXT NOT NULL,
    level VARCHAR(20) DEFAULT 'info',
    created_at TIMESTAMP DEFAULT now()
);

-- Heartbeats table for cron examples
CREATE TABLE IF NOT EXISTS playground.heartbeats (
    id SERIAL PRIMARY KEY,
    ts TIMESTAMP NOT NULL,
    source VARCHAR(100) DEFAULT 'pg_durable'
);

-- Metrics table for aggregation examples
CREATE TABLE IF NOT EXISTS playground.metrics (
    id SERIAL PRIMARY KEY,
    metric_name VARCHAR(100) NOT NULL,
    metric_value DECIMAL(15,4) NOT NULL,
    recorded_at TIMESTAMP DEFAULT now()
);

-- Staging table for ETL examples
CREATE TABLE IF NOT EXISTS playground.staging (
    id SERIAL PRIMARY KEY,
    data JSONB,
    source_id INTEGER,
    processed_at TIMESTAMP
);

-- Target table for ETL examples
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

-- Insert some staging data for ETL
INSERT INTO playground.staging (data, source_id) VALUES
    ('{"product": "Widget A", "qty": 10}', 1001),
    ('{"product": "Widget B", "qty": 25}', 1002),
    ('{"product": "Gadget X", "qty": 5}', 1003)
ON CONFLICT DO NOTHING;

-- Insert sample metrics
INSERT INTO playground.metrics (metric_name, metric_value) VALUES
    ('cpu_usage', 45.5),
    ('memory_usage', 72.3),
    ('disk_io', 15.8),
    ('network_in', 1024.0),
    ('network_out', 512.5)
ON CONFLICT DO NOTHING;

-- Create helper function for reports (used in examples)
CREATE OR REPLACE FUNCTION playground.generate_report(report_type TEXT)
RETURNS TEXT AS $$
BEGIN
    INSERT INTO playground.logs (msg, level) 
    VALUES ('Generated report: ' || report_type, 'info');
    RETURN 'Report generated: ' || report_type || ' at ' || now()::text;
END;
$$ LANGUAGE plpgsql;

-- Summary
SELECT 'Test data setup complete!' as status;
SELECT 'Users: ' || COUNT(*) FROM playground.users;
SELECT 'Orders: ' || COUNT(*) FROM playground.orders;
SELECT 'Tasks: ' || COUNT(*) FROM playground.task_queue;
```

After running this script, you can test durable functions against the `playground` schema.

---

## Core Concepts

### Function Lifecycle

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Define    │ ──► │   Start     │ ──► │  Running    │
│  (DSL)      │     │  (returns   │     │  (bg work)  │
│             │     │   inst_id)  │     │             │
└─────────────┘     └─────────────┘     └──────┬──────┘
                                               │
                         ┌─────────────────────┼─────────────────────┐
                         ▼                     ▼                     ▼
                  ┌─────────────┐       ┌─────────────┐       ┌─────────────┐
                  │  Completed  │       │   Failed    │       │  Cancelled  │
                  └─────────────┘       └─────────────┘       └─────────────┘
```

### Instance IDs

Every durable function gets a unique 8-character hex ID (e.g., `a1b2c3d4`). Use this ID to:
- Check status: `SELECT durable.status('a1b2c3d4')`
- Get result: `SELECT durable.result('a1b2c3d4')`
- Cancel: `SELECT durable.cancel('a1b2c3d4')`

### Durability

Functions are persisted to disk. If PostgreSQL crashes:
- Completed steps are not re-executed
- In-progress steps resume from the last checkpoint
- Pending steps execute when the server restarts

---

## DSL Reference

### Auto-Wrap SQL

Plain SQL strings are automatically wrapped - no need for explicit `durable.sql()` calls:

```sql
-- These are equivalent:
'SELECT 1' ~> 'SELECT 2'
durable.sql('SELECT 1') ~> durable.sql('SELECT 2')
```

### Functions

| Function | Description | Example |
|----------|-------------|---------|
| `durable.sleep(seconds)` | Pause for N seconds | `durable.sleep(60)` |
| `durable.wait_for_schedule(cron)` | Wait until cron matches | `durable.wait_for_schedule('0 * * * *')` |
| `durable.join(a, b)` | Execute in parallel | `durable.join('SELECT 1', 'SELECT 2')` |
| `durable.join3(a, b, c)` | Three in parallel | `durable.join3(a, b, c)` |
| `durable.if(cond, then, else)` | Conditional branch | `durable.if('SELECT true', a, b)` |
| `durable.loop(body)` | Repeat forever | `durable.loop(body)` |
| `durable.start(func, label)` | Start function | `durable.start('SELECT 1', 'job')` |
| `durable.cancel(id, reason)` | Cancel function | `durable.cancel('a1b2c3d4', 'Done')` |
| `durable.status(id)` | Get status | `durable.status('a1b2c3d4')` |
| `durable.result(id)` | Get result | `durable.result('a1b2c3d4')` |
| `durable.explain(input)` | Visualize graph | `durable.explain('a1b2c3d4')` |

### Operators

| Operator | Name | Description | Example |
|----------|------|-------------|---------|
| `~>` | Sequence | Run left, then right | `'SELECT 1' ~> 'SELECT 2'` |
| `\|=>` | Name | Name result for later use | `'SELECT 1' \|=> 'myvar'` |

### Variable Substitution

Use `$name` to reference named results in subsequent steps:

```sql
SELECT durable.start(
    'SELECT 100 as amount' |=> 'total'        -- save result as $total
    ~> 'SELECT $total * 2 as doubled'         -- use $total in next step
);
```

### Cron Expression Format

```
┌───────────── minute (0-59)
│ ┌───────────── hour (0-23)
│ │ ┌───────────── day of month (1-31)
│ │ │ ┌───────────── month (1-12)
│ │ │ │ ┌───────────── day of week (0-6, Sun=0)
│ │ │ │ │
* * * * *
```

| Expression | Description |
|------------|-------------|
| `* * * * *` | Every minute |
| `*/5 * * * *` | Every 5 minutes |
| `0 * * * *` | Every hour (at :00) |
| `0 0 * * *` | Daily at midnight |
| `0 9 * * 1-5` | Weekdays at 9am |
| `0 0 1 * *` | First of each month |

---

## Function Examples

### 1. Simple Query

```sql
SELECT durable.start(
    'SELECT COUNT(*) FROM playground.users WHERE active = true',
    'count-active-users'
);
```

### 2. Sequential Steps

```sql
SELECT durable.start(
    'INSERT INTO playground.logs (msg) VALUES (''Step 1: Starting'')'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Step 2: Processing'')'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Step 3: Complete'')',
    'three-step-function'
);
```

### 3. Multi-Step ETL

```sql
SELECT durable.start(
    'DELETE FROM playground.target 
     WHERE loaded_at < now() - interval ''1 day'''                    -- cleanup
    ~> 'UPDATE playground.staging 
        SET processed_at = now() WHERE processed_at IS NULL'          -- mark
    ~> 'INSERT INTO playground.target (data, source_id, processed_at) 
        SELECT data, source_id, processed_at FROM playground.staging 
        WHERE processed_at IS NOT NULL',                              -- load
    'daily-etl'
);
```

### 4. With Variables

```sql
SELECT durable.start(
    'SELECT id FROM playground.orders 
     WHERE status = ''pending'' LIMIT 1' |=> 'order_id'               -- get order
    ~> 'UPDATE playground.orders 
        SET status = ''processing'' WHERE id = $order_id'             -- mark processing
    ~> durable.sleep(2)                                               -- simulate work
    ~> 'UPDATE playground.orders 
        SET status = ''completed'', processed_at = now() 
        WHERE id = $order_id',                                        -- complete
    'process-order'
);
```

### 5. Parallel Execution

```sql
SELECT durable.start(
    durable.join(
        'SELECT COUNT(*) as user_count FROM playground.users',        -- branch 1
        'SELECT COUNT(*) as order_count FROM playground.orders'       -- branch 2
    )                                                                 -- waits for both
    ~> 'INSERT INTO playground.logs (msg) 
        VALUES (''Parallel counts complete'')',
    'parallel-counts'
);
```

### 6. Conditional Logic

```sql
SELECT durable.start(
    durable.if(
        'SELECT COUNT(*) > 3 FROM playground.task_queue 
         WHERE status = ''pending''',                                 -- condition
        'INSERT INTO playground.logs (msg, level) 
         VALUES (''High task load!'', ''warning'')',                  -- then
        'INSERT INTO playground.logs (msg) 
         VALUES (''Task queue normal'')'                              -- else
    ),
    'check-task-load'
);
```

### 7. Task Queue Processor

```sql
SELECT durable.start(
    'UPDATE playground.task_queue 
     SET status = ''processing'', started_at = now()
     WHERE id = (
         SELECT id FROM playground.task_queue 
         WHERE status = ''pending'' 
         ORDER BY priority DESC, created_at 
         LIMIT 1 
         FOR UPDATE SKIP LOCKED
     )
     RETURNING id, payload' |=> 'task'                                -- claim task
    ~> durable.sleep(1)                                               -- process
    ~> 'UPDATE playground.task_queue 
        SET status = ''completed'', completed_at = now()
        WHERE status = ''processing''',                               -- complete
    'process-next-task'
);
```

---

## Loops & Cron Jobs

### Eternal Loops

Use `durable.loop()` to create functions that run forever. Each iteration creates a new execution with fresh state (via continue-as-new).

```sql
-- Simple heartbeat every 30 seconds
SELECT durable.start(
    durable.loop(
        'INSERT INTO playground.heartbeats (ts) VALUES (now())'
        ~> durable.sleep(30)
    ),
    'heartbeat-30s'
);
```

### Cron-Style Scheduling

Use `durable.wait_for_schedule()` with a cron expression:

```sql
-- Every minute: log a tick
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('* * * * *')
        ~> 'INSERT INTO playground.logs (msg) 
            VALUES (''Minute tick: '' || now()::text)'
    ),
    'every-minute-tick'
);

-- Every 5 minutes: check for pending tasks
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('*/5 * * * *')
        ~> 'SELECT COUNT(*) as pending FROM playground.task_queue 
            WHERE status = ''pending''' |=> 'count'
        ~> 'INSERT INTO playground.logs (msg) 
            VALUES (''Pending tasks: '' || $count)'
    ),
    'task-monitor-5min'
);

-- Hourly: clean up old logs
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('0 * * * *')
        ~> 'DELETE FROM playground.logs 
            WHERE created_at < now() - interval ''24 hours'''
    ),
    'hourly-log-cleanup'
);

-- Daily at midnight: archive completed orders
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('0 0 * * *')
        ~> 'UPDATE playground.orders 
            SET status = ''archived'' 
            WHERE status = ''completed'' 
            AND processed_at < now() - interval ''7 days'''
    ),
    'daily-order-archive'
);

-- Weekdays at 9am: generate report
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('0 9 * * 1-5')
        ~> 'SELECT playground.generate_report(''daily_summary'')'
    ),
    'weekday-morning-report'
);
```

### Stopping a Loop

```sql
-- Cancel by instance ID
SELECT durable.cancel('a1b2c3d4', 'Manual stop');

-- Find by label first, then cancel
SELECT instance_id FROM durable.list_instances() WHERE label = 'every-minute-tick';
-- Then cancel with the found ID
SELECT durable.cancel('found_id', 'Stopping cron job');
```

---

## Visualizing Functions

### durable.explain()

Use `durable.explain()` to visualize function structure. It works in two modes:

**1. Live Instance** - Pass an instance ID to see execution status:

```sql
SELECT durable.explain('a1b2c3d4');
```

Output shows status markers for each node:
```
Instance: a1b2c3d4 (my-job)
Status:   ✓ Completed
Output:   {"result": 42}

SQL |=> 'step1': SELECT 1                    ✓ Completed
→ SQL |=> 'step2': SELECT 2                  ✓ Completed
→ SQL: INSERT INTO results...               ✓ Completed
```

**2. Dry-Run Preview** - Pass a DSL expression to visualize without executing:

```sql
SELECT durable.explain($$
    'SELECT 1' |=> 'a'
    ~> 'SELECT 2' |=> 'b'
    ~> durable.if(
        'SELECT $a > 0',
        'SELECT ''yes''',
        'SELECT ''no'''
    )
$$);
```

Output shows the graph structure:
```
SQL |=> 'a': SELECT 1
→ SQL |=> 'b': SELECT 2
→ IF
    ✓ then:
      SQL: SELECT 'yes'
    ✗ else:
      SQL: SELECT 'no'
```

### Status Markers

| Marker | Meaning |
|--------|---------|
| `✓ Completed` | Node finished successfully |
| `✗ Failed` | Node encountered an error |
| `⏳ Running` | Node currently executing |
| `○ Pending` | Node waiting to execute |

### Visualizing Complex Structures

```sql
-- Parallel branches
SELECT durable.explain($$
    durable.join(
        'SELECT 1' |=> 'a',
        'SELECT 2' |=> 'b'
    )
    ~> 'SELECT $a + $b'
$$);

-- Loop with conditional
SELECT durable.explain($$
    durable.loop(
        'SELECT COUNT(*) FROM tasks WHERE status = ''pending''' |=> 'cnt'
        ~> durable.if(
            'SELECT $cnt > 0',
            'UPDATE tasks SET status = ''done'' WHERE id = 1',
            durable.sleep(60)
        )
    )
$$);
```

---

## Monitoring

### List All Instances

```sql
-- All instances
SELECT * FROM durable.list_instances();

-- Filter by status
SELECT * FROM durable.list_instances('Running');
SELECT * FROM durable.list_instances('Completed');
SELECT * FROM durable.list_instances('Failed');

-- With limit
SELECT * FROM durable.list_instances(NULL, 10);
```

**Columns:** `instance_id`, `label`, `function_name`, `status`, `execution_count`, `output`

### Instance Details

```sql
SELECT * FROM durable.instance_info('a1b2c3d4');
```

**Columns:** `instance_id`, `label`, `function_name`, `function_version`, `current_execution_id`, `status`, `output`

### Execution History

For loops and retried functions, see the execution history:

```sql
-- Last 5 executions (default)
SELECT * FROM durable.instance_executions('a1b2c3d4');

-- Last 20 executions
SELECT * FROM durable.instance_executions('a1b2c3d4', 20);
```

**Columns:** `execution_id`, `status`, `event_count`, `duration_ms`, `output`

### Function Nodes

See the function graph structure:

```sql
-- Last 5 executions (default)
SELECT * FROM durable.instance_nodes('a1b2c3d4');

-- Last 10 executions
SELECT * FROM durable.instance_nodes('a1b2c3d4', 10);
```

**Columns:** `execution_id`, `node_id`, `node_type`, `query`, `result_name`, `left_node`, `right_node`, `status`, `result`

### System Metrics

```sql
SELECT * FROM durable.metrics();
```

**Columns:** `total_instances`, `running_instances`, `completed_instances`, `failed_instances`, `total_executions`, `total_events`

### Quick Status Check

```sql
-- Status only
SELECT durable.status('a1b2c3d4');

-- Result only
SELECT durable.result('a1b2c3d4');
```

---

## Quick Reference Card

```sql
-- Start a durable function (plain SQL auto-wrapped)
SELECT durable.start('SELECT 1', 'optional-label');

-- Chain steps with ~>
SELECT durable.start(
    'SELECT 1' ~> 'SELECT 2' ~> 'SELECT 3'
);

-- Name a result with |=>
SELECT durable.start(
    'SELECT 1' |=> 'myvar' ~> 'SELECT $myvar * 2'
);

-- Sleep
durable.sleep(60)                             -- 60 seconds

-- Cron schedule  
durable.wait_for_schedule('*/5 * * * *')      -- every 5 min

-- Parallel execution
durable.join('SELECT 1', 'SELECT 2')

-- Conditional
durable.if('SELECT true', 'yes branch', 'no branch')

-- Loop forever
durable.loop(body)

-- Visualize
SELECT durable.explain('instance_id');        -- live instance
SELECT durable.explain($$ 'a' ~> 'b' $$);     -- dry-run preview

-- Monitor
SELECT * FROM durable.list_instances();
SELECT * FROM durable.instance_info('id');
SELECT durable.status('id');
SELECT durable.result('id');

-- Cancel
SELECT durable.cancel('id', 'reason');
```
