# pg_durable User Guide

**Durable Workflows for PostgreSQL**

pg_durable is a PostgreSQL extension that brings durable, fault-tolerant workflow execution directly into your database. Define workflows using a SQL-native DSL, and let the extension handle persistence, retries, and scheduling.

---

## Table of Contents

1. [Overview](#overview)
2. [Getting Started](#getting-started)
3. [Test Data Setup](#test-data-setup)
4. [Core Concepts](#core-concepts)
5. [DSL Reference](#dsl-reference)
6. [Workflow Examples](#workflow-examples)
7. [Loops & Cron Jobs](#loops--cron-jobs)
8. [Monitoring Functions](#monitoring-functions)
9. [Troubleshooting](#troubleshooting)

---

## Overview

### What is pg_durable?

pg_durable enables you to define and execute **durable workflows** entirely within PostgreSQL. Unlike traditional job queues or external workflow engines, pg_durable:

- **Lives in your database** - No external services to manage
- **Uses SQL syntax** - Define workflows with familiar SQL functions and operators
- **Is fault-tolerant** - Workflows survive crashes and restarts
- **Supports scheduling** - Built-in cron-style scheduling for recurring jobs
- **Provides visibility** - Monitor workflow status directly via SQL queries

### Key Features

| Feature | Description |
|---------|-------------|
| **SQL DSL** | Define workflows using `durable.sql()`, `~>`, `\|=>` operators |
| **Sequential Execution** | Chain steps with `~>` operator |
| **Parallel Execution** | Run steps concurrently with `durable.join()` |
| **Conditional Logic** | Branch with `durable.if()` |
| **Timers & Delays** | Sleep with `durable.sleep()` |
| **Cron Scheduling** | Schedule with `durable.wait_for_schedule()` |
| **Eternal Loops** | Create forever-running jobs with `durable.loop()` |
| **Variable Substitution** | Pass results between steps using `$name` |
| **Labels** | Tag workflows with friendly names |
| **Monitoring** | Query workflow status, history, and metrics |

---

## Getting Started

### Enable the Extension

```sql
CREATE EXTENSION pg_durable;
```

### Your First Workflow

```sql
-- Execute a simple SQL query as a durable workflow
SELECT durable.start(
    durable.sql('SELECT ''Hello, durable world!''')
);
-- Returns: a1b2c3d4 (8-character instance ID)
```

### Check the Result

```sql
-- List all workflows
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
-- Run this script to create sample schemas and data for testing workflows
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

-- Logs table for workflow output
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

After running this script, you can test workflows against the `playground` schema.

---

## Core Concepts

### Workflow Lifecycle

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

Every workflow gets a unique 8-character hex ID (e.g., `a1b2c3d4`). Use this ID to:
- Check status: `SELECT durable.status('a1b2c3d4')`
- Get result: `SELECT durable.result('a1b2c3d4')`
- Cancel: `SELECT durable.cancel('a1b2c3d4')`

### Durability

Workflows are persisted to disk. If PostgreSQL crashes:
- Completed steps are not re-executed
- In-progress steps resume from the last checkpoint
- Pending steps execute when the server restarts

---

## DSL Reference

### Functions

| Function | Description | Example |
|----------|-------------|---------|
| `durable.sql(query)` | Execute a SQL query | `durable.sql('SELECT 1')` |
| `durable.sleep(seconds)` | Pause for N seconds | `durable.sleep(60)` |
| `durable.wait_for_schedule(cron)` | Wait until cron expression matches | `durable.wait_for_schedule('0 * * * *')` |
| `durable.join(a, b)` | Execute a and b in parallel | `durable.join(a, b)` |
| `durable.join3(a, b, c)` | Execute three in parallel | `durable.join3(a, b, c)` |
| `durable.if(cond, then, else)` | Conditional branching | `durable.if(cond, then_branch, else_branch)` |
| `durable.loop(body)` | Repeat forever (eternal) | `durable.loop(body)` |
| `durable.start(workflow, label)` | Start a workflow | `durable.start(wf, 'my-job')` |
| `durable.cancel(id, reason)` | Cancel a workflow | `durable.cancel('a1b2c3d4', 'Done')` |
| `durable.status(id)` | Get workflow status | `durable.status('a1b2c3d4')` |
| `durable.result(id)` | Get workflow result | `durable.result('a1b2c3d4')` |

### Operators

| Operator | Name | Description | Example |
|----------|------|-------------|---------|
| `~>` | Sequence | Run left, then right | `a ~> b ~> c` |
| `\|=>` | Name | Name the result for later use | `durable.sql('...') \|=> 'myvar'` |

### Variable Substitution

Use `$name` to reference named results in subsequent steps:

```sql
SELECT durable.start(
    durable.sql('SELECT 100 as amount') |=> 'total' ~>
    durable.sql('SELECT $total * 2 as doubled')
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

## Workflow Examples

### 1. Simple Query

```sql
SELECT durable.start(
    durable.sql('SELECT COUNT(*) FROM playground.users WHERE active = true'),
    'count-active-users'
);
```

### 2. Sequential Steps

```sql
SELECT durable.start(
    durable.sql('INSERT INTO playground.logs (msg) VALUES (''Step 1: Starting'')') ~>
    durable.sql('INSERT INTO playground.logs (msg) VALUES (''Step 2: Processing'')') ~>
    durable.sql('INSERT INTO playground.logs (msg) VALUES (''Step 3: Complete'')'),
    'three-step-workflow'
);
```

### 3. Multi-Step ETL

```sql
SELECT durable.start(
    durable.sql('DELETE FROM playground.target WHERE loaded_at < now() - interval ''1 day''') ~>
    durable.sql('UPDATE playground.staging SET processed_at = now() WHERE processed_at IS NULL') ~>
    durable.sql('INSERT INTO playground.target (data, source_id, processed_at) 
                 SELECT data, source_id, processed_at FROM playground.staging 
                 WHERE processed_at IS NOT NULL'),
    'daily-etl'
);
```

### 4. With Variables

```sql
SELECT durable.start(
    durable.sql('SELECT id FROM playground.orders WHERE status = ''pending'' LIMIT 1') |=> 'order_id' ~>
    durable.sql('UPDATE playground.orders SET status = ''processing'' WHERE id = $order_id') ~>
    durable.sleep(2) ~>
    durable.sql('UPDATE playground.orders SET status = ''completed'', processed_at = now() WHERE id = $order_id'),
    'process-order'
);
```

### 5. Parallel Execution

```sql
SELECT durable.start(
    durable.join(
        durable.sql('SELECT COUNT(*) as user_count FROM playground.users'),
        durable.sql('SELECT COUNT(*) as order_count FROM playground.orders')
    ) ~>
    durable.sql('INSERT INTO playground.logs (msg) VALUES (''Parallel counts complete'')'),
    'parallel-counts'
);
```

### 6. Conditional Logic

```sql
SELECT durable.start(
    durable.if(
        durable.sql('SELECT COUNT(*) > 3 FROM playground.task_queue WHERE status = ''pending'''),
        durable.sql('INSERT INTO playground.logs (msg, level) VALUES (''High task load detected!'', ''warning'')'),
        durable.sql('INSERT INTO playground.logs (msg) VALUES (''Task queue normal'')')
    ),
    'check-task-load'
);
```

### 7. Task Queue Processor

```sql
SELECT durable.start(
    durable.sql('
        UPDATE playground.task_queue 
        SET status = ''processing'', started_at = now()
        WHERE id = (
            SELECT id FROM playground.task_queue 
            WHERE status = ''pending'' 
            ORDER BY priority DESC, created_at 
            LIMIT 1 
            FOR UPDATE SKIP LOCKED
        )
        RETURNING id, payload
    ') |=> 'task' ~>
    durable.sleep(1) ~>
    durable.sql('
        UPDATE playground.task_queue 
        SET status = ''completed'', completed_at = now()
        WHERE status = ''processing''
    '),
    'process-next-task'
);
```

---

## Loops & Cron Jobs

### Eternal Loops

Use `durable.loop()` to create workflows that run forever. Each iteration creates a new execution with fresh state (via continue-as-new).

```sql
-- Simple heartbeat every 30 seconds
SELECT durable.start(
    durable.loop(
        durable.sql('INSERT INTO playground.heartbeats (ts) VALUES (now())') ~>
        durable.sleep(30)
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
        durable.wait_for_schedule('* * * * *') ~>
        durable.sql('INSERT INTO playground.logs (msg) VALUES (''Minute tick: '' || now()::text)')
    ),
    'every-minute-tick'
);

-- Every 5 minutes: check for pending tasks
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('*/5 * * * *') ~>
        durable.sql('SELECT COUNT(*) as pending FROM playground.task_queue WHERE status = ''pending''') |=> 'count' ~>
        durable.sql('INSERT INTO playground.logs (msg) VALUES (''Pending tasks: '' || $count)')
    ),
    'task-monitor-5min'
);

-- Hourly: clean up old logs
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('0 * * * *') ~>
        durable.sql('DELETE FROM playground.logs WHERE created_at < now() - interval ''24 hours''')
    ),
    'hourly-log-cleanup'
);

-- Daily at midnight: archive completed orders
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('0 0 * * *') ~>
        durable.sql('
            UPDATE playground.orders 
            SET status = ''archived'' 
            WHERE status = ''completed'' 
            AND processed_at < now() - interval ''7 days''
        ')
    ),
    'daily-order-archive'
);

-- Weekdays at 9am: generate report
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('0 9 * * 1-5') ~>
        durable.sql('SELECT playground.generate_report(''daily_summary'')')
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

## Monitoring Functions

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

**Columns:** `instance_id`, `label`, `orchestration_name`, `status`, `execution_count`, `output`

### Instance Details

```sql
SELECT * FROM durable.instance_info('a1b2c3d4');
```

**Columns:** `instance_id`, `label`, `orchestration_name`, `orchestration_version`, `current_execution_id`, `status`, `output`

### Execution History

For loops and retried workflows, see the execution history:

```sql
-- Last 5 executions (default)
SELECT * FROM durable.instance_executions('a1b2c3d4');

-- Last 20 executions
SELECT * FROM durable.instance_executions('a1b2c3d4', 20);
```

**Columns:** `execution_id`, `status`, `event_count`, `duration_ms`, `output`

### Workflow Nodes

See the workflow graph structure:

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

## Troubleshooting

### Extension Not Loading

```sql
-- Check if extension is installed
SELECT * FROM pg_extension WHERE extname = 'pg_durable';

-- Check shared_preload_libraries
SHOW shared_preload_libraries;
```

### Background Worker Not Starting

Check PostgreSQL logs for:
```
LOG:  pg_durable: duroxide background worker starting...
LOG:  pg_durable: duroxide runtime started, processing orchestrations...
```

### Workflow Stuck in "Running"

```sql
-- Check execution history
SELECT * FROM durable.instance_executions('instance_id');

-- Check if there are errors
SELECT * FROM durable.instance_info('instance_id');

-- Cancel if needed
SELECT durable.cancel('instance_id', 'Manual intervention');
```

### View Running Workflows

```sql
-- See all running workflows with labels
SELECT instance_id, label, status 
FROM durable.list_instances('Running');
```

### Debug Database Path

```sql
SELECT durable.debug_db_path();
```

---

## Quick Reference Card

```sql
-- Start a workflow
SELECT durable.start(durable.sql('...'), 'optional-label');

-- Chain steps
SELECT durable.start(step1 ~> step2 ~> step3);

-- Name a result
SELECT durable.start(durable.sql('SELECT 1') |=> 'myvar' ~> ...);

-- Use a named result  
durable.sql('SELECT $myvar * 2')

-- Sleep
durable.sleep(60)  -- 60 seconds

-- Cron schedule
durable.wait_for_schedule('*/5 * * * *')  -- every 5 min

-- Parallel
durable.join(a, b)

-- Conditional
durable.if(condition, then_branch, else_branch)

-- Loop forever
durable.loop(body)

-- Monitor
SELECT * FROM durable.list_instances();
SELECT * FROM durable.instance_info('id');
SELECT durable.status('id');
SELECT durable.result('id');

-- Cancel
SELECT durable.cancel('id', 'reason');
```
