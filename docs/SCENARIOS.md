# pg_durable Scenarios Guide

**Real-World Patterns for Durable SQL Functions**

This guide presents practical scenarios showing when and how to use pg_durable. Each scenario includes a use case, copy-paste ready code, and verification steps.

> 📖 **New to pg_durable?** See the [User Guide](../USER_GUIDE.md) for complete DSL reference and concepts.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- **Part 1: Database & ETL Patterns**
  - [Scenario 1: Getting Started](#scenario-1-getting-started)
  - [Scenario 2: ETL Pipeline](#scenario-2-etl-pipeline)
  - [Scenario 3: Order Processing with Variables](#scenario-3-order-processing-with-variables)
  - [Scenario 4: Parallel Aggregation](#scenario-4-parallel-aggregation)
  - [Scenario 5: Scheduled Data Sync](#scenario-5-scheduled-data-sync)
- **Part 2: Standard Operational Scenarios** → See [examples/operational_scenarios/](../examples/operational_scenarios/) folder
- **Part 3: Azure Integration Examples** → See [examples/](../examples/) folder
- [Next Steps](#next-steps)

---

## Prerequisites

```sql
-- Enable the extension
CREATE EXTENSION IF NOT EXISTS pg_durable;

-- Verify it's working
SELECT df.start('SELECT 1');
```

> 💡 Some scenarios use a `playground` schema with sample data. See the [User Guide Appendix](../USER_GUIDE.md#appendix-test-data-setup) for setup instructions.

---

# Part 1: Database & ETL Patterns

---

## Scenario 1: Getting Started

### Use This Pattern When...

> *"I want to run SQL that survives crashes and can be monitored. I need to track execution status and retrieve results later."*

**Business examples:**
- Long-running reports that shouldn't restart on connection drop
- Critical data updates that need audit trails
- Any SQL you want to monitor and retry automatically

### Code Sample

```sql
-- Start a durable function that executes a simple query
SELECT df.start('SELECT ''Hello, durable world!'' as message');
-- Returns: a1b2c3d4 (8-character instance ID)
```

### How It Works

1. `df.start()` registers your SQL as a durable function
2. A background worker picks it up and executes it
3. The function survives PostgreSQL restarts, connection drops, and crashes
4. Results are persisted and queryable at any time

### Verify It Worked

```sql
-- Check status of all recent functions
SELECT instance_id, label, status, started_at, completed_at 
FROM df.list_instances() 
ORDER BY started_at DESC 
LIMIT 5;

-- Get result of a specific instance
SELECT df.result('a1b2c3d4');  -- Replace with your instance ID

-- Check status
SELECT df.status('a1b2c3d4');
```

### Related Patterns

- Add **multiple steps** → [Scenario 2: ETL Pipeline](#scenario-2-etl-pipeline)
- Pass data between steps → [Scenario 3: Order Processing with Variables](#scenario-3-order-processing-with-variables)

---

## Scenario 2: ETL Pipeline

### Use This Pattern When...

> *"I need multi-step data transformations where each step must complete before the next begins. Failures should stop the pipeline."*

**Business examples:**
- Data warehouse loading: staging → transform → load
- Database migrations with cleanup → modification → validation
- Report generation: gather → compute → publish

### Code Sample

```sql
-- Create tables for this example
CREATE TABLE IF NOT EXISTS staging (
    id SERIAL PRIMARY KEY,
    data TEXT,
    source_id INT,
    processed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS target (
    id SERIAL PRIMARY KEY,
    data TEXT,
    source_id INT,
    loaded_at TIMESTAMPTZ DEFAULT now()
);

-- Insert sample data
INSERT INTO staging (data, source_id) VALUES 
    ('record-a', 1001),
    ('record-b', 1002),
    ('record-c', 1003);

-- ETL Pipeline: cleanup → mark → load (using ~> operator)
SELECT df.start(
    'DELETE FROM target WHERE loaded_at < now() - interval ''7 days'''        -- Step 1: Cleanup old
    ~> 'UPDATE staging SET processed_at = now() WHERE processed_at IS NULL'   -- Step 2: Mark staging
    ~> 'INSERT INTO target (data, source_id)
        SELECT data, source_id FROM staging WHERE processed_at IS NOT NULL',  -- Step 3: Load
    'etl-pipeline'  -- Label for easy identification
);
```

### How It Works

1. The `~>` operator chains steps **sequentially**
2. Each step waits for the previous one to complete
3. If any step fails, execution stops (no partial state)
4. All steps are logged for audit and debugging

### Verify It Worked

```sql
-- Check pipeline status
SELECT status FROM df.instances WHERE label = 'etl-pipeline';

-- Verify data loaded
SELECT COUNT(*) as loaded_records FROM target;

-- View execution timeline
SELECT * FROM df.nodes WHERE instance_id = (
    SELECT instance_id FROM df.instances WHERE label = 'etl-pipeline'
);
```

### Related Patterns

- Add **parallel steps** → [Scenario 4: Parallel Aggregation](#scenario-4-parallel-aggregation)

---

## Scenario 3: Order Processing with Variables

### Use This Pattern When...

> *"I need to pass data (IDs, computed values, results) from one step to the next. Each step builds on previous results."*

**Business examples:**
- Process orders: get order → validate → mark complete
- User workflows: fetch user → check permissions → update record
- Inventory: find item → reserve stock → create shipment

### Code Sample

```sql
-- Create orders table for this example
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    status TEXT DEFAULT 'pending',
    processed_at TIMESTAMPTZ
);

INSERT INTO orders (status) VALUES ('pending'), ('pending'), ('completed');

-- Order Processing: capture order_id, pass it through pipeline
SELECT df.start(
    'SELECT id FROM orders WHERE status = ''pending'' LIMIT 1' 
        |=> 'order_id'                                            -- Capture result as $order_id
    
    ~> 'UPDATE orders SET status = ''processing'' 
        WHERE id = $order_id'                                     -- Use $order_id
    
    ~> df.sleep(2)                                                -- Simulate work (2 seconds)
    
    ~> 'UPDATE orders SET status = ''completed'', processed_at = now() 
        WHERE id = $order_id',                                    -- Use $order_id again
    
    'process-order'
);
```

### How It Works

1. `|=>` captures the result of a SQL step into a named variable
2. `$variable_name` substitutes that value in subsequent steps
3. Variables persist across the entire function execution
4. Multiple variables can be captured and used

### Verify It Worked

```sql
-- Check the function completed
SELECT status FROM df.instances WHERE label = 'process-order';

-- See the processed order
SELECT * FROM orders WHERE status = 'completed' ORDER BY processed_at DESC LIMIT 1;

-- View captured variables in execution log
SELECT node_label, status, result 
FROM df.nodes 
WHERE instance_id = (SELECT instance_id FROM df.instances WHERE label = 'process-order');
```

### Variable Tips

```sql
-- Capture multiple values
'SELECT user_id, email FROM users WHERE id = 1' |=> 'user_data'

-- Use in SQL (as JSON)
'INSERT INTO logs (data) VALUES ($user_data::jsonb)'

-- Chain multiple captures
'SELECT id FROM a' |=> 'a_id' ~> 'SELECT name FROM b WHERE a_id = $a_id' |=> 'name'
```

---

## Scenario 4: Parallel Aggregation

### Use This Pattern When...

> *"I want to run multiple independent queries at once and wait for all to finish. Parallelism speeds up data gathering."*

**Business examples:**
- Dashboard data: count users + count orders + sum revenue simultaneously
- Data validation: check table A + check table B + check table C
- Multi-source ETL: load from source 1 + source 2 + source 3 in parallel

### Code Sample

```sql
-- Create sample tables
CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, name TEXT);
CREATE TABLE IF NOT EXISTS orders (id SERIAL PRIMARY KEY, amount NUMERIC);
CREATE TABLE IF NOT EXISTS products (id SERIAL PRIMARY KEY, name TEXT);

INSERT INTO users (name) VALUES ('Alice'), ('Bob'), ('Carol');
INSERT INTO orders (amount) VALUES (100), (250), (175);
INSERT INTO products (name) VALUES ('Widget'), ('Gadget');

-- Parallel Aggregation: count all tables simultaneously
SELECT df.start(
    (
        'SELECT COUNT(*) as user_count FROM users'
        &  -- Parallel operator
        'SELECT COUNT(*) as order_count FROM orders'
        &
        'SELECT SUM(amount) as total_revenue FROM orders'
        &
        'SELECT COUNT(*) as product_count FROM products'
    )
    ~> 'SELECT ''Dashboard data collected'' as status',  -- Runs after ALL parallel queries complete
    'dashboard-parallel'
);
```

### How It Works

1. The `&` operator runs steps **in parallel**
2. Execution continues only after **all** parallel branches complete
3. This is a "fan-out / fan-in" pattern
4. Use `df.join()` function for more than 2 branches (cleaner syntax)

### Alternative Syntax with df.join()

```sql
SELECT df.start(
    df.join(
        'SELECT COUNT(*) FROM users',
        'SELECT COUNT(*) FROM orders', 
        'SELECT COUNT(*) FROM products'
    )
    ~> 'INSERT INTO logs (msg) VALUES (''All counts complete'')',
    'dashboard-join'
);
```

### Verify It Worked

```sql
-- Check status
SELECT status FROM df.instances WHERE label = 'dashboard-parallel';

-- View parallel execution (notice same started_at for parallel branches)
SELECT node_label, status, started_at, completed_at 
FROM df.nodes 
WHERE instance_id = (SELECT instance_id FROM df.instances WHERE label = 'dashboard-parallel')
ORDER BY started_at;
```

### Related Patterns

- Need **first to complete wins** instead of all? Use `|` (race) operator

---

## Scenario 5: Scheduled Data Sync

### Use This Pattern When...

> *"I need to poll an external API or run a job on a schedule (hourly, daily, every 30 minutes). The job should run forever and survive restarts."*

**Business examples:**
- Sync data from external API every hour
- Archive old records daily at midnight
- Health checks every 5 minutes
- Report generation every Monday at 9am

### Code Sample

```sql
-- Create table to store synced data
CREATE TABLE IF NOT EXISTS external_data_sync (
    id SERIAL PRIMARY KEY,
    data JSONB,
    synced_at TIMESTAMPTZ DEFAULT now()
);

-- Scheduled sync: fetch data every 30 minutes (runs forever)
SELECT df.start(
    @> (  -- @> creates an eternal loop
        -- Fetch from external API
        (df.http(
            'https://httpbingo.org/json',
            'GET'
        ) |=> 'response')
        
        -- Store the response
        ~> 'INSERT INTO external_data_sync (data) 
            VALUES ($response::jsonb)'
        
        -- Wait for next scheduled run
        ~> df.wait_for_schedule('*/30 * * * *')  -- Cron: every 30 minutes
    ),
    'scheduled-data-sync'
);
```

### How It Works

1. `@>` (or `df.loop()`) creates an **eternal loop**
2. `df.wait_for_schedule()` pauses until the cron expression matches
3. The loop runs forever, surviving restarts
4. State is durably persisted between iterations

### Cron Schedule Examples

| Expression | Meaning |
|------------|---------|
| `*/5 * * * *` | Every 5 minutes |
| `0 * * * *` | Every hour (on the hour) |
| `0 0 * * *` | Daily at midnight |
| `0 9 * * 1` | Every Monday at 9am |
| `0 */6 * * *` | Every 6 hours |

### Manage the Scheduled Job

```sql
-- Check if running
SELECT status FROM df.instances WHERE label = 'scheduled-data-sync';

-- View iteration count
SELECT COUNT(*) FROM external_data_sync;

-- Cancel the scheduled job
SELECT df.cancel(
    (SELECT instance_id FROM df.instances WHERE label = 'scheduled-data-sync'),
    'Stopping scheduled sync'
);
```

### Related Patterns

- Add **conditional exit** → Use `df.break()` to exit loop on condition
- Add **error handling** → Wrap with `df.if()` to handle API failures

---

# Part 2: Standard Operational Scenarios

> 🔧 **Looking for database-maintenance workflows?** See the dedicated **[examples/operational_scenarios/](../examples/operational_scenarios/)** folder for vacuum, bloat, and wraparound remediation scripts.

pg_durable is well suited to durable database-operations workflows that must detect a
condition, surface findings for review, wait for human approval, then remediate and verify
the result — surviving restarts along the way. These standard operational scenarios close
the loop on the most common PostgreSQL maintenance pain points.

| Scenario | Use Case | Script |
|----------|----------|--------|
| **Common Prerequisite** | Identify autovacuum blockers before any manual action | [`00_common_prerequisite.sql`](../examples/operational_scenarios/00_common_prerequisite.sql) |
| **Autovacuum Is Blocked** | Detect and resolve autovacuum blockers, then vacuum | [`01_autovacuum_blocked.sql`](../examples/operational_scenarios/01_autovacuum_blocked.sql) |
| **Database Bloat > 80%** | Address excessive table bloat by clearing blockers and vacuuming | [`02_database_bloat.sql`](../examples/operational_scenarios/02_database_bloat.sql) |
| **Wraparound Risk** | Identify and mitigate transaction ID wraparound risk | [`03_wraparound_risk.sql`](../examples/operational_scenarios/03_wraparound_risk.sql) |
| **Tables Not Vacuumed for X Days** | Find stale tables and keep vacuum maintenance current | [`04_tables_not_vacuumed.sql`](../examples/operational_scenarios/04_tables_not_vacuumed.sql) |

### Scenario 0: Common Prerequisite

> *"Before I run any manual vacuum, what's actually holding back autovacuum?"*

Identifies the oldest `xmin` holder — long-running transactions, logical/physical replication
slots, or prepared transactions — that can block vacuum, freeze, and catalog cleanup. Always
run this first so remediation targets the real blocker. → [`00_common_prerequisite.sql`](../examples/operational_scenarios/00_common_prerequisite.sql)

### Scenario 1: Autovacuum Is Blocked

> *"Autovacuum can't keep up — dead tuples are piling up and the table keeps growing."*

Detects autovacuum blockers, surfaces them for review, waits for approval, then clears the
blocker and runs `VACUUM (ANALYZE)` — all as a single durable, crash-safe pipeline. → [`01_autovacuum_blocked.sql`](../examples/operational_scenarios/01_autovacuum_blocked.sql)

### Scenario 2: Database Bloat > 80%

> *"A table is mostly dead tuples — disk is wasted and scans are slow."*

Identifies bloated tables, branches on whether blockers exist (`?>` / `!>`), remediates with
approval when needed, then vacuums to reclaim space and logs how much was recovered. → [`02_database_bloat.sql`](../examples/operational_scenarios/02_database_bloat.sql)

### Scenario 3: Wraparound Risk

> *"The database is approaching the ~2 billion XID limit and risks an emergency shutdown."*

Detects tables at transaction-ID wraparound risk, escalates for approval, and runs a
durable freeze/vacuum to pull the database back from the brink. → [`03_wraparound_risk.sql`](../examples/operational_scenarios/03_wraparound_risk.sql)

### Scenario 4: Tables Not Vacuumed for X Days

> *"Some tables haven't been vacuumed — manually or by autovacuum — for over a week."*

Finds stale tables past a configurable threshold (default: 7 days) and keeps vacuum
maintenance current, optionally on an off-hours schedule via `df.wait_for_schedule()`. → [`04_tables_not_vacuumed.sql`](../examples/operational_scenarios/04_tables_not_vacuumed.sql)

> 💡 Always start with the Common Prerequisite (Scenario 0) to identify autovacuum blockers before running any remediation. See the [operational scenarios README](../examples/operational_scenarios/README.md) and [design notes](../examples/operational_scenarios/SCENARIOS_DESIGN.md) for details.

---

# Part 3: Azure Integration Examples

> ☁️ **Looking for cloud-connected workflows?** These runnable examples live in the **[examples/](../examples/)** folder and show pg_durable calling Azure services over HTTPS with `df.http()`.

These examples round out the full set of pg_durable patterns, demonstrating how durable
SQL workflows integrate with Azure Functions and other Azure HTTP endpoints — including
human-in-the-loop approval and always-on processing loops.

| Example | Use Case | Folder |
|---------|----------|--------|
| **Azure Functions** | Call an HTTP-triggered Azure Function from `df.http()` for token-aware text chunking, then store the chunks in PostgreSQL | [`azure-functions/`](../examples/azure-functions/) |
| **Azure HTTP Domains** | Validate `df.http()` against every Azure domain suffix in the `http-allow-azure-domains` allowlist | [`azure-http-domains/`](../examples/azure-http-domains/) |
| **Invoice Approval** | Always-on pipeline that classifies invoices via an Azure Function, auto-approves small ones, and pauses for human approval on high-value invoices | [`invoice-approval/`](../examples/invoice-approval/) |

### Azure Functions

> *"Chunk documents for ingestion by calling out to an Azure Function, then persist the results."*

Reads pending documents from PostgreSQL, calls an HTTP-triggered Azure Function over HTTPS
for token-aware chunking, then inserts the returned chunks and marks documents processed. → [`azure-functions/`](../examples/azure-functions/)

### Azure HTTP Domains

> *"Confirm `df.http()` works across every allowed Azure domain suffix."*

Systematically exercises `df.http()` against each Azure domain suffix in the
`http-allow-azure-domains` allowlist, sending real requests through pg_durable's background
worker and verifying successful responses. → [`azure-http-domains/`](../examples/azure-http-domains/)

### Invoice Approval

> *"Process invoices continuously, auto-approving small ones and escalating large ones for sign-off."*

An always-on loop (`@>`) that classifies each invoice via an Azure Function, branches with
`df.if`, auto-approves invoices under a threshold, and pauses high-value invoices with
`df.wait_for_signal` until a human approves. → [`invoice-approval/`](../examples/invoice-approval/)

---

# Next Steps

## Learn More

- **[User Guide](../USER_GUIDE.md)** — Complete DSL reference, all operators and functions
- **[API Reference](api-reference.md)** — Detailed function signatures
- **[Architecture](ARCHITECTURE.md)** — How pg_durable works under the hood

## Advanced Topics

- **Error Handling** — Retry policies and failure callbacks
- **Compensation** — Rollback patterns for distributed transactions
- **Performance** — Tuning worker processes and batch sizes
- **Security** — Role-based access control for durable functions

## Get Help

- **GitHub Issues** — Report bugs or request features
- **Discussions** — Ask questions and share patterns

---

*This guide covers common patterns. For production use, consider adding error handling, logging, and security measures appropriate to your environment.*
