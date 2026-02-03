# pg_durable User Guide

**Durable SQL Functions for PostgreSQL**

pg_durable is a PostgreSQL extension that brings durable, fault-tolerant function execution directly into your database. Define durable SQL functions using a SQL-native DSL, and let the extension handle persistence, retries, and scheduling.

---

## Table of Contents

1. [Overview](#overview)
2. [Getting Started](#getting-started)
3. [Core Concepts](#core-concepts)
4. [DSL Reference](#dsl-reference)
5. [Condition Evaluation](#condition-evaluation)
6. [Function Examples](#function-examples)
7. [HTTP Requests](#http-requests)
8. [Durable Function Variables](#durable-function-variables)
9. [Loops & Cron Jobs](#loops--cron-jobs)
10. [Signals](#signals)
11. [Visualizing Functions](#visualizing-functions)
12. [Monitoring](#monitoring)
13. [User Isolation & Privileges](#user-isolation--privileges)
14. [Troubleshooting](#troubleshooting)
15. [Quick Reference Card](#quick-reference-card)
16. [Appendix: Test Data Setup](#appendix-test-data-setup)

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
| **SQL DSL** | Define functions using plain SQL strings with intuitive operators |
| **Sequential Execution** | Chain steps with `~>` operator |
| **Parallel Execution** | Run steps concurrently with `&` operator or `df.join()` |
| **Race Execution** | First to complete wins with `\|` operator or `df.race()` |
| **Conditional Logic** | Branch with `?>` `!>` operators or `df.if()` |
| **Timers & Delays** | Sleep with `df.sleep()` |
| **Cron Scheduling** | Schedule with `df.wait_for_schedule()` |
| **Eternal Loops** | Create forever-running jobs with `@>` operator or `df.loop()` |
| **Signals** | Wait for external events with `df.wait_for_signal()` |
| **Variable Substitution** | Pass results between steps using `$name` |
| **Labels** | Tag functions with friendly names |
| **Visualization** | Preview function structure with `df.explain()` |
| **Monitoring** | Query function status, history, and metrics |

---

## Getting Started

### Prerequisites

pg_durable requires:
1. **PostgreSQL configuration**: Add `pg_durable` to `shared_preload_libraries` in `postgresql.conf`
2. **Server restart**: Required after modifying `shared_preload_libraries`
3. **Extension creation**: Run `CREATE EXTENSION pg_durable` in your database

### Enable the Extension

```sql
CREATE EXTENSION pg_durable;
```

**What happens during `CREATE EXTENSION`:**
- pg_durable creates its own tables in the `df` schema (for tracking function graphs)
- It creates the `duroxide` schema and all required tables (for durable execution state)
- The background worker (started by `shared_preload_libraries`) detects the extension and initializes the runtime
- Within a few seconds, the system is ready to execute durable functions

> ⚠️ **Important**: The background worker waits for `CREATE EXTENSION` to complete before starting. If you include `pg_durable` in `shared_preload_libraries` but don't create the extension, the worker will remain idle and durable functions cannot execute.

### Your First Durable Function

```sql
-- Execute a simple SQL query as a durable function
SELECT df.start('SELECT ''Hello, durable world!''');
-- Returns: a1b2c3d4 (8-character instance ID)
```

### Check the Result

```sql
-- List all functions
SELECT * FROM df.list_instances();

-- Get result of a specific instance
SELECT df.result('a1b2c3d4');
```

---

> 💡 **Want to run the examples?** The examples in this guide use a `playground` schema with sample data. See the [Appendix: Test Data Setup](#appendix-test-data-setup) to install it.

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
- Check status: `SELECT df.status('a1b2c3d4')`
- Get result: `SELECT df.result('a1b2c3d4')`
- Cancel: `SELECT df.cancel('a1b2c3d4')`

### Durability

Functions are persisted to disk. If PostgreSQL crashes:
- Completed steps are not re-executed
- In-progress steps resume from the last checkpoint
- Pending steps execute when the server restarts

### Graph Construction

DSL functions build graph structures **in memory** without touching the database. Only when you call `df.start()` are the nodes written to the database:

```sql
-- This creates a JSON string representing the graph.
SELECT 'SELECT 1' ~> 'SELECT 2';
-- Returns: {"node_type":"THEN","left_node":{"node_type":"SQL","query":"SELECT 1"},"right_node":{"node_type":"SQL","query":"SELECT 2"}}

-- Only df.start() writes to the database
SELECT df.start('SELECT 1' ~> 'SELECT 2');
```

---

## DSL Reference

### Auto-Wrap SQL

Plain SQL strings are automatically wrapped - no need for explicit `df.sql()` calls:

```sql
-- These are equivalent:
'SELECT 1' ~> 'SELECT 2'
df.sql('SELECT 1') ~> df.sql('SELECT 2')
```

### Functions

| Function | Description | Example |
|----------|-------------|---------|
| `df.sleep(seconds)` | Pause for N seconds | `df.sleep(60)` |
| `df.wait_for_schedule(cron)` | Wait until cron matches | `df.wait_for_schedule('0 * * * *')` |
| `df.http(url, method, body, headers, timeout)` | Make HTTP request | `df.http('https://api.example.com', 'POST', '{"key": "value"}')` |
| `df.join(a, b)` | Execute in parallel, wait for all | `df.join('SELECT 1', 'SELECT 2')` |
| `df.join3(a, b, c)` | Three in parallel | `df.join3(a, b, c)` |
| `df.race(a, b)` | Execute in parallel, first wins | `df.race(fast_query, slow_query)` |
| `df.if(cond, then, else)` | Conditional branch | `df.if('SELECT true', a, b)` |
| `df.loop(body)` | Repeat forever | `df.loop(body)` |
| `df.loop(body, cond)` | Repeat while condition is true | `df.loop(body, 'SELECT count(*) > 0 FROM q')` |
| `df.break()` | Exit enclosing loop | `df.break()` |
| `df.break(value)` | Exit loop with return value | `df.break('{"done": true}')` |
| `df.start(func, label)` | Start function | `df.start('SELECT 1', 'job')` |
| `df.cancel(id, reason)` | Cancel function | `df.cancel('a1b2c3d4', 'Done')` |
| `df.status(id)` | Get status | `df.status('a1b2c3d4')` |
| `df.result(id)` | Get result | `df.result('a1b2c3d4')` |
| `df.explain(input)` | Visualize graph | `df.explain('a1b2c3d4')` |
| `df.setvar(name, value)` | Set durable function variable | `df.setvar('api_url', 'https://...')` |
| `df.getvar(name)` | Get durable function variable | `df.getvar('api_url')` |
| `df.unsetvar(name)` | Remove durable function variable | `df.unsetvar('api_url')` |
| `df.clearvars()` | Clear all durable function variables | `df.clearvars()` |
| `df.wait_for_signal(name)` | Wait for external signal | `df.wait_for_signal('approval')` |
| `df.wait_for_signal(name, timeout)` | Wait with timeout (seconds) | `df.wait_for_signal('approval', 3600)` |
| `df.signal(id, name, data)` | Send signal to instance | `df.signal('a1b2', 'go', '{}')` |

### Operators

| Operator | Name | Description | Example |
|----------|------|-------------|---------|
| `~>` | Sequence | Run left, then right | `'SELECT 1' ~> 'SELECT 2'` |
| `\|=>` | Name | Name result for later use | `'SELECT 1' \|=> 'myvar'` |
| `&` | Join | Run in parallel, wait for all | `'SELECT 1' & 'SELECT 2'` |
| `\|` | Race | Run in parallel, first wins | `fast_query \| slow_query` |
| `?>` | If-Then | Conditional then branch | `cond ?> then_branch` |
| `!>` | Else | Conditional else branch | `cond ?> then !> else` |
| `@>` | Loop | Repeat forever (prefix) | `@> body` |

### Operator Examples

```sql
-- Join: run both in parallel, wait for all
SELECT df.start('SELECT 1' & 'SELECT 2');

-- Race: run both, first to complete wins
SELECT df.start(
    'SELECT quick_result()' | df.sleep(30)  -- timeout after 30s
);

-- If-then-else with operators
SELECT df.start(
    'SELECT count(*) > 10 FROM orders' 
        ?> 'SELECT ''high volume'''
        !> 'SELECT ''low volume'''
);

-- Loop with operator (prefix)
SELECT df.start(
    @> ('INSERT INTO heartbeats (ts) VALUES (now())' ~> df.sleep(60)),
    'heartbeat-job'
);
```

### Variable Substitution

Use `$name` to reference named results in subsequent steps:

```sql
SELECT df.start(
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

## Condition Evaluation

When using conditional operators (`?>`, `!>`), `df.if()`, or loop conditions (`df.loop(body, condition)`), pg_durable needs to interpret SQL results as boolean values. This section explains how arbitrary data types are evaluated for truthiness.

### How SQL Results Are Evaluated

When a condition SQL query executes, pg_durable:

1. **Extracts the first column of the first row** from the result
2. **Evaluates that value for truthiness** using the rules below

```sql
-- Example: condition evaluates the first column of first row
SELECT df.start(
    'SELECT count(*) > 10 FROM orders'   -- Returns: true or false
        ?> 'SELECT ''high volume'''
        !> 'SELECT ''low volume'''
);
```

### Truthiness Rules by Type

| Type | Truthy | Falsy |
|------|--------|-------|
| **Boolean** | `true`, `t` | `false`, `f` |
| **Number** | Any non-zero value | `0`, `0.0` |
| **String** | `'true'`, `'t'`, `'yes'`, `'1'`, any non-empty string | `'false'`, `'f'`, `'no'`, `'0'`, empty string `''` |
| **Array/JSON Array** | Non-empty array `[1,2,3]` | Empty array `[]` |
| **Object/JSON Object** | Non-empty object `{"a":1}` | Empty object `{}` |
| **NULL** | — | Always falsy |

### Examples

```sql
-- Boolean expressions (most common)
'SELECT true'                              -- ✓ truthy
'SELECT false'                             -- ✗ falsy
'SELECT count(*) > 0 FROM users'           -- ✓ truthy if count > 0
'SELECT EXISTS(SELECT 1 FROM orders)'      -- ✓ truthy if exists

-- Numeric comparisons
'SELECT 1'                                 -- ✓ truthy (non-zero)
'SELECT 0'                                 -- ✗ falsy (zero)
'SELECT count(*) FROM empty_table'         -- ✗ falsy (returns 0)

-- String conditions
'SELECT ''yes'''                           -- ✓ truthy
'SELECT ''no'''                            -- ✗ falsy
'SELECT status FROM orders WHERE id = 1'   -- ✓ truthy if non-empty string

-- NULL handling
'SELECT NULL'                              -- ✗ falsy
'SELECT name FROM users WHERE id = 999'    -- ✗ falsy if no rows (NULL)
```

### Best Practices

1. **Use explicit boolean expressions** for clarity:

```sql
-- Good: explicit boolean
'SELECT count(*) > 0 FROM pending_tasks'

-- Works but less clear: relies on numeric truthiness
'SELECT count(*) FROM pending_tasks'
```

2. **Handle NULL explicitly** when querying data that might not exist:

```sql
-- Good: COALESCE ensures a boolean result
'SELECT COALESCE(active, false) FROM users WHERE id = $user_id'

-- Risky: NULL if user doesn't exist
'SELECT active FROM users WHERE id = $user_id'
```

3. **Use EXISTS for existence checks**:

```sql
-- Good: EXISTS always returns true/false
'SELECT EXISTS(SELECT 1 FROM orders WHERE status = ''pending'')'

-- Works but returns count instead of boolean
'SELECT count(*) > 0 FROM orders WHERE status = ''pending'''
```

### Loop Condition Example

For `df.loop(body, condition)`, the condition is evaluated after each iteration:

```sql
-- Loop while there are pending items
SELECT df.start(
    df.loop(
        'SELECT process_next_item()',
        'SELECT count(*) > 0 FROM queue WHERE status = ''pending'''  -- condition
    )
);
```

The loop continues while the condition is truthy and exits when it becomes falsy.

---

## Function Examples

### 1. Simple Query

```sql
SELECT df.start(
    'SELECT COUNT(*) FROM playground.users WHERE active = true',
    'count-active-users'
);
```

### 2. Sequential Steps

```sql
SELECT df.start(
    'INSERT INTO playground.logs (msg) VALUES (''Step 1: Starting'')'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Step 2: Processing'')'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Step 3: Complete'')',
    'three-step-function'
);
```

### 3. Multi-Step ETL

```sql
SELECT df.start(
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
SELECT df.start(
    'SELECT id FROM playground.orders 
     WHERE status = ''pending'' LIMIT 1' |=> 'order_id'               -- get order
    ~> 'UPDATE playground.orders 
        SET status = ''processing'' WHERE id = $order_id'             -- mark processing
    ~> df.sleep(2)                                               -- simulate work
    ~> 'UPDATE playground.orders 
        SET status = ''completed'', processed_at = now() 
        WHERE id = $order_id',                                        -- complete
    'process-order'
);
```

### 5. Parallel Execution

```sql
-- Using & operator (preferred)
SELECT df.start(
    'SELECT COUNT(*) as user_count FROM playground.users'             -- branch 1
    & 'SELECT COUNT(*) as order_count FROM playground.orders'         -- branch 2
    ~> 'INSERT INTO playground.logs (msg) 
        VALUES (''Parallel counts complete'')',
    'parallel-counts'
);

-- Or using df.join() function
SELECT df.start(
    df.join(
        'SELECT COUNT(*) as user_count FROM playground.users',
        'SELECT COUNT(*) as order_count FROM playground.orders'
    )
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Done'')',
    'parallel-counts-func'
);
```

### 6. Conditional Logic

```sql
-- Using ?> !> operators (preferred)
SELECT df.start(
    'SELECT COUNT(*) > 3 FROM playground.task_queue WHERE status = ''pending'''
        ?> 'INSERT INTO playground.logs (msg, level) VALUES (''High load!'', ''warning'')'
        !> 'INSERT INTO playground.logs (msg) VALUES (''Queue normal'')',
    'check-task-load'
);

-- Or using df.if() function
SELECT df.start(
    df.if(
        'SELECT COUNT(*) > 3 FROM playground.task_queue WHERE status = ''pending''',
        'INSERT INTO playground.logs (msg, level) VALUES (''High load!'', ''warning'')',
        'INSERT INTO playground.logs (msg) VALUES (''Queue normal'')'
    ),
    'check-task-load-func'
);
```

### 7. Task Queue Processor

```sql
SELECT df.start(
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
    ~> df.sleep(1)                                               -- process
    ~> 'UPDATE playground.task_queue 
        SET status = ''completed'', completed_at = now()
        WHERE status = ''processing''',                               -- complete
    'process-next-task'
);
```

---

## HTTP Requests

Use `df.http()` to make HTTP requests to external APIs, webhooks, or services. HTTP requests are executed as durable activities - they survive crashes and can be retried.

### df.http() Function

```sql
df.http(
    url TEXT,                     -- Required: endpoint URL
    method TEXT DEFAULT 'POST',   -- GET, POST, PUT, DELETE, PATCH
    body TEXT DEFAULT NULL,       -- Request body (JSON)
    headers JSONB DEFAULT '{}',   -- Custom headers
    timeout_seconds INT DEFAULT 30
) RETURNS TEXT                    -- JSON response object
```

### Response Format

HTTP calls return a JSON object with full response details:

```json
{
  "status": 200,
  "body": "{\"result\": \"success\"}",
  "headers": {"content-type": "application/json"},
  "ok": true,
  "duration_ms": 245
}
```

| Field | Description |
|-------|-------------|
| `status` | HTTP status code (200, 404, 500, etc.) |
| `body` | Response body as string |
| `headers` | Response headers object |
| `ok` | `true` for 2xx status codes |
| `duration_ms` | Request duration in milliseconds |

### Error Handling

- **2xx responses**: Success - `ok` is `true`
- **4xx responses**: Returned to user (not a failure) - handle in workflow
- **5xx responses**: Activity fails and may be retried
- **Timeouts/Network errors**: Activity fails and may be retried

### HTTP Examples

#### 1. Simple GET Request

```sql
SELECT df.start(
    df.http('https://api.example.com/users/123', 'GET') |=> 'user'
    ~> 'INSERT INTO users_cache (data) VALUES (($user::jsonb->>''body'')::jsonb)',
    'fetch-user'
);
```

#### 2. POST with JSON Body

```sql
SELECT df.start(
    df.http(
        'https://api.example.com/orders',
        'POST',
        '{"product_id": 42, "quantity": 2}'
    ) |=> 'response'
    ~> df.if(
        'SELECT ($response::jsonb->>''ok'')::boolean',
        'INSERT INTO playground.logs (msg) VALUES (''Order created'')',
        'INSERT INTO playground.logs (msg, level) VALUES (''Order failed'', ''error'')'
    ),
    'create-order'
);
```

#### 3. HTTP with Custom Headers

```sql
SELECT df.start(
    df.http(
        'https://api.example.com/secure/data',
        'GET',
        NULL,
        '{"Authorization": "Bearer token123", "X-Custom-Header": "value"}'::jsonb
    ) |=> 'response'
    ~> 'SELECT ($response::jsonb->>''body'')::jsonb',
    'authenticated-request'
);
```

#### 4. Parallel API Calls

```sql
SELECT df.start(
    df.join(
        df.http('https://api.example.com/users', 'GET'),
        df.http('https://api.example.com/products', 'GET')
    ) |=> 'results'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Fetched users and products'')',
    'parallel-fetch'
);
```

#### 5. HTTP with Variable Substitution

```sql
SELECT df.start(
    'SELECT id, email FROM playground.users WHERE id = 1' |=> 'user'
    ~> df.http(
        'https://api.example.com/notifications',
        'POST',
        '{"user_id": "$user.id", "message": "Welcome!"}'
    ) |=> 'notification'
    ~> 'UPDATE playground.users SET notified = true WHERE id = ($user::jsonb->>''id'')::int',
    'send-notification'
);
```

#### 6. Handle 4xx Errors in Workflow

```sql
SELECT df.start(
    df.http('https://api.example.com/users/999', 'GET') |=> 'response'
    ~> df.if(
        'SELECT ($response::jsonb->>''status'')::int = 404',
        'INSERT INTO playground.logs (msg) VALUES (''User not found - creating new'')'
            ~> df.http('https://api.example.com/users', 'POST', '{"name": "New User"}'),
        'SELECT ($response::jsonb->>''body'')::jsonb'
    ),
    'fetch-or-create-user'
);
```

#### 7. Webhook Integration

```sql
SELECT df.start(
    'SELECT order_id, status, total FROM playground.orders WHERE id = 1' |=> 'order'
    ~> df.http(
        'https://partner.example.com/webhook/order-update',
        'POST',
        '{"order_id": "$order.order_id", "status": "$order.status", "total": "$order.total"}',
        '{"X-Webhook-Secret": "shared-secret-123"}'::jsonb
    ) |=> 'webhook_response'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Webhook sent: '' || ($webhook_response::jsonb->>''status''))',
    'send-order-webhook'
);
```

#### 8. Scheduled API Polling

```sql
SELECT df.start(
    @> (
        df.wait_for_schedule('*/5 * * * *')  -- Every 5 minutes
        ~> df.http('https://api.example.com/status', 'GET') |=> 'status'
        ~> df.if(
            'SELECT ($status::jsonb->''body''::jsonb->>''healthy'')::boolean = false',
            'INSERT INTO playground.logs (msg, level) VALUES (''Service unhealthy!'', ''error'')',
            'SELECT ''healthy'''
        )
    ),
    'api-health-monitor'
);
```

#### 9. Real-World Example: Scheduled GitHub Commit Sync

This example creates a scheduled durable function that fetches the last 5 commits from a GitHub repository every 30 minutes and stores them in a table. It demonstrates variables, HTTP requests, parsing complex JSON, and scheduled loops.

```sql
-- Create table to store commit data (sha, author, message, time)
CREATE TABLE IF NOT EXISTS github_commits (
    id SERIAL PRIMARY KEY,
    sha TEXT UNIQUE,
    author TEXT,
    message TEXT,
    committed_at TIMESTAMPTZ,
    fetched_at TIMESTAMPTZ DEFAULT now()
);

-- Configure the sync URL using durable function variable
SELECT df.setvar('github_url', 'https://api.github.com/repos/microsoft/duroxide/commits?per_page=5');

-- Start scheduled commit sync (runs every 30 minutes)
SELECT df.start(
    @> (
        (df.http(
            '{github_url}',
            'GET',
            NULL,
            '{"Accept": "application/vnd.github.v3+json", "User-Agent": "pg_durable"}'::jsonb
        ) |=> 'response')
        ~> 'INSERT INTO github_commits (sha, author, message, committed_at)
            SELECT 
                c->>''sha'',
                c->''commit''->''author''->>''name'',
                c->''commit''->>''message'',
                (c->''commit''->''author''->>''date'')::timestamptz
            FROM jsonb_array_elements(($response::jsonb->>''body'')::jsonb) AS c
            ON CONFLICT (sha) DO UPDATE SET
                fetched_at = now()
            RETURNING sha'
        ~> df.wait_for_schedule('*/30 * * * *')  -- Every 30 minutes
    ),
    'github-commit-sync'
);

-- Check the results
SELECT sha, author, committed_at, LEFT(message, 50) AS message FROM github_commits;

-- To stop the sync:
-- SELECT df.cancel('<instance_id>', 'Stopping commit sync');
```

This demonstrates:
- Configuring API endpoints with durable function variables
- Calling a real REST API (GitHub)
- Setting required headers (User-Agent, Accept)
- Parsing nested JSON (extracting `commit.author.name` and `commit.message`)
- Upserting with ON CONFLICT
- Creating a scheduled loop that runs every 30 minutes

---

## Durable Function Variables

Durable function variables allow you to configure durable functions with external values like API endpoints, credentials, or configuration settings. Variables are set **before** starting a durable function and remain **immutable** during execution.

### How Variables Work

1. **Set variables** using `df.setvar()` before calling `df.start()`
2. Variables are **captured** when `df.start()` is called
3. Variables are **immutable** during durable function execution
4. Use `{varname}` syntax in SQL to substitute variable values

### Variable Functions

| Function | Description |
|----------|-------------|
| `df.setvar(name, value)` | Set a variable (before durable function starts) |
| `df.getvar(name)` | Get a variable value |
| `df.unsetvar(name)` | Remove a variable |
| `df.clearvars()` | Clear all variables |

> **Important**: `df.setvar()`, `df.unsetvar()`, and `df.clearvars()` cannot be called from within a running durable function. They are for configuration only.

### System Variables

These read-only variables are automatically available during durable function execution:

| Variable | Description |
|----------|-------------|
| `{sys_instance_id}` | Current durable function instance ID |
| `{sys_label}` | Durable function label (if provided) |

### Variable Substitution

Use `{varname}` in SQL queries to substitute variable values:

```sql
-- Set up configuration
SELECT df.setvar('api_base', 'https://api.example.com');
SELECT df.setvar('api_key', 'secret123');

-- Start durable function using variables
SELECT df.start(
    df.http('{api_base}/users', 'GET', NULL, '{"Authorization": "Bearer {api_key}"}'::jsonb)
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Fetched users'')',
    'fetch-users'
);
```

### Example: Configurable ETL Pipeline

```sql
-- Configure the pipeline
SELECT df.setvar('source_table', 'raw_orders');
SELECT df.setvar('target_table', 'processed_orders');
SELECT df.setvar('batch_size', '100');

-- Start the pipeline
SELECT df.start(
    'SELECT * FROM {source_table} LIMIT {batch_size}::int' |=> 'batch'
    ~> 'INSERT INTO {target_table} SELECT * FROM ($batch) AS source',
    'etl-pipeline'
);
```

### Example: Using System Variables for Logging

```sql
SELECT df.start(
    'INSERT INTO audit_log (instance_id, label, action, ts) 
     VALUES (''{sys_instance_id}'', ''{sys_label}'', ''started'', now())'
    ~> 'SELECT process_data()'
    ~> 'INSERT INTO audit_log (instance_id, label, action, ts) 
        VALUES (''{sys_instance_id}'', ''{sys_label}'', ''completed'', now())',
    'audit-example'
);
```

### Example: HTTP with Variables

```sql
-- Configure API endpoint
SELECT df.setvar('webhook_url', 'https://hooks.example.com/notify');

-- Durable function that calls the configured webhook
SELECT df.start(
    'SELECT id, status FROM orders WHERE id = 1' |=> 'order'
    ~> df.http('{webhook_url}', 'POST', '{"order_id": "$order"}'),
    'order-webhook'
);
```

### Variable Lifecycle

```
┌─────────────────────────────────────────────────────────────┐
│  User Session                                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ df.setvar('key', 'value')  ← Configure variables    │    │
│  │ df.setvar('url', 'https://...')                     │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ df.start(workflow, 'label')                         │    │
│  │   → Variables CAPTURED (snapshot taken)             │    │
│  │   → Variables become IMMUTABLE for this execution   │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Background Worker (Durable Function Execution)             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ {key} → 'value'         ← Substitution works        │    │
│  │ {url} → 'https://...'                               │    │
│  │ {sys_instance_id} → 'a1b2c3d4'                      │    │
│  │                                                     │    │
│  │ df.setvar('x', 'y')     ← ERROR! Cannot modify      │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## Loops & Cron Jobs

### Eternal Loops

Use `@>` operator or `df.loop()` to create functions that run forever. Each iteration creates a new execution with fresh state (via continue-as-new).

```sql
-- Simple heartbeat every 30 seconds (using @> operator)
SELECT df.start(
    @> ('INSERT INTO playground.heartbeats (ts) VALUES (now())' ~> df.sleep(30)),
    'heartbeat-30s'
);

-- Same using df.loop() function
SELECT df.start(
    df.loop(
        'INSERT INTO playground.heartbeats (ts) VALUES (now())' ~> df.sleep(30)
    ),
    'heartbeat-30s-func'
);
```

### Cron-Style Scheduling

Use `df.wait_for_schedule()` with a cron expression:

```sql
-- Every minute: log a tick
SELECT df.start(
    @> (
        df.wait_for_schedule('* * * * *')
        ~> 'INSERT INTO playground.logs (msg) VALUES (''Minute tick: '' || now()::text)'
    ),
    'every-minute-tick'
);

-- Every 5 minutes: check for pending tasks
SELECT df.start(
    @> (
        df.wait_for_schedule('*/5 * * * *')
        ~> 'SELECT COUNT(*) as pending FROM playground.task_queue 
            WHERE status = ''pending''' |=> 'count'
        ~> 'INSERT INTO playground.logs (msg) VALUES (''Pending tasks: '' || $count)'
    ),
    'task-monitor-5min'
);

-- Hourly: clean up old logs
SELECT df.start(
    @> (
        df.wait_for_schedule('0 * * * *')
        ~> 'DELETE FROM playground.logs 
            WHERE created_at < now() - interval ''24 hours'''
    ),
    'hourly-log-cleanup'
);

-- Daily at midnight: archive completed orders
SELECT df.start(
    @> (
        df.wait_for_schedule('0 0 * * *')
        ~> 'UPDATE playground.orders SET status = ''archived'' 
            WHERE status = ''completed'' 
            AND processed_at < now() - interval ''7 days'''
    ),
    'daily-order-archive'
);

-- Weekdays at 9am: generate report
SELECT df.start(
    @> (
        df.wait_for_schedule('0 9 * * 1-5')
        ~> 'SELECT playground.generate_report(''daily_summary'')'
    ),
    'weekday-morning-report'
);
```

### While Loops

Use `df.loop(body, condition)` to repeat while a condition is true:

```sql
-- Process items while queue has entries
SELECT df.start(
    df.loop(
        'SELECT process_next_item()' ~> df.sleep(1),
        'SELECT count(*) > 0 FROM task_queue WHERE status = ''pending'''
    ),
    'queue-processor'
);
```

### Breaking Out of Loops

Use `df.break()` to exit a loop from inside its body:

```sql
-- Process batches until done flag is set
SELECT df.start(
    df.loop(
        'SELECT process_batch()' |=> 'batch'
        ~> (
            '$batch.done'
                ?> df.break('{"status": "complete", "total": $batch.count}')
                !> df.sleep(5)
        )
    ),
    'batch-processor'
);
```

`df.break(value)` exits the loop and returns the value as the loop's final result.

### Stopping a Loop Externally

```sql
-- Cancel by instance ID
SELECT df.cancel('a1b2c3d4', 'Manual stop');

-- Find by label first, then cancel
SELECT instance_id FROM df.list_instances() WHERE label = 'every-minute-tick';
-- Then cancel with the found ID
SELECT df.cancel('found_id', 'Stopping cron job');
```

---

## Signals

Signals allow external code to send events to running durable functions. This enables:
- **Human-in-the-loop workflows** - Wait for approval before proceeding
- **Webhook callbacks** - Receive notifications from external systems
- **Event-driven coordination** - Synchronize between processes

### Waiting for a Signal

Use `df.wait_for_signal()` to pause execution until a signal arrives:

```sql
-- Wait forever for a signal
df.wait_for_signal('signal_name')

-- Wait with timeout (seconds) - returns after timeout if no signal
df.wait_for_signal('signal_name', 3600)  -- 1 hour timeout
```

### Sending a Signal

Use `df.signal()` to send a signal to a running instance:

```sql
SELECT df.signal('instance_id', 'signal_name', '{"data": "value"}');
```

**Parameters:**
- `instance_id` - The durable function instance ID (required)
- `signal_name` - Name of the signal (must match what the instance is waiting for)
- `signal_data` - JSON payload (optional, defaults to `'{}'`)

### Signal Result Format

When a signal is received (or times out), the result is a JSON object:

```json
{
  "signal_name": "approval",
  "timed_out": false,
  "data": {"approved": true, "approver": "jane@acme.com"}
}
```

If the signal times out:
```json
{
  "signal_name": "approval",
  "timed_out": true,
  "data": null
}
```

### Example: Order Approval Workflow

```sql
SELECT df.start(
    'SELECT order_id, total FROM orders WHERE id = 1' |=> 'order'
    ~> df.wait_for_signal('approval', 86400) |=> 'sig'  -- 24h timeout
    ~> df.if(
        'SELECT NOT ($sig::jsonb->>''timed_out'')::boolean 
            AND ($sig::jsonb->''data''->>''approved'')::boolean',
        'UPDATE orders SET status = ''approved'' WHERE id = $order_id',
        'UPDATE orders SET status = ''rejected'' WHERE id = $order_id'
    ),
    'order-approval'
);

-- Later, approve the order (using the instance ID returned by df.start)
SELECT df.signal('a1b2c3d4', 'approval', '{"approved": true, "approver": "jane@acme.com"}');
```

### Example: Multi-Party Approval

Wait for multiple approvals using `df.join()`:

```sql
SELECT df.start(
    'SELECT doc_id FROM documents WHERE id = 1' |=> 'doc'
    ~> df.join(
        df.wait_for_signal('legal_approval'),
        df.wait_for_signal('tech_approval'),
        df.wait_for_signal('mgmt_approval')
    ) |=> 'approvals'
    ~> 'UPDATE documents SET status = ''approved'' WHERE id = $doc_id',
    'multi-approval'
);

-- Each approver sends their signal independently
SELECT df.signal('abc123', 'legal_approval', '{"approved": true}');
SELECT df.signal('abc123', 'tech_approval', '{"approved": true}');
SELECT df.signal('abc123', 'mgmt_approval', '{"approved": true}');
```

### Example: Webhook Callback Pattern

Start a job and wait for external callback:

```sql
SELECT df.start(
    df.http('{job_api}/start', 'POST', '{"type": "render"}') |=> 'job'
    ~> df.wait_for_signal('job_complete', 3600) |=> 'result'
    ~> df.if(
        'SELECT NOT ($result::jsonb->>''timed_out'')::boolean',
        'INSERT INTO completed_jobs VALUES ($job, $result)',
        'INSERT INTO failed_jobs VALUES ($job, ''timeout'')'
    ),
    'webhook-job'
);

-- External system calls back via df.signal when job completes
-- (e.g., via a webhook endpoint that calls df.signal)
```

---

## Visualizing Functions

### df.explain()

Use `df.explain()` to visualize function structure. It works in two modes:

**1. Live Instance** - Pass an instance ID to see execution status:

```sql
SELECT df.explain('a1b2c3d4');
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
SELECT df.explain(
    'SELECT 1' |=> 'a'
    ~> 'SELECT 2' |=> 'b'
    ~> df.if(
        'SELECT $a > 0',
        'SELECT ''yes''',
        'SELECT ''no'''
    )
);
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

**ETL Pipeline with Parallel Validation:**

```sql
SELECT df.explain(
    'SELECT * FROM staging WHERE status = ''pending'' LIMIT 1' |=> 'record'
    ~> df.if(
        'SELECT $record IS NOT NULL',
        'UPDATE staging SET status = ''validating'' WHERE id = $record.id'
            ~> df.join(
                'SELECT validate_schema($record.data)' |=> 'schema_ok',
                'SELECT validate_rules($record.data)' |=> 'rules_ok'
            )
            ~> df.if(
                'SELECT $schema_ok AND $rules_ok',
                'INSERT INTO target SELECT * FROM staging WHERE id = $record.id'
                    ~> 'UPDATE staging SET status = ''loaded'' WHERE id = $record.id',
                'UPDATE staging SET status = ''failed'' WHERE id = $record.id'
            ),
        'SELECT ''no pending records'''
    )
);
```

Output:
```
SQL |=> 'record': SELECT * FROM staging WHERE status = 'pending' LIMIT 1
→ IF
    ✓ then:
      SQL: UPDATE staging SET status = 'validating' WHERE id = $record.id
      → JOIN (2)
          ║ branch 1:
            SQL |=> 'schema_ok': SELECT validate_schema($record.data)
          ║ branch 2:
            SQL |=> 'rules_ok': SELECT validate_rules($record.data)
      → IF
          ✓ then:
            SQL: INSERT INTO target SELECT * FROM staging WHERE id = $record.id
            → SQL: UPDATE staging SET status = 'loaded' WHERE id = $record.id
          ✗ else:
            SQL: UPDATE staging SET status = 'failed' WHERE id = $record.id
    ✗ else:
      SQL: SELECT 'no pending records'
```

**Cron Job with Cleanup Loop:**

```sql
SELECT df.explain(
    df.loop(
        df.wait_for_schedule('0 * * * *')
        ~> 'DELETE FROM logs WHERE created_at < now() - interval ''7 days''' |=> 'deleted'
        ~> df.if(
            'SELECT $deleted > 0',
            'INSERT INTO audit (action, count) VALUES (''cleanup'', $deleted)',
            'SELECT ''nothing to clean'''
        )
    )
);
```

Output:
```
LOOP
    ↻ body:
      WAIT_SCHEDULE '0 * * * *'
      → SQL |=> 'deleted': DELETE FROM logs WHERE created_at < now() - interval '7 days'
      → IF
          ✓ then:
            SQL: INSERT INTO audit (action, count) VALUES ('cleanup', $deleted)
          ✗ else:
            SQL: SELECT 'nothing to clean'
```

**Daily Midnight Order Archive (from Examples section):**

```sql
-- Visualize the daily-order-archive function before starting it
SELECT df.explain(
    df.loop(
        df.wait_for_schedule('0 0 * * *')
        ~> 'SELECT COUNT(*) as cnt FROM playground.orders 
            WHERE status = ''completed'' 
            AND processed_at < now() - interval ''7 days''' |=> 'to_archive'
        ~> df.if(
            'SELECT $to_archive > 0',
            'UPDATE playground.orders SET status = ''archived'' 
             WHERE status = ''completed'' 
             AND processed_at < now() - interval ''7 days''' |=> 'archived'
                ~> 'INSERT INTO playground.logs (msg, level) 
                    VALUES (''Archived '' || $archived || '' orders'', ''info'')',
            'INSERT INTO playground.logs (msg) 
             VALUES (''No orders to archive'')'
        )
    )
);
```

Output:
```
LOOP
    ↻ body:
      WAIT_SCHEDULE '0 0 * * *'
      → SQL |=> 'to_archive': SELECT COUNT(*) as cnt FROM playground.orders WHERE status = 'completed' AND processed_at < now() - interval '7 days'
      → IF
          ✓ then:
            SQL |=> 'archived': UPDATE playground.orders SET status = 'archived' WHERE status = 'completed' AND processed_at < now() - interval '7 days'
            → SQL: INSERT INTO playground.logs (msg, level) VALUES ('Archived ' || $archived || ' orders', 'info')
          ✗ else:
            SQL: INSERT INTO playground.logs (msg) VALUES ('No orders to archive')
```

---

## Monitoring

### List All Instances

```sql
-- All instances
SELECT * FROM df.list_instances();

-- Filter by status
SELECT * FROM df.list_instances('Running');
SELECT * FROM df.list_instances('Completed');
SELECT * FROM df.list_instances('Failed');

-- With limit
SELECT * FROM df.list_instances(NULL, 10);
```

**Columns:** `instance_id`, `label`, `function_name`, `status`, `execution_count`, `output`

### Instance Details

```sql
SELECT * FROM df.instance_info('a1b2c3d4');
```

**Columns:** `instance_id`, `label`, `function_name`, `function_version`, `current_execution_id`, `status`, `output`

### Execution History

For loops and retried functions, see the execution history:

```sql
-- Last 5 executions (default)
SELECT * FROM df.instance_executions('a1b2c3d4');

-- Last 20 executions
SELECT * FROM df.instance_executions('a1b2c3d4', 20);
```

**Columns:** `execution_id`, `status`, `event_count`, `duration_ms`, `output`

### Function Nodes

See the function graph structure:

```sql
-- Last 5 executions (default)
SELECT * FROM df.instance_nodes('a1b2c3d4');

-- Last 10 executions
SELECT * FROM df.instance_nodes('a1b2c3d4', 10);
```

**Columns:** `execution_id`, `node_id`, `node_type`, `query`, `result_name`, `left_node`, `right_node`, `status`, `result`

### System Metrics

```sql
SELECT * FROM df.metrics();
```

**Columns:** `total_instances`, `running_instances`, `completed_instances`, `failed_instances`, `total_executions`, `total_events`

### Quick Status Check

```sql
-- Status only
SELECT df.status('a1b2c3d4');

-- Result only
SELECT df.result('a1b2c3d4');
```

---

## User Isolation & Privileges

### How Privilege Isolation Works

Durable functions **execute with the privileges of the user who submitted them**, not the background worker's privileges. This means:

- ✅ Your SQL runs as **you**, with your permissions
- ✅ You can only access tables and data **you** have access to
- ✅ Non-superusers cannot escalate privileges through durable functions
- ✅ Superusers' functions run with superuser privileges (expected behavior)

**Example:**

```sql
-- Alice creates a table she owns
CREATE USER alice;
CREATE TABLE alice_data (secret TEXT);
ALTER TABLE alice_data OWNER TO alice;

-- Alice submits a durable function
SET SESSION AUTHORIZATION alice;
SELECT df.start('SELECT * FROM alice_data');
-- ✅ This works - alice can access her own table

SELECT df.start('SELECT * FROM bob_data');
-- ❌ This fails - alice doesn't have permission
```

### How Identity Is Captured

When you call `df.start()`, pg_durable captures two pieces of identity:

1. **Login role** (`session_user`) - The user you authenticated as
2. **Effective role** (`current_user`) - Your current effective privileges (after `SET ROLE`, if used)

The background worker then:
1. Connects to PostgreSQL as your **login role**
2. Executes `SET ROLE` to your **effective role** 
3. Runs your SQL with the correct privileges

### Working with Group Roles

You can use `SET ROLE` to switch to a group role before submitting a durable function:

```sql
-- Create a group role (no LOGIN)
CREATE ROLE analysts NOLOGIN;
GRANT analysts TO alice;

CREATE TABLE analyst_reports (id INT, report TEXT);
ALTER TABLE analyst_reports OWNER TO analysts;

-- Alice switches to the analysts role
SET SESSION AUTHORIZATION alice;
SET ROLE analysts;

-- Submit as the group role
SELECT df.start('SELECT * FROM analyst_reports');
-- ✅ Runs as 'analysts', alice's session user is used for authentication
```

### What Happens If a Role Is Dropped?

If the user who submitted a function is dropped **before execution**:

- The background worker will fail to connect
- The instance transitions to `failed` status
- You'll see a clear error message: `"Failed to connect as 'username'..."`

**Important:** Don't drop roles that have running or pending durable functions.

### Current Limitations

#### Shared Variables

The `df.vars` table is currently **shared across all users**:

```sql
-- User alice sets a variable
SET SESSION AUTHORIZATION alice;
SELECT df.setvar('api_key', 'alice-secret');

-- User bob can read it! ⚠️
SET SESSION AUTHORIZATION bob;
SELECT df.getvar('api_key');  -- Returns 'alice-secret'
```

**Workaround:** Use namespaced variable names: `df.setvar('alice.api_key', ...)`

**Future:** User-scoped variables with row-level security (RLS) are planned.

#### HTTP Requests

HTTP requests (`df.http()`) currently execute with the **background worker's privileges**, not the submitting user's privileges:

- All users can make HTTP requests to the same endpoints
- No user-specific URL allowlists or SSRF protection

**Future:** Per-user HTTP isolation and URL allowlists are planned.

#### Cross-Instance Visibility

Any user with `SELECT` access to `df.instances` can see **all instances**, including:
- Who submitted them (`submitted_by` column)
- Their labels and status
- When they were created

**Future:** Row-level security (RLS) to restrict visibility to own instances is planned.

### Security Best Practices

1. **Grant minimal permissions** - Only grant `df` schema access to users who need it
2. **Review df.vars usage** - Avoid storing secrets in shared variables
3. **Use labels carefully** - Labels are visible to all users; avoid including sensitive info
4. **Monitor instances** - Use `df.list_instances()` to see who's running what
5. **Clean up** - Cancel or delete old instances to reduce cross-user visibility

### Privilege Grants

To allow a user to use pg_durable:

```sql
-- Minimum grants for basic usage
GRANT USAGE ON SCHEMA df TO username;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO username;

-- Current implementation requires table access
-- (This will be tightened in future releases)
GRANT SELECT, INSERT, UPDATE ON df.instances TO username;
GRANT SELECT, INSERT, UPDATE ON df.nodes TO username;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO username;
```

**Note:** These grants will become more restrictive as the security model evolves.
## Troubleshooting

### Extension Exists But Workflows Don't Start

**Symptom**: You've run `CREATE EXTENSION pg_durable` but `df.start()` returns an instance ID that never completes.

**Cause**: The background worker is not running, usually because `pg_durable` is not in `shared_preload_libraries`.

**Solution**:
1. Check if `pg_durable` is in `shared_preload_libraries`:
   ```sql
   SHOW shared_preload_libraries;
   ```
2. If missing, add to `postgresql.conf`:
   ```ini
   shared_preload_libraries = 'pg_durable'  # or 'pg_durable,other_ext'
   ```
3. Restart PostgreSQL (required for `shared_preload_libraries` changes)
4. Verify the background worker started by checking PostgreSQL logs for:
   ```
   pg_durable: duroxide background worker starting...
   pg_durable: extension detected, proceeding with initialization
   pg_durable: duroxide runtime started
   ```

### "Failed to connect to duroxide store" Error

**Symptom**: Calling `df.start()`, `df.status()`, or monitoring functions returns an error:
```
Failed to connect to duroxide store: ...
```

**Possible Causes**:

1. **Extension not created**: Run `CREATE EXTENSION pg_durable`

2. **Schema migration mismatch**: The `duroxide` schema exists but is at an incompatible version
   - **Solution**: Drop and recreate the extension:
     ```sql
     DROP EXTENSION pg_durable CASCADE;
     CREATE EXTENSION pg_durable;
     ```
   
3. **Database connection issues**: PostgreSQL is not accepting connections
   - Check PostgreSQL is running
   - Verify connection string environment variables if customized

### Background Worker Not Initializing

**Symptom**: After `CREATE EXTENSION`, functions still don't execute, and logs show:
```
pg_durable: waiting for CREATE EXTENSION pg_durable...
```

**Cause**: The background worker is waiting for the extension to be created in the database it's connected to.

**Solution**:
1. Verify you're creating the extension in the correct database
2. Check which database the background worker connects to:
   - Defaults to the database specified by `PGDATABASE` environment variable or `postgres`
   - The background worker only processes functions in **one** database
3. If you need pg_durable in a different database:
   - Create the extension in the database the background worker uses, OR
   - Update environment variables and restart PostgreSQL

### Extension Drop/Recreate Issues

**Symptom**: After `DROP EXTENSION pg_durable CASCADE`, workflows still appear to be running or you see errors.

**Explanation**: The background worker polls for extension existence every 5 seconds. After detecting a drop:
- It shuts down the duroxide runtime (takes ~10 seconds)
- Returns to waiting for extension creation
- Any in-flight workflows are terminated

**Solution**: Wait 15-20 seconds after `DROP EXTENSION` before recreating:
```sql
DROP EXTENSION pg_durable CASCADE;
-- Wait ~20 seconds for background worker to fully shut down
CREATE EXTENSION pg_durable;
```

### Functions Complete But Results Are Empty

**Symptom**: `df.status()` shows `Completed` but `df.result()` returns empty or null.

**Possible Causes**:

1. **Query returns no rows**: The SQL query executed successfully but returned no data
   ```sql
   SELECT * FROM users WHERE id = 999999;  -- no such user
   ```
   
2. **Variable not named**: Use `|=>` to capture results in named variables
   ```sql
   -- Bad: result not captured
   SELECT df.start('SELECT id FROM users LIMIT 1');
   
   -- Good: result captured
   SELECT df.start('SELECT id FROM users LIMIT 1' |=> 'user_id');
   ```

3. **ETL workflow that doesn't return data**: If the function performs INSERTs/UPDATEs, those succeed without returning data. Add a final query to return status:
   ```sql
   SELECT df.start(
     'INSERT INTO logs (msg) VALUES (''done'')' ~>
     'SELECT ''success'' as status'
   );
   ```

### Slow Function Startup

**Symptom**: There's a delay between `df.start()` returning and the function actually executing.

**Explanation**: This is normal during:
- **Initial extension creation**: Background worker needs 1-5 seconds to initialize
- **After DROP/CREATE**: Background worker needs to reinitialize

**Solution**: If delays persist beyond startup:
1. Check PostgreSQL logs for errors
2. Verify the background worker is running (see "Extension Exists But Workflows Don't Start")
3. Check for resource contention (CPU, disk I/O, connection limits)

### Check Background Worker Logs

To debug background worker issues, check PostgreSQL logs:

```bash
# Find PostgreSQL log location
psql -c "SHOW log_directory;"
psql -c "SHOW log_filename;"

# Example (adjust path for your installation)
tail -f /var/log/postgresql/postgresql-17-main.log

# Or for pgrx development:
tail -f ~/.pgrx/17.log
```

Look for lines starting with `pg_durable:` for background worker activity.

---

## Quick Reference Card

```sql
-- Start a durable function (plain SQL auto-wrapped)
SELECT df.start('SELECT 1', 'optional-label');

-- Chain steps with ~>
SELECT df.start('SELECT 1' ~> 'SELECT 2' ~> 'SELECT 3');

-- Name a result with |=>
SELECT df.start('SELECT 1' |=> 'myvar' ~> 'SELECT $myvar * 2');

-- Parallel join (& operator or df.join)
SELECT df.start('SELECT 1' & 'SELECT 2');         -- operator
SELECT df.start(df.join('SELECT 1', 'SELECT 2')); -- function

-- Race (| operator or df.race) - first wins
SELECT df.start('fast_query' | df.sleep(30));     -- operator
SELECT df.start(df.race(fast, slow));             -- function

-- Conditional (?> !> operators or df.if)
SELECT df.start('SELECT true' ?> 'yes' !> 'no');  -- operator
SELECT df.start(df.if('SELECT true', 'yes', 'no')); -- function

-- Loop forever (@> operator or df.loop)
SELECT df.start(@> (body ~> df.sleep(60)));       -- operator
SELECT df.start(df.loop(body ~> df.sleep(60)));   -- function

-- While loop (continues while condition is true)
SELECT df.start(df.loop(body, 'SELECT count(*) > 0 FROM queue'));

-- Break out of loop
df.break()                               -- exit loop
df.break('{"done": true}')               -- exit with return value

-- Timers
df.sleep(60)                             -- 60 seconds
df.wait_for_schedule('*/5 * * * *')      -- every 5 min

-- HTTP requests
df.http('https://api.example.com', 'GET')                    -- simple GET
df.http('https://api.example.com', 'POST', '{"key": "val"}') -- POST with body
df.http(url, 'GET', NULL, '{"Auth": "Bearer x"}'::jsonb)     -- with headers

-- Durable function variables (set BEFORE df.start)
SELECT df.setvar('api_url', 'https://api.example.com');      -- set variable
SELECT df.getvar('api_url');                                  -- get variable
SELECT df.unsetvar('api_url');                                -- remove variable
SELECT df.clearvars();                                        -- clear all

-- Use variables in workflows: {varname}
SELECT df.start(df.http('{api_url}/data', 'GET'));           -- variable substitution
-- System vars: {sys_instance_id}, {sys_label}

-- Signals (wait for external events)
df.wait_for_signal('approval')                    -- wait forever
df.wait_for_signal('approval', 3600)              -- wait with 1h timeout
SELECT df.signal('inst_id', 'approval', '{}');    -- send signal

-- Visualize
SELECT df.explain('instance_id');        -- live instance
SELECT df.explain('a' ~> 'b');           -- dry-run preview

-- Monitor
SELECT * FROM df.list_instances();
SELECT * FROM df.instance_info('id');
SELECT df.status('id');
SELECT df.result('id');

-- Cancel
SELECT df.cancel('id', 'reason');
```

---

## Appendix: Test Data Setup

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
