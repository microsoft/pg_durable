# pg_durable User Guide

**Durable SQL Workflows for PostgreSQL**

pg_durable is a PostgreSQL extension that brings durable, fault-tolerant workflow execution directly into your database. Define durable workflows using a declarative SQL API, and let the extension handle persistence, retries, and scheduling.

---

## Table of Contents

1. [Overview](#overview)
2. [Getting Started](#getting-started)
3. [Core Concepts](#core-concepts)
4. [API Reference](#api-reference)
5. [Condition Evaluation](#condition-evaluation)
6. [Workflow Examples](#workflow-examples)
7. [HTTP Requests](#http-requests)
8. [Durable Workflow Variables](#durable-workflow-variables)
9. [Loops & Cron Jobs](#loops--cron-jobs)
10. [Signals](#signals)
11. [Multi-Database Support](#multi-database-support)
12. [Visualizing Workflows](#visualizing-workflows)
13. [Monitoring](#monitoring)
14. [User Isolation & Privileges](#user-isolation--privileges)
15. [Connection Limits](#connection-limits)
16. [Troubleshooting](#troubleshooting)
17. [Quick Reference Card](#quick-reference-card)
18. [Appendix: Test Data Setup](#appendix-test-data-setup)

---

## Overview

### What is pg_durable?

pg_durable enables you to define and execute **durable SQL workflows** entirely within PostgreSQL. Unlike traditional job queues or external workflow engines, pg_durable:

- **Lives in your database** - No external services to manage
- **Uses declarative SQL** - Define workflows with composable step functions
- **Is fault-tolerant** - Workflows survive crashes and restarts
- **Supports scheduling** - Built-in cron-style scheduling for recurring jobs
- **Provides visibility** - Monitor workflow status directly via SQL queries

### Key Features

| Feature | Description |
|---------|-------------|
| **Declarative API** | Define workflows using `df.create_workflow()` with composable step functions |
| **Sequential Execution** | Steps in an array execute in order |
| **Parallel Execution** | Run steps concurrently with `df.join()` |
| **Race Execution** | First to complete wins with `df.race()` |
| **Conditional Logic** | Branch with `df.if()` and `df.if_rows()` |
| **Timers & Delays** | Sleep with `df.sleep()` |
| **Cron Scheduling** | Schedule with `df.wait_for_schedule()` |
| **Loops** | Create forever-running or conditional loops with `df.loop()` |
| **Signals** | Wait for external events with `df.wait_for_signal()` |
| **Variable Substitution** | Pass results between steps using `$name` |
| **Labels** | Tag workflows with friendly names |
| **Visualization** | Preview workflow structure with `df.explain()` |
| **Monitoring** | Query workflow status, history, and metrics |

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

-- Grant usage to application roles
SELECT df.grant_usage('app_role');
```

After `CREATE EXTENSION`, the background worker initializes the engine schema asynchronously (normally within a few seconds). Until initialization completes, `df.*` functions will return: `"pg_durable background worker not yet initialized — try again in a moment"`. Simply retry after a short delay.

> ⚠️ **Important**: If you include `pg_durable` in `shared_preload_libraries` but don't create the extension, the worker will remain idle and durable workflows cannot execute.

### Your First Durable Workflow

```sql
-- Execute a simple SQL query as a durable workflow
SELECT df.create_workflow(
    name => 'hello-world',
    steps => ARRAY[
        df.sql('SELECT ''Hello, durable world!''')
    ]
);
-- Returns: a1b2c3d4 (8-character instance ID)
```

### Check the Result

```sql
-- List all workflows
SELECT * FROM df.list_instances();

-- Get result of a specific instance
SELECT df.result('a1b2c3d4');
```

---

> 💡 **Want to run the examples?** The examples in this guide use a `playground` schema with sample data. See the [Appendix: Test Data Setup](#appendix-test-data-setup) to install it.

---

## Core Concepts

### Workflow Lifecycle

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Define    │ ──► │   Start     │ ──► │  Running    │
│  (Steps)    │     │  (returns   │     │  (bg work)  │
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

Every durable workflow gets a unique 8-character hex ID (e.g., `a1b2c3d4`). Use this ID to:
- Check status: `SELECT df.status('a1b2c3d4')`
- Get result: `SELECT df.result('a1b2c3d4')`
- Cancel: `SELECT df.cancel('a1b2c3d4')`

### Durability

Workflows are persisted to disk. If PostgreSQL crashes:
- Completed steps are not re-executed
- In-progress steps resume from the last checkpoint
- Pending steps execute when the server restarts

### Workflow Construction

Step functions build graph structures **in memory** without touching the database. Only when you call `df.create_workflow()` are the nodes written to the database and execution begins:

```sql
-- Step functions compose into a JSON graph representation
SELECT df.sql('SELECT 1');
-- Returns a step descriptor (JSON)

-- Only df.create_workflow() writes to the database and starts execution
SELECT df.create_workflow(
    name => 'example',
    steps => ARRAY[
        df.sql('SELECT 1'),
        df.sql('SELECT 2')
    ]
);
```

---

## API Reference

### df.create_workflow()

The primary entry point for defining and starting durable workflows:

```sql
SELECT df.create_workflow(
    name     => TEXT,                    -- Required: workflow name/label
    steps    => df.step[],              -- Required: array of steps (executed sequentially)
    database => TEXT DEFAULT NULL,       -- Optional: target database (default: current)
    options  => JSONB DEFAULT '{}'       -- Optional: configuration
) RETURNS TEXT;                          -- Returns: 8-character instance ID
```

### Step Functions

| Function | Description | Example |
|----------|-------------|---------|
| `df.sql(query, result_name)` | Execute a SQL query | `df.sql('SELECT 1', result_name => 'x')` |
| `df.sleep(seconds)` | Pause for N seconds | `df.sleep(60)` |
| `df.wait_for_schedule(cron)` | Wait until cron matches | `df.wait_for_schedule('0 * * * *')` |
| `df.http(url, method, body, headers, timeout, result_name)` | Make HTTP request | `df.http('https://api.example.com', 'POST')` |
| `df.join(steps)` | Execute in parallel, wait for all | `df.join(ARRAY[step1, step2])` |
| `df.join(steps, result_name)` | Parallel join with named result | `df.join(ARRAY[s1, s2], result_name => 'r')` |
| `df.race(steps)` | Execute in parallel, first wins | `df.race(ARRAY[fast, slow])` |
| `df.if(condition, then_steps, else_steps)` | Conditional branch | `df.if('SELECT true', ARRAY[a], ARRAY[b])` |
| `df.if_rows(name, then_steps, else_steps)` | Branch on row existence | `df.if_rows('result', ARRAY[a], ARRAY[b])` |
| `df.loop(steps...)` | Repeat forever (variadic) | `df.loop(body1, body2)` |
| `df.loop(steps..., condition)` | Repeat while condition is true | `df.loop(body, condition => 'SELECT ...')` |
| `df.break()` | Exit enclosing loop | `df.break()` |
| `df.break(value)` | Exit loop with return value | `df.break('{"done": true}')` |
| `df.wait_for_signal(name)` | Wait for external signal | `df.wait_for_signal('approval')` |
| `df.wait_for_signal(name, timeout)` | Wait with timeout (seconds) | `df.wait_for_signal('approval', 3600)` |

### Management Functions

| Function | Description | Example |
|----------|-------------|---------|
| `df.create_workflow(name, steps, ...)` | Create and start workflow | See above |
| `df.cancel(id, reason)` | Cancel workflow | `df.cancel('a1b2c3d4', 'Done')` |
| `df.status(id)` | Get status | `df.status('a1b2c3d4')` |
| `df.result(id)` | Get result | `df.result('a1b2c3d4')` |
| `df.explain(input)` | Visualize graph | `df.explain('a1b2c3d4')` |
| `df.setvar(name, value)` | Set durable workflow variable | `df.setvar('api_url', 'https://...')` |
| `df.getvar(name)` | Get durable workflow variable | `df.getvar('api_url')` |
| `df.unsetvar(name)` | Remove durable workflow variable | `df.unsetvar('api_url')` |
| `df.clearvars()` | Clear all durable workflow variables | `df.clearvars()` |
| `df.signal(id, name, data)` | Send signal to instance | `df.signal('a1b2', 'go', '{}')` |

### Result Naming

Use `result_name` to capture a step's output for use in subsequent steps via `$name`:

```sql
SELECT df.create_workflow(
    name => 'naming-example',
    steps => ARRAY[
        df.sql('SELECT 100 as amount', result_name => 'total'),
        df.sql('SELECT $total * 2 as doubled')
    ]
);
```

#### Dot-Notation (`$name.column`)

Access specific columns by name instead of just the first column:

```sql
SELECT df.create_workflow(
    name => 'dot-notation',
    steps => ARRAY[
        df.sql($$SELECT 42 AS id, 'Alice' AS name$$, result_name => 'user'),
        df.sql($$SELECT $user.id, $user.name$$)
    ]
);
```

#### Null-Safe Accessor (`$name?`, `$name.column?`)

By default, referencing a result with no rows or a NULL value **fails** the instance with a clear error. Use the `?` suffix to substitute `NULL` instead:

```sql
SELECT df.create_workflow(
    name => 'null-safe',
    steps => ARRAY[
        df.sql($$SELECT NULL::text AS val$$, result_name => 'x'),
        df.sql($$SELECT COALESCE($x.val?, 'fallback')$$)
    ]
);
```

| Pattern | No rows | NULL value |
|---------|---------|------------|
| `$name` | **Fails** | **Fails** |
| `$name.col` | **Fails** | **Fails** |
| `$name?` | → `NULL` | → `NULL` |
| `$name.col?` | → `NULL` | → `NULL` |

#### Row-Set Expansion (`$name.*`)

Expand a multi-row result into an inline `VALUES` subquery:

```sql
SELECT df.create_workflow(
    name => 'row-expansion',
    steps => ARRAY[
        df.sql($$SELECT id, name FROM users WHERE active$$, result_name => 'batch'),
        df.sql($$SELECT count(*) FROM $batch.*$$)
    ]
);
```

This is useful for passing row sets between steps. The expansion generates SQL like `(VALUES (1,'Alice'), (2,'Bob')) AS batch(id, name)`.


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

When using `df.if()` or loop conditions (`df.loop(steps..., condition)`), pg_durable needs to interpret SQL results as boolean values. This section explains how arbitrary data types are evaluated for truthiness.

### How SQL Results Are Evaluated

When a condition SQL query executes, pg_durable:

1. **Extracts the first column of the first row** from the result
2. **Evaluates that value for truthiness** using the rules below

```sql
-- Example: condition evaluates the first column of first row
SELECT df.create_workflow(
    name => 'condition-demo',
    steps => ARRAY[
        df.if(
            condition => 'SELECT count(*) > 10 FROM orders',
            then_steps => ARRAY[df.sql('SELECT ''high volume''')],
            else_steps => ARRAY[df.sql('SELECT ''low volume''')]
        )
    ]
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

For `df.loop(steps..., condition)`, the condition is evaluated after each iteration:

```sql
-- Loop while there are pending items
SELECT df.create_workflow(
    name => 'loop-until-empty',
    steps => ARRAY[
        df.loop(
            df.sql('SELECT process_next_item()'),
            condition => 'SELECT count(*) > 0 FROM queue WHERE status = ''pending'''
        )
    ]
);
```

The loop continues while the condition is truthy and exits when it becomes falsy.

---

## Workflow Examples

### 1. Simple Query

```sql
SELECT df.create_workflow(
    name => 'count-active-users',
    steps => ARRAY[
        df.sql('SELECT COUNT(*) FROM playground.users WHERE active = true')
    ]
);
```

### 2. Sequential Steps

```sql
SELECT df.create_workflow(
    name => 'three-step-workflow',
    steps => ARRAY[
        df.sql('INSERT INTO playground.logs (msg) VALUES (''Step 1: Starting'')'),
        df.sql('INSERT INTO playground.logs (msg) VALUES (''Step 2: Processing'')'),
        df.sql('INSERT INTO playground.logs (msg) VALUES (''Step 3: Complete'')')
    ]
);
```

### 3. Multi-Step ETL

```sql
SELECT df.create_workflow(
    name => 'daily-etl',
    steps => ARRAY[
        df.sql('DELETE FROM playground.target
                WHERE loaded_at < now() - interval ''1 day'''),
        df.sql('UPDATE playground.staging
                SET processed_at = now() WHERE processed_at IS NULL'),
        df.sql('INSERT INTO playground.target (data, source_id, processed_at)
                SELECT data, source_id, processed_at FROM playground.staging
                WHERE processed_at IS NOT NULL')
    ]
);
```

### 4. With Variables

```sql
SELECT df.create_workflow(
    name => 'process-order',
    steps => ARRAY[
        df.sql('SELECT id FROM playground.orders
                WHERE status = ''pending'' LIMIT 1',
               result_name => 'order_id'),
        df.sql('UPDATE playground.orders
                SET status = ''processing'' WHERE id = $order_id'),
        df.sleep(2),
        df.sql('UPDATE playground.orders
                SET status = ''completed'', processed_at = now()
                WHERE id = $order_id')
    ]
);
```

### 5. Parallel Execution

```sql
SELECT df.create_workflow(
    name => 'parallel-counts',
    steps => ARRAY[
        df.join(ARRAY[
            df.sql('SELECT COUNT(*) as user_count FROM playground.users'),
            df.sql('SELECT COUNT(*) as order_count FROM playground.orders')
        ]),
        df.sql('INSERT INTO playground.logs (msg)
                VALUES (''Parallel counts complete'')')
    ]
);
```

### 6. Conditional Logic

```sql
SELECT df.create_workflow(
    name => 'check-task-load',
    steps => ARRAY[
        df.if(
            condition => 'SELECT COUNT(*) > 3 FROM playground.task_queue
                          WHERE status = ''pending''',
            then_steps => ARRAY[
                df.sql('INSERT INTO playground.logs (msg, level)
                        VALUES (''High load!'', ''warning'')')
            ],
            else_steps => ARRAY[
                df.sql('INSERT INTO playground.logs (msg)
                        VALUES (''Queue normal'')')
            ]
        )
    ]
);
```

#### Branching on Row Count with `df.if_rows`

Use `df.if_rows()` to branch based on whether a named result has rows — without executing an extra SQL query:

```sql
SELECT df.create_workflow(
    name => 'check-pending',
    steps => ARRAY[
        df.sql($$SELECT id FROM orders WHERE status = 'pending'$$,
               result_name => 'pending'),
        df.if_rows(
            result => 'pending',
            then_steps => ARRAY[
                df.sql($$UPDATE orders SET status = 'processing' WHERE id = $pending.id$$)
            ],
            else_steps => ARRAY[
                df.sql($$INSERT INTO logs (msg) VALUES ('No pending orders')$$)
            ]
        )
    ]
);
```

### 7. Task Queue Processor

```sql
SELECT df.create_workflow(
    name => 'process-next-task',
    steps => ARRAY[
        df.sql('UPDATE playground.task_queue
                SET status = ''processing'', started_at = now()
                WHERE id = (
                    SELECT id FROM playground.task_queue
                    WHERE status = ''pending''
                    ORDER BY priority DESC, created_at
                    LIMIT 1
                    FOR UPDATE SKIP LOCKED
                )
                RETURNING id, payload',
               result_name => 'task'),
        df.sleep(1),
        df.sql('UPDATE playground.task_queue
                SET status = ''completed'', completed_at = now()
                WHERE status = ''processing''')
    ]
);
```

---

## HTTP Requests

Use `df.http()` to make HTTP requests to external APIs, webhooks, or services. HTTP requests are executed as durable activities - they survive crashes and can be retried.

### df.http() Step Function

```sql
df.http(
    url TEXT,                              -- Required: endpoint URL
    method TEXT DEFAULT 'POST',            -- GET, POST, PUT, DELETE, PATCH
    body TEXT DEFAULT NULL,                -- Request body (JSON)
    headers JSONB DEFAULT '{}',            -- Custom headers
    timeout_seconds INT DEFAULT 30,
    result_name TEXT DEFAULT NULL           -- Optional: name for referencing result
) RETURNS df.step                           -- Step descriptor
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
SELECT df.create_workflow(
    name => 'fetch-user',
    steps => ARRAY[
        df.http('https://api.example.com/users/123', 'GET',
                result_name => 'user'),
        df.sql('INSERT INTO users_cache (data)
                VALUES (($user::jsonb->>''body'')::jsonb)')
    ]
);
```

#### 2. POST with JSON Body

```sql
SELECT df.create_workflow(
    name => 'create-order',
    steps => ARRAY[
        df.http(
            'https://api.example.com/orders',
            'POST',
            '{"product_id": 42, "quantity": 2}',
            result_name => 'response'
        ),
        df.if(
            condition => 'SELECT ($response::jsonb->>''ok'')::boolean',
            then_steps => ARRAY[
                df.sql('INSERT INTO playground.logs (msg) VALUES (''Order created'')')
            ],
            else_steps => ARRAY[
                df.sql('INSERT INTO playground.logs (msg, level)
                        VALUES (''Order failed'', ''error'')')
            ]
        )
    ]
);
```

#### 3. HTTP with Custom Headers

```sql
SELECT df.create_workflow(
    name => 'authenticated-request',
    steps => ARRAY[
        df.http(
            'https://api.example.com/secure/data',
            'GET',
            NULL,
            '{"Authorization": "Bearer token123", "X-Custom-Header": "value"}'::jsonb,
            result_name => 'response'
        ),
        df.sql('SELECT ($response::jsonb->>''body'')::jsonb')
    ]
);
```

#### 4. Parallel API Calls

```sql
SELECT df.create_workflow(
    name => 'parallel-fetch',
    steps => ARRAY[
        df.join(
            ARRAY[
                df.http('https://api.example.com/users', 'GET'),
                df.http('https://api.example.com/products', 'GET')
            ],
            result_name => 'results'
        ),
        df.sql('INSERT INTO playground.logs (msg)
                VALUES (''Fetched users and products'')')
    ]
);
```

#### 5. HTTP with Variable Substitution

```sql
SELECT df.create_workflow(
    name => 'send-notification',
    steps => ARRAY[
        df.sql('SELECT id, email FROM playground.users WHERE id = 1',
               result_name => 'user'),
        df.http(
            'https://api.example.com/notifications',
            'POST',
            '{"user_id": "$user.id", "message": "Welcome!"}',
            result_name => 'notification'
        ),
        df.sql('UPDATE playground.users SET notified = true
                WHERE id = ($user::jsonb->>''id'')::int')
    ]
);
```

#### 6. Handle 4xx Errors in Workflow

```sql
SELECT df.create_workflow(
    name => 'fetch-or-create-user',
    steps => ARRAY[
        df.http('https://api.example.com/users/999', 'GET',
                result_name => 'response'),
        df.if(
            condition => 'SELECT ($response::jsonb->>''status'')::int = 404',
            then_steps => ARRAY[
                df.sql('INSERT INTO playground.logs (msg)
                        VALUES (''User not found - creating new'')'),
                df.http('https://api.example.com/users', 'POST',
                        '{"name": "New User"}')
            ],
            else_steps => ARRAY[
                df.sql('SELECT ($response::jsonb->>''body'')::jsonb')
            ]
        )
    ]
);
```

#### 7. Webhook Integration

```sql
SELECT df.create_workflow(
    name => 'send-order-webhook',
    steps => ARRAY[
        df.sql('SELECT order_id, status, total FROM playground.orders WHERE id = 1',
               result_name => 'order'),
        df.http(
            'https://partner.example.com/webhook/order-update',
            'POST',
            '{"order_id": "$order.order_id", "status": "$order.status", "total": "$order.total"}',
            '{"X-Webhook-Secret": "shared-secret-123"}'::jsonb,
            result_name => 'webhook_response'
        ),
        df.sql('INSERT INTO playground.logs (msg)
                VALUES (''Webhook sent: '' || ($webhook_response::jsonb->>''status''))')
    ]
);
```

#### 8. Scheduled API Polling

```sql
SELECT df.create_workflow(
    name => 'api-health-monitor',
    steps => ARRAY[
        df.loop(
            df.wait_for_schedule('*/5 * * * *'),
            df.http('https://api.example.com/status', 'GET',
                    result_name => 'status'),
            df.if(
                condition => 'SELECT ($status::jsonb->''body''::jsonb->>''healthy'')::boolean = false',
                then_steps => ARRAY[
                    df.sql('INSERT INTO playground.logs (msg, level)
                            VALUES (''Service unhealthy!'', ''error'')')
                ],
                else_steps => ARRAY[
                    df.sql('SELECT ''healthy''')
                ]
            )
        )
    ]
);
```

#### 9. Real-World Example: Scheduled GitHub Commit Sync

This example creates a scheduled durable workflow that fetches the last 5 commits from a GitHub repository every 30 minutes and stores them in a table. It demonstrates variables, HTTP requests, parsing complex JSON, and scheduled loops.

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

-- Configure the sync URL using durable workflow variable
SELECT df.setvar('github_url', 'https://api.github.com/repos/microsoft/duroxide/commits?per_page=5');

-- Start scheduled commit sync (runs every 30 minutes)
SELECT df.create_workflow(
    name => 'github-commit-sync',
    steps => ARRAY[
        df.loop(
            df.http(
                '{github_url}',
                'GET',
                NULL,
                '{"Accept": "application/vnd.github.v3+json", "User-Agent": "pg_durable"}'::jsonb,
                result_name => 'response'
            ),
            df.sql('INSERT INTO github_commits (sha, author, message, committed_at)
                    SELECT
                        c->>''sha'',
                        c->''commit''->''author''->>''name'',
                        c->''commit''->>''message'',
                        (c->''commit''->''author''->>''date'')::timestamptz
                    FROM jsonb_array_elements(($response::jsonb->>''body'')::jsonb) AS c
                    ON CONFLICT (sha) DO UPDATE SET
                        fetched_at = now()
                    RETURNING sha'),
            df.wait_for_schedule('*/30 * * * *')
        )
    ]
);

-- Check the results
SELECT sha, author, committed_at, LEFT(message, 50) AS message FROM github_commits;

-- To stop the sync:
-- SELECT df.cancel('<instance_id>', 'Stopping commit sync');
```

This demonstrates:
- Configuring API endpoints with durable workflow variables
- Calling a real REST API (GitHub)
- Setting required headers (User-Agent, Accept)
- Parsing nested JSON (extracting `commit.author.name` and `commit.message`)
- Upserting with ON CONFLICT
- Creating a scheduled loop that runs every 30 minutes

---

## Durable Workflow Variables

Durable workflow variables allow you to configure workflows with external values like API endpoints, credentials, or configuration settings. Variables are set **before** starting a workflow and remain **immutable** during execution.

### How Variables Work

1. **Set variables** using `df.setvar()` before calling `df.create_workflow()`
2. Variables are **captured** when `df.create_workflow()` is called
3. Variables are **immutable** during workflow execution
4. Use `{varname}` syntax in SQL to substitute variable values

### Variable Functions

| Function | Description |
|----------|-------------|
| `df.setvar(name, value)` | Set a variable (before workflow starts) |
| `df.getvar(name)` | Get a variable value |
| `df.unsetvar(name)` | Remove a variable |
| `df.clearvars()` | Clear all variables |

> **Important**: `df.setvar()`, `df.unsetvar()`, and `df.clearvars()` cannot be called from within a running workflow. They are for configuration only.

### System Variables

These read-only variables are automatically available during workflow execution:

| Variable | Description |
|----------|-------------|
| `{sys_instance_id}` | Current workflow instance ID |
| `{sys_label}` | Workflow label (if provided) |

### Variable Substitution

Use `{varname}` in SQL queries to substitute variable values:

```sql
-- Set up configuration
SELECT df.setvar('api_base', 'https://api.example.com');
SELECT df.setvar('api_key', 'secret123');

-- Start workflow using variables
SELECT df.create_workflow(
    name => 'fetch-users',
    steps => ARRAY[
        df.http('{api_base}/users', 'GET', NULL,
                '{"Authorization": "Bearer {api_key}"}'::jsonb),
        df.sql('INSERT INTO playground.logs (msg) VALUES (''Fetched users'')')
    ]
);
```

### Example: Configurable ETL Pipeline

```sql
-- Configure the pipeline
SELECT df.setvar('source_table', 'raw_orders');
SELECT df.setvar('target_table', 'processed_orders');
SELECT df.setvar('batch_size', '100');

-- Start the pipeline
SELECT df.create_workflow(
    name => 'etl-pipeline',
    steps => ARRAY[
        df.sql('SELECT * FROM {source_table} LIMIT {batch_size}::int',
               result_name => 'batch'),
        df.sql('INSERT INTO {target_table} SELECT * FROM ($batch) AS source')
    ]
);
```

### Example: Using System Variables for Logging

```sql
SELECT df.create_workflow(
    name => 'audit-example',
    steps => ARRAY[
        df.sql('INSERT INTO audit_log (instance_id, label, action, ts)
                VALUES (''{sys_instance_id}'', ''{sys_label}'', ''started'', now())'),
        df.sql('SELECT process_data()'),
        df.sql('INSERT INTO audit_log (instance_id, label, action, ts)
                VALUES (''{sys_instance_id}'', ''{sys_label}'', ''completed'', now())')
    ]
);
```

### Example: HTTP with Variables

```sql
-- Configure API endpoint
SELECT df.setvar('webhook_url', 'https://hooks.example.com/notify');

-- Workflow that calls the configured webhook
SELECT df.create_workflow(
    name => 'order-webhook',
    steps => ARRAY[
        df.sql('SELECT id, status FROM orders WHERE id = 1',
               result_name => 'order'),
        df.http('{webhook_url}', 'POST', '{"order_id": "$order"}')
    ]
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
│  │ df.create_workflow(name, steps)                      │    │
│  │   → Variables CAPTURED (snapshot taken)             │    │
│  │   → Variables become IMMUTABLE for this execution   │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Background Worker (Workflow Execution)                      │
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

Use `df.loop()` to create workflows that run forever. Each iteration creates a new execution with fresh state (via continue-as-new).

```sql
-- Simple heartbeat every 30 seconds
SELECT df.create_workflow(
    name => 'heartbeat-30s',
    steps => ARRAY[
        df.loop(
            df.sql('INSERT INTO playground.heartbeats (ts) VALUES (now())'),
            df.sleep(30)
        )
    ]
);
```

### Cron-Style Scheduling

Use `df.wait_for_schedule()` with a cron expression:

```sql
-- Every minute: log a tick
SELECT df.create_workflow(
    name => 'every-minute-tick',
    steps => ARRAY[
        df.loop(
            df.wait_for_schedule('* * * * *'),
            df.sql('INSERT INTO playground.logs (msg)
                    VALUES (''Minute tick: '' || now()::text)')
        )
    ]
);

-- Every 5 minutes: check for pending tasks
SELECT df.create_workflow(
    name => 'task-monitor-5min',
    steps => ARRAY[
        df.loop(
            df.wait_for_schedule('*/5 * * * *'),
            df.sql('SELECT COUNT(*) as pending FROM playground.task_queue
                    WHERE status = ''pending''',
                   result_name => 'count'),
            df.sql('INSERT INTO playground.logs (msg)
                    VALUES (''Pending tasks: '' || $count)')
        )
    ]
);

-- Hourly: clean up old logs
SELECT df.create_workflow(
    name => 'hourly-log-cleanup',
    steps => ARRAY[
        df.loop(
            df.wait_for_schedule('0 * * * *'),
            df.sql('DELETE FROM playground.logs
                    WHERE created_at < now() - interval ''24 hours''')
        )
    ]
);

-- Daily at midnight: archive completed orders
SELECT df.create_workflow(
    name => 'daily-order-archive',
    steps => ARRAY[
        df.loop(
            df.wait_for_schedule('0 0 * * *'),
            df.sql('UPDATE playground.orders SET status = ''archived''
                    WHERE status = ''completed''
                    AND processed_at < now() - interval ''7 days''')
        )
    ]
);

-- Weekdays at 9am: generate report
SELECT df.create_workflow(
    name => 'weekday-morning-report',
    steps => ARRAY[
        df.loop(
            df.wait_for_schedule('0 9 * * 1-5'),
            df.sql('SELECT playground.generate_report(''daily_summary'')')
        )
    ]
);
```

### While Loops

Use `df.loop(steps..., condition)` to repeat while a condition is true:

```sql
-- Process items while queue has entries
SELECT df.create_workflow(
    name => 'queue-processor',
    steps => ARRAY[
        df.loop(
            df.sql('SELECT process_next_item()'),
            df.sleep(1),
            condition => 'SELECT count(*) > 0 FROM task_queue WHERE status = ''pending'''
        )
    ]
);
```

### Breaking Out of Loops

Use `df.break()` to exit a loop from inside its body:

```sql
-- Process batches until done flag is set
SELECT df.create_workflow(
    name => 'batch-processor',
    steps => ARRAY[
        df.loop(
            df.sql('SELECT process_batch()', result_name => 'batch'),
            df.if(
                condition => 'SELECT ($batch::jsonb->>''done'')::boolean',
                then_steps => ARRAY[
                    df.break('{"status": "complete", "total": $batch.count}')
                ],
                else_steps => ARRAY[
                    df.sleep(5)
                ]
            )
        )
    ]
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

Signals allow external code to send events to running durable workflows. This enables:
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
- `instance_id` - The durable workflow instance ID (required)
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
SELECT df.create_workflow(
    name => 'order-approval',
    steps => ARRAY[
        df.sql('SELECT order_id, total FROM orders WHERE id = 1',
               result_name => 'order'),
        df.wait_for_signal('approval', 86400,
                           result_name => 'sig'),
        df.if(
            condition => 'SELECT NOT ($sig::jsonb->>''timed_out'')::boolean
                AND ($sig::jsonb->''data''->>''approved'')::boolean',
            then_steps => ARRAY[
                df.sql('UPDATE orders SET status = ''approved'' WHERE id = $order_id')
            ],
            else_steps => ARRAY[
                df.sql('UPDATE orders SET status = ''rejected'' WHERE id = $order_id')
            ]
        )
    ]
);

-- Later, approve the order (using the instance ID returned by df.create_workflow)
SELECT df.signal('a1b2c3d4', 'approval', '{"approved": true, "approver": "jane@acme.com"}');
```

### Example: Multi-Party Approval

Wait for multiple approvals using `df.join()`:

```sql
SELECT df.create_workflow(
    name => 'multi-approval',
    steps => ARRAY[
        df.sql('SELECT doc_id FROM documents WHERE id = 1',
               result_name => 'doc'),
        df.join(
            ARRAY[
                df.wait_for_signal('legal_approval'),
                df.wait_for_signal('tech_approval'),
                df.wait_for_signal('mgmt_approval')
            ],
            result_name => 'approvals'
        ),
        df.sql('UPDATE documents SET status = ''approved'' WHERE id = $doc_id')
    ]
);

-- Each approver sends their signal independently
SELECT df.signal('abc123', 'legal_approval', '{"approved": true}');
SELECT df.signal('abc123', 'tech_approval', '{"approved": true}');
SELECT df.signal('abc123', 'mgmt_approval', '{"approved": true}');
```

### Example: Webhook Callback Pattern

Start a job and wait for external callback:

```sql
SELECT df.create_workflow(
    name => 'webhook-job',
    steps => ARRAY[
        df.http('{job_api}/start', 'POST', '{"type": "render"}',
                result_name => 'job'),
        df.wait_for_signal('job_complete', 3600,
                           result_name => 'result'),
        df.if(
            condition => 'SELECT NOT ($result::jsonb->>''timed_out'')::boolean',
            then_steps => ARRAY[
                df.sql('INSERT INTO completed_jobs VALUES ($job, $result)')
            ],
            else_steps => ARRAY[
                df.sql('INSERT INTO failed_jobs VALUES ($job, ''timeout'')')
            ]
        )
    ]
);

-- External system calls back via df.signal when job completes
-- (e.g., via a webhook endpoint that calls df.signal)
```

---

## Multi-Database Support

By default, all SQL in a workflow runs in the database where the extension is installed (the `pg_durable.database` GUC, typically `postgres`). You can target a different database on the same cluster by passing the `database` parameter to `df.create_workflow()`.

### Running SQL in Another Database

```sql
-- Run a query in the 'analytics' database
SELECT df.create_workflow(
    name => 'daily-report',
    steps => ARRAY[
        df.sql('INSERT INTO reports (date, total) SELECT now(), count(*) FROM events')
    ],
    database => 'analytics'
);
```

All SQL steps in the workflow execute against the specified database. The step functions are unchanged — database is purely a property of the instance.

### Key Points

- **One database per invocation.** All SQL in a single `df.create_workflow()` call targets the same database. For cross-database workflows, start separate durable workflows per database, or use `dblink`/`postgres_fdw` within your SQL.
- **Backwards compatible.** Omitting `database` (or passing NULL) uses the extension database — existing queries are unaffected.
- **Validated at submission time.** If the database doesn't exist, `df.create_workflow()` raises an immediate error.
- **Role isolation preserved.** The workflow runs as the user who called `df.create_workflow()`, not the background worker. The login role must be able to connect to the target database (`GRANT CONNECT`).

### Example: Multi-Tenant Processing

```sql
-- Process data in each tenant database
SELECT df.create_workflow(
    name => 'tenant-alpha-refresh',
    steps => ARRAY[df.sql('CALL refresh_materialized_views()')],
    database => 'tenant_alpha'
);

SELECT df.create_workflow(
    name => 'tenant-beta-refresh',
    steps => ARRAY[df.sql('CALL refresh_materialized_views()')],
    database => 'tenant_beta'
);
```

---

## Visualizing Workflows

### df.explain()

Use `df.explain()` to visualize workflow structure. It works in two modes:

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

**2. Dry-Run Preview** - Pass a steps array to `df.explain()` to visualize without executing:

```sql
SELECT df.explain(
    ARRAY[
        df.sql('SELECT 1', result_name => 'a'),
        df.sql('SELECT 2', result_name => 'b'),
        df.if(
            condition => 'SELECT $a > 0',
            then_steps => ARRAY[df.sql('SELECT ''yes''')],
            else_steps => ARRAY[df.sql('SELECT ''no''')]
        )
    ]
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
    ARRAY[
        df.sql($$SELECT * FROM staging WHERE status = 'pending' LIMIT 1$$,
               result_name => 'record'),
        df.if(
            condition => 'SELECT $record IS NOT NULL',
            then_steps => ARRAY[
                df.sql('UPDATE staging SET status = ''validating'' WHERE id = $record.id'),
                df.join(ARRAY[
                    df.sql('SELECT validate_schema($record.data)', result_name => 'schema_ok'),
                    df.sql('SELECT validate_rules($record.data)', result_name => 'rules_ok')
                ]),
                df.if(
                    condition => 'SELECT $schema_ok AND $rules_ok',
                    then_steps => ARRAY[
                        df.sql('INSERT INTO target SELECT * FROM staging WHERE id = $record.id'),
                        df.sql('UPDATE staging SET status = ''loaded'' WHERE id = $record.id')
                    ],
                    else_steps => ARRAY[
                        df.sql('UPDATE staging SET status = ''failed'' WHERE id = $record.id')
                    ]
                )
            ],
            else_steps => ARRAY[
                df.sql('SELECT ''no pending records''')
            ]
        )
    ]
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
    ARRAY[
        df.loop(
            df.wait_for_schedule('0 * * * *'),
            df.sql('DELETE FROM logs WHERE created_at < now() - interval ''7 days''',
                   result_name => 'deleted'),
            df.if(
                condition => 'SELECT $deleted > 0',
                then_steps => ARRAY[
                    df.sql('INSERT INTO audit (action, count) VALUES (''cleanup'', $deleted)')
                ],
                else_steps => ARRAY[
                    df.sql('SELECT ''nothing to clean''')
                ]
            )
        )
    ]
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
-- Visualize the daily-order-archive workflow before starting it
SELECT df.explain(
    ARRAY[
        df.loop(
            df.wait_for_schedule('0 0 * * *'),
            df.sql('SELECT COUNT(*) as cnt FROM playground.orders
                    WHERE status = ''completed''
                    AND processed_at < now() - interval ''7 days''',
                   result_name => 'to_archive'),
            df.if(
                condition => 'SELECT $to_archive > 0',
                then_steps => ARRAY[
                    df.sql('UPDATE playground.orders SET status = ''archived''
                            WHERE status = ''completed''
                            AND processed_at < now() - interval ''7 days''',
                           result_name => 'archived'),
                    df.sql('INSERT INTO playground.logs (msg, level)
                            VALUES (''Archived '' || $archived || '' orders'', ''info'')')
                ],
                else_steps => ARRAY[
                    df.sql('INSERT INTO playground.logs (msg)
                            VALUES (''No orders to archive'')')
                ]
            )
        )
    ]
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

For loops and retried workflows, see the execution history:

```sql
-- Last 5 executions (default)
SELECT * FROM df.instance_executions('a1b2c3d4');

-- Last 20 executions
SELECT * FROM df.instance_executions('a1b2c3d4', 20);
```

**Columns:** `execution_id`, `status`, `event_count`, `duration_ms`, `output`

### Workflow Nodes

See the workflow graph structure:

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

### Worker Liveness

Check whether the background worker is alive and healthy:

```sql
SELECT started_at, last_seen_at,
       now() - last_seen_at AS time_since_last_heartbeat
  FROM df._worker_epoch;
```

- `time_since_last_heartbeat < 15 seconds` → worker is alive (recent heartbeat)
- No rows in `df._worker_epoch` → worker hasn't initialized yet

The background worker updates `last_seen_at` every ~5 seconds as part of its normal operation.

---

## User Isolation & Privileges

### How Privilege Isolation Works

Durable workflows **execute with the privileges of the user who submitted them**, not the background worker's privileges. This means:

- ✅ Your SQL runs as **you**, with your permissions
- ✅ You can only access tables and data **you** have access to
- ✅ Non-superusers cannot escalate privileges through durable workflows
- ✅ Superusers' workflows run with superuser privileges (expected behavior)

**Example:**

```sql
-- Alice creates a table she owns
CREATE USER alice;
CREATE TABLE alice_data (secret TEXT);
ALTER TABLE alice_data OWNER TO alice;

-- Alice submits a durable workflow
SET SESSION AUTHORIZATION alice;
SELECT df.create_workflow(
    name => 'read-my-data',
    steps => ARRAY[df.sql('SELECT * FROM alice_data')]
);
-- ✅ This works - alice can access her own table

SELECT df.create_workflow(
    name => 'read-bob-data',
    steps => ARRAY[df.sql('SELECT * FROM bob_data')]
);
-- ❌ This fails - alice doesn't have permission
```

### How Identity Is Captured

When you call `df.create_workflow()`, pg_durable captures two pieces of identity:

1. **Login role** (`session_user`) - The user you authenticated as
2. **Effective role** (`current_user`) - Your current effective privileges (after `SET ROLE`, if used)

The background worker then:
1. Connects to PostgreSQL as your **login role**
2. Executes `SET ROLE` to your **effective role** 
3. Runs your SQL with the correct privileges

### Working with Group Roles

You can use `SET ROLE` to switch to a group role before submitting a durable workflow:

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
SELECT df.create_workflow(
    name => 'analyst-query',
    steps => ARRAY[df.sql('SELECT * FROM analyst_reports')]
);
-- ✅ Runs as 'analysts', alice's session user is used for authentication
```

### What Happens If a Role Is Dropped?

If the user who submitted a workflow is dropped **before execution**:

- The background worker will fail to connect
- The instance transitions to `failed` status
- You'll see a clear error message: `"Failed to connect as 'username'..."`

**Important:** Don't drop roles that have running or pending durable workflows.

### Current Limitations

#### HTTP Requests

HTTP requests (`df.http()`) currently execute with the **background worker's privileges**, not the submitting user's privileges:

- All users can make HTTP requests to the same endpoints
- No user-specific URL allowlists

**Security model:** Outbound HTTP is controlled by compile-time Cargo features and is off by default. When enabled, a hardcoded SSRF IP blocklist and domain allow-list are enforced — all requests to private/reserved IP ranges are blocked and only approved Azure service domains are permitted (e.g. `*.blob.core.windows.net`, `*.openai.azure.com`). These restrictions cannot be bypassed by any database user, including superusers. See `docs/http-security.md` for the full security model and feature flag reference.

**Future:** Per-user HTTP isolation and URL allowlists are planned.

#### Cross-Instance Visibility

Row-level security (RLS) restricts each user to their own instances and nodes:

- Users can only see instances they submitted (`submitted_by = current_user`)
- `df.list_instances()`, `df.status()`, `df.result()` automatically filter to the caller's own data
- `df.cancel()` and `df.signal()` check ownership before acting — attempts on other users' instances return "Instance not found or access denied"
- Superusers bypass RLS and can see all instances (standard PostgreSQL behavior)

### Security Best Practices

1. **Worker role must be superuser** — The background worker role (`pg_durable.worker_role`) must be a superuser to bypass RLS and manage all instances
2. **Review df.vars usage** — Variables are scoped per-user via RLS, but avoid storing secrets in plain text
3. **Use labels carefully** — Instance labels are visible only to the submitting user (RLS-filtered) and superusers
4. **Monitor instances** — Superusers can use `df.list_instances()` to see all users' instances; regular users see only their own

### Privilege Grants

`CREATE EXTENSION pg_durable` does **not** grant privileges to `PUBLIC`. After installing the extension, the admin must explicitly grant access to each application role. RLS ensures per-user isolation even when multiple roles share the same grants.

**Recommended — use the built-in helper:**

```sql
-- Grant all required df privileges to a role (must be run by a superuser)
SELECT df.grant_usage('app_role');
```

`df.grant_usage()` issues every GRANT a role needs to call step functions, submit workflows, and read results. Only superusers can execute it (EXECUTE is revoked from PUBLIC). **This function is the authoritative source for the required grant set** — see the equivalent manual grants below for the full list.

<details>
<summary>Equivalent manual grants (for reference)</summary>

```sql
GRANT USAGE ON SCHEMA df TO app_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO app_role;
REVOKE EXECUTE ON FUNCTION df.grant_usage(TEXT) FROM app_role;   -- admin-only
REVOKE EXECUTE ON FUNCTION df.revoke_usage(TEXT) FROM app_role;  -- admin-only
GRANT SELECT ON df.instances TO app_role;
GRANT UPDATE (status, updated_at) ON df.instances TO app_role;
GRANT SELECT ON df.nodes TO app_role;
GRANT INSERT (id, label, root_node, submitted_by, database) ON df.instances TO app_role;
GRANT INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database) ON df.nodes TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO app_role;
```

</details>

Alternatively, create an indirection role and grant membership to application roles:

```sql
-- Create a shared role for pg_durable access
CREATE ROLE pg_durable_user NOLOGIN;
SELECT df.grant_usage('pg_durable_user');

-- Grant membership to application roles
GRANT pg_durable_user TO app_backend, etl_service;
```

> **Security note:** If a user/role has INSERT privilege on `df.nodes`, they can construct workflow graphs with any available node type (including powerful types like HTTP). Granular restrictions on node types are deferred to future work.

> **Note:** `GRANT EXECUTE ON ALL FUNCTIONS` only applies to functions that exist when the grant runs. After upgrading pg_durable with `ALTER EXTENSION pg_durable UPDATE`, re-run `df.grant_usage('role')` (or re-issue the manual grants) so new functions are accessible.

Users get `SELECT` and `INSERT` on `df.instances` and `df.nodes` (required for `df.create_workflow()`, `df.status()`, `df.result()`). Column-level `UPDATE` on `(status, updated_at)` allows `df.cancel()` to set status. No full `UPDATE` or `DELETE` — the identity column (`submitted_by`) and structural columns are protected.

> **Note:** `df.vars` uses per-user scoping via an `owner` column and RLS — each user can only read and write their own variables. Superusers bypass RLS but the DSL functions (`df.setvar()`, `df.getvar()`, etc.) still scope to the calling user via explicit filters. Avoid storing secrets in plain text.

### Revoking Privileges

To remove a role's access to pg_durable:

```sql
SELECT df.revoke_usage('app_role');
```

This revokes all privileges previously granted by `df.grant_usage()`.

### Hardening Upgraded Installs

Installs upgraded from v0.1.1 retain legacy PUBLIC grants. To lock down an upgraded install to match the fresh-install security posture:

```sql
-- Revoke legacy PUBLIC grants
SELECT df.revoke_usage('PUBLIC');

-- Then grant to specific roles
SELECT df.grant_usage('app_role');
```

---

## Connection Limits

pg_durable uses multiple PostgreSQL connections for different purposes. Four GUCs let you control the connection budget to match your deployment's resources.

### Connection Architecture

The background worker maintains three categories of connections:

| Category | Purpose | GUC | Default |
|----------|---------|-----|---------|
| **Management pool** | Extension lifecycle checks, graph loading, status updates | `pg_durable.max_management_connections` | 6 |
| **Duroxide pool** | Orchestration state, LISTEN/NOTIFY for work dispatch | `pg_durable.max_duroxide_connections` | 10 |
| **User-execution** | Per-SQL-node connections authenticated as the submitting user | `pg_durable.max_user_connections` | 10 |

Each PG backend session (user calling `df.create_workflow()`, `df.cancel()`, etc.) creates **1 additional connection** for duroxide client operations.

### GUC Reference

All connection-limit GUCs are **Postmaster-context** — set them in `postgresql.conf` and restart PostgreSQL.

```ini
# postgresql.conf

# Management pool: graph loading, status updates, lifecycle polling
# Minimum: 1 (warning logged). Increase for high-concurrency workloads.
pg_durable.max_management_connections = 6

# Duroxide provider pool: orchestration state + LISTEN/NOTIFY
# Minimum: 2 (1 reserved for listener). Worker refuses to start if < 2.
pg_durable.max_duroxide_connections = 10

# Maximum concurrent SQL node executions (user connections)
# Additional executions queue until a slot frees up or timeout expires.
pg_durable.max_user_connections = 10

# How long (seconds) a SQL node waits for a user-execution slot
# before failing with an error.
pg_durable.execution_acquire_timeout = 30
```

### Connection Budget Formula

To calculate the total connections pg_durable will use:

```
Total = max_management_connections
      + max_duroxide_connections
      + max_user_connections
      + (active_backend_sessions × 1)
```

With defaults and 5 connected users: `6 + 10 + 10 + 5 = 31 connections`.

> **Tip**: Ensure PostgreSQL's `max_connections` is large enough to accommodate pg_durable's budget plus your application's direct connections.

### Backpressure Behavior

When all user-execution slots are occupied, additional SQL node executions **queue** (they don't fail immediately). The semaphore-based backpressure ensures:

- Queued executions proceed as slots free up
- If the wait exceeds `execution_acquire_timeout`, the SQL node fails with:
  ```
  pg_durable: connection limit reached (max_user_connections=10).
  Timed out after 30s waiting for an available execution slot.
  ```
- The failed node causes the workflow to enter `failed` status
- Other nodes in the same workflow that have already acquired slots continue normally

### Startup Validation

The background worker validates GUC values at startup:

- `max_duroxide_connections < 2` → worker **refuses to start** (logs error and exits)
- `max_management_connections = 1` → worker starts but logs a **warning**
- Invalid values are caught before any connections are created

### Interaction with PostgreSQL CONNECTION LIMIT

PostgreSQL's per-role `CONNECTION LIMIT` (set via `ALTER ROLE ... CONNECTION LIMIT n`) counts against the **authenticating role** (the role in the connection string), not the role set via `SET ROLE`.

For pg_durable, this means:
- **Management and duroxide pools** authenticate as `pg_durable.worker_role` — all pool connections count against that role's limit
- **User-execution connections** authenticate as the submitting user (`submitted_by`) — these count against *that* role's limit
- **Backend connections** authenticate as whatever role the application uses

If you use per-role connection limits, ensure each role's limit accounts for pg_durable's usage.

### Example Configurations

**Small deployment** (single app, few concurrent workflows):
```ini
pg_durable.max_management_connections = 3
pg_durable.max_duroxide_connections = 5
pg_durable.max_user_connections = 5
# Budget: 3 + 5 + 5 + backends ≈ 15 connections
```

**Medium deployment** (defaults — suitable for most workloads):
```ini
# Use defaults: 6 + 10 + 10 + backends ≈ 28 connections
```

**Large deployment** (high concurrency, many parallel workflows):
```ini
pg_durable.max_management_connections = 10
pg_durable.max_duroxide_connections = 15
pg_durable.max_user_connections = 50
pg_durable.execution_acquire_timeout = 60
# Budget: 10 + 15 + 50 + backends ≈ 80 connections
```

---

## Troubleshooting

### Extension Exists But Workflows Don't Start

**Symptom**: You've run `CREATE EXTENSION pg_durable` but `df.create_workflow()` returns an instance ID that never completes.

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

**Symptom**: Calling `df.create_workflow()`, `df.status()`, or monitoring functions returns an error:
```
Failed to connect to duroxide store: ...
```

**Possible Causes**:

1. **Extension not created**: Run `CREATE EXTENSION pg_durable`

2. **Background worker not yet ready**: After `CREATE EXTENSION`, the background worker initializes the engine schema asynchronously (normally within a few seconds). Simply retry after a short delay — once the worker finishes, the error resolves on its own.

3. **Database connection issues**: PostgreSQL is not accepting connections
   - Check PostgreSQL is running
   - Verify connection string environment variables if customized

### Background Worker Not Initializing

**Symptom**: After `CREATE EXTENSION`, workflows still don't execute, and logs show:
```
pg_durable: waiting for CREATE EXTENSION pg_durable...
```

**Cause**: The background worker is waiting for the extension to be created in the database it's connected to.

**Solution**:
1. Verify you're creating the extension in the correct database
2. Check which database the background worker connects to:
   - Defaults to the database specified by `PGDATABASE` environment variable or `postgres`
   - The background worker only processes workflows in **one** database
3. If you need pg_durable in a different database:
   - Create the extension in the database the background worker uses, OR
   - Update environment variables and restart PostgreSQL

### Extension Drop/Recreate Issues

**Symptom**: After `DROP EXTENSION pg_durable CASCADE`, workflows still appear to be running or you see errors.

**Explanation**: The background worker polls for extension existence every 5 seconds. After detecting a drop:
- It shuts down the duroxide runtime (takes ~10 seconds)
- Returns to waiting for extension creation
- Any in-flight workflows are terminated

> ⚠️ **`CASCADE` is always required.** The duroxide schema contains tables and functions created by the background worker that are not directly owned by the extension. `DROP EXTENSION pg_durable` (without `CASCADE`) will fail with an error. Always use `DROP EXTENSION pg_durable CASCADE`.

**Solution**: Wait 15-20 seconds after `DROP EXTENSION` before recreating:
```sql
DROP EXTENSION pg_durable CASCADE;
-- Wait ~20 seconds for background worker to fully shut down
CREATE EXTENSION pg_durable;
```

### Workflows Complete But Results Are Empty

**Symptom**: `df.status()` shows `Completed` but `df.result()` returns empty or null.

**Possible Causes**:

1. **Query returns no rows**: The SQL query executed successfully but returned no data
   ```sql
   SELECT * FROM users WHERE id = 999999;  -- no such user
   ```
   
2. **Result not named**: Use `result_name` to capture results for later access
   ```sql
   -- Bad: result not captured
   SELECT df.create_workflow(
       name => 'example',
       steps => ARRAY[df.sql('SELECT id FROM users LIMIT 1')]
   );
   
   -- Good: result captured
   SELECT df.create_workflow(
       name => 'example',
       steps => ARRAY[
           df.sql('SELECT id FROM users LIMIT 1', result_name => 'user_id')
       ]
   );
   ```

3. **ETL workflow that doesn't return data**: If the workflow performs INSERTs/UPDATEs, those succeed without returning data. Add a final query to return status:
   ```sql
   SELECT df.create_workflow(
       name => 'etl-with-status',
       steps => ARRAY[
           df.sql('INSERT INTO logs (msg) VALUES (''done'')'),
           df.sql('SELECT ''success'' as status')
       ]
   );
   ```

### Slow Workflow Startup

**Symptom**: There's a delay between `df.create_workflow()` returning and the workflow actually executing.

**Explanation**: This is normal during:
- **Initial extension creation**: Background worker needs 1-5 seconds to initialize
- **After DROP/CREATE**: Background worker needs to reinitialize

**Solution**: If delays persist beyond startup:
1. Check PostgreSQL logs for errors
2. Verify the background worker is running (see "Extension Exists But Workflows Don't Start")
3. Check for resource contention (CPU, disk I/O, connection limits)

### Debugging Failed Workflows

When a durable workflow fails or produces unexpected results, use these steps to diagnose the issue from `psql` — no server log access required.

#### Step 1: Check Status

```sql
SELECT df.status('a1b2c3d4');
-- Returns: Completed, Failed, Running, Pending, or Canceled
```

If the status is `Failed`, proceed to the next steps. If it's `Completed` but results are wrong, skip to Step 3.

#### Step 2: Check the Overall Result

```sql
SELECT df.result('a1b2c3d4');
```

For failed instances, this often contains an error message from the runtime. Look for clues like connection errors, permission denied, or SQL syntax errors.

#### Step 3: Visualize the Execution Tree

```sql
SELECT df.explain('a1b2c3d4');
```

This shows the graph structure with status markers on each node:
- `✓ Completed` — node finished successfully
- `✗ Failed` — node encountered an error
- `⏳ Running` — node was in progress when the instance failed or was inspected
- `○ Pending` — node never started

`df.explain()` tells you **where** in the graph execution stopped, but not **why**. For that, inspect individual nodes.

#### Step 4: Inspect Individual Nodes

```sql
SELECT node_id, node_type, result_name, status, 
       left(query, 80) AS query,
       left(result, 120) AS result
FROM df.instance_nodes('a1b2c3d4');
```

This shows every node in the graph with its status and result. Key things to look for:

| What to check | What it means |
|---------------|---------------|
| A node with `status = 'failed'` | This is the node that caused the failure |
| A node with `result = NULL` and `status = 'completed'` | The SQL returned no rows |
| Result contains `{"jsonb": null}` | Possible type extraction issue — see "Known Limitations" below |
| A `running` node with no result | Execution was interrupted at this node |

#### Step 5: Trace Variable Flow

When using `result_name` to pass results between steps, check how values flow through the graph:

```sql
-- Show only nodes that produce named results
SELECT result_name, status, result
FROM df.instance_nodes('a1b2c3d4')
WHERE result_name IS NOT NULL
ORDER BY node_id;
```

If a downstream step received the wrong value:
1. Find the node that produced the variable (by `result_name`)
2. Check its `result` column — this is the JSON that gets substituted for `$name`
3. Verify the JSON structure matches what the downstream SQL expects

#### Example: Diagnosing a Variable Issue

```sql
-- Suppose step 'total' should produce a number, but downstream SQL fails
SELECT result_name, result FROM df.instance_nodes('a1b2c3d4')
WHERE result_name = 'total';

-- If result is: {"rows": [{"count": 42}], "row_count": 1}
-- Then $total substitutes the FULL JSON object, not just 42
-- Fix: use ($total::jsonb->'rows'->0->>'count')::int in downstream SQL
```

#### Known Limitations of Node Inspection

- **Template SQL only**: The `query` column shows the SQL template with `$name` placeholders, not the substituted SQL that actually ran. If variable substitution caused the bug, you won't see the final SQL.
- **No per-node error messages**: When a node fails, the error details are in the PostgreSQL server logs, not in the nodes table. The `result` column for a failed node may be NULL.

#### Debugging Checklist

1. **Status is `Failed`?** → Check `df.result()` for the error, then `df.instance_nodes()` to find which node failed
2. **Status is `Completed` but wrong results?** → Trace variable flow through `df.instance_nodes()`, check each named result
3. **Status stuck on `Pending` or `Running`?** → Check that the background worker is alive (see "Extension Exists But Workflows Don't Start")
4. **Variable has unexpected value?** → Check the producing node's `result` column; remember results are JSON objects, not bare values
5. **Still stuck?** → Check PostgreSQL server logs for lines starting with `pg_durable:` (see below)

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
-- Create and start a durable workflow
SELECT df.create_workflow(
    name => 'my-workflow',
    steps => ARRAY[df.sql('SELECT 1')]
);

-- Start in a different database
SELECT df.create_workflow(
    name => 'remote-job',
    steps => ARRAY[df.sql('SELECT 1')],
    database => 'analytics'
);

-- Sequential steps (array ordering)
SELECT df.create_workflow(
    name => 'sequential',
    steps => ARRAY[
        df.sql('SELECT 1'),
        df.sql('SELECT 2'),
        df.sql('SELECT 3')
    ]
);

-- Name a result with result_name
SELECT df.create_workflow(
    name => 'with-vars',
    steps => ARRAY[
        df.sql('SELECT 1', result_name => 'myvar'),
        df.sql('SELECT $myvar * 2')
    ]
);

-- Parallel join (wait for all)
SELECT df.create_workflow(
    name => 'parallel',
    steps => ARRAY[
        df.join(ARRAY[
            df.sql('SELECT 1'),
            df.sql('SELECT 2')
        ])
    ]
);

-- Race (first wins)
SELECT df.create_workflow(
    name => 'race',
    steps => ARRAY[
        df.race(ARRAY[
            df.sql('SELECT quick_result()'),
            df.sleep(30)
        ])
    ]
);

-- Conditional (if/then/else)
SELECT df.create_workflow(
    name => 'conditional',
    steps => ARRAY[
        df.if(
            condition => 'SELECT true',
            then_steps => ARRAY[df.sql('SELECT ''yes''')],
            else_steps => ARRAY[df.sql('SELECT ''no''')]
        )
    ]
);

-- Loop forever
SELECT df.create_workflow(
    name => 'eternal-loop',
    steps => ARRAY[
        df.loop(
            df.sql('SELECT do_work()'),
            df.sleep(60)
        )
    ]
);

-- While loop (continues while condition is true)
SELECT df.create_workflow(
    name => 'while-loop',
    steps => ARRAY[
        df.loop(
            df.sql('SELECT process_item()'),
            condition => 'SELECT count(*) > 0 FROM queue'
        )
    ]
);

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
df.http(url, 'GET', result_name => 'resp')                   -- with named result

-- Durable workflow variables (set BEFORE df.create_workflow)
SELECT df.setvar('api_url', 'https://api.example.com');      -- set variable
SELECT df.getvar('api_url');                                  -- get variable
SELECT df.unsetvar('api_url');                                -- remove variable
SELECT df.clearvars();                                        -- clear all

-- Use variables in workflows: {varname}
SELECT df.create_workflow(
    name => 'with-var',
    steps => ARRAY[df.http('{api_url}/data', 'GET')]
);
-- System vars: {sys_instance_id}, {sys_label}

-- Signals (wait for external events)
df.wait_for_signal('approval')                    -- wait forever
df.wait_for_signal('approval', 3600)              -- wait with 1h timeout
SELECT df.signal('inst_id', 'approval', '{}');    -- send signal

-- Visualize
SELECT df.explain('instance_id');                 -- live instance
SELECT df.explain(ARRAY[                          -- dry-run preview
    df.sql('SELECT 1'),
    df.sql('SELECT 2')
]);

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

After running this script, you can test durable workflows against the `playground` schema.
