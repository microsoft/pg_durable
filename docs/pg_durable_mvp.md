# pg_durable MVP User Guide

---

## Goal

Prove the core architecture works end-to-end:
1. SQL DSL operators build a function graph
2. Graph is stored in PostgreSQL tables
3. Duroxide runtime loads and executes the graph
4. Execution is durable (survives restarts)

---

## MVP Scope

### DSL Functions

| Function | Description |
|----------|-------------|
| `durable.sql(query)` | Execute SQL, return result as JSON |
| `durable.sleep(seconds)` | Pause execution for N seconds |
| `durable.if(cond, then, else)` | Conditional branching |
| `durable.join(a, b)` | Parallel execution, wait for all |
| `durable.loop(body)` | Infinite loop (use with break conditions) |
| `durable.start(func, label)` | Start a durable function, return instance ID |

### Operators

| Operator | Expands To | Description |
|----------|------------|-------------|
| `a ~> b` | `durable.then(a, b)` | Sequential composition |
| `a \|=> 'name'` | `durable.as('name', a)` | Name result for `$name` reference |

### Auto-Wrap SQL

Plain SQL strings are automatically wrapped in `durable.sql()` calls:

```sql
-- These are equivalent:
'SELECT 1' ~> 'SELECT 2'
durable.sql('SELECT 1') ~> durable.sql('SELECT 2')
```

### Variable References

Results can be referenced in subsequent steps:
- `$name` — The full result JSON
- `$name.rows` — The rows array
- `$name.rows[0].column` — Specific value

---

## What Users Can Build with MVP

### Example 1: Sequential SQL Function

```sql
SELECT durable.start(
    'SELECT count(*) as total FROM users' |=> 'users'         -- step 1, save as $users
    ~> 'SELECT count(*) as total FROM orders' |=> 'orders'    -- step 2, save as $orders
    ~> 'INSERT INTO daily_stats (date, users, orders) 
        VALUES (now(), $users, $orders)'                      -- step 3, use both
);
```

**What this does:**
1. Count users
2. Count orders
3. Insert both counts into a stats table

**Why it's useful:**
- Each step is checkpointed — if the runtime crashes after step 2, it resumes at step 3
- The function survives database restarts (state is in tables)
- No external job scheduler needed

### Example 2: ETL Pipeline

```sql
SELECT durable.start(
    'SELECT id, raw_data FROM staging.events 
     WHERE processed = false LIMIT 100' |=> 'batch'           -- extract
    ~> 'INSERT INTO warehouse.events 
        SELECT id, parse_json(raw_data) FROM staging.events 
        WHERE id = ANY($batch)' |=> 'loaded'                  -- transform & load
    ~> 'UPDATE staging.events SET processed = true 
        WHERE id = ANY($batch)'                               -- mark done
);
```

**What this does:**
1. Fetch unprocessed events
2. Transform and load into warehouse
3. Mark as processed

### Example 3: Conditional Processing

```sql
SELECT durable.start(
    'SELECT count(*) as cnt FROM pending_jobs' |=> 'jobs'
    ~> durable.if(
        'SELECT $jobs > 0',                                   -- condition
        'INSERT INTO log VALUES (''Processing jobs'')'        -- then branch
            ~> 'CALL process_pending_jobs()',
        'INSERT INTO log VALUES (''No jobs to process'')'     -- else branch
    )
);
```

**What this does:**
1. Check if there are pending jobs
2. If yes: log and process them
3. If no: log that there's nothing to do

### Example 4: Parallel Data Aggregation

```sql
SELECT durable.start(
    durable.join(                                             -- run in parallel
        'SELECT category, sum(amount) as total 
         FROM orders GROUP BY category' |=> 'sales',          -- branch 1
        'SELECT category, count(*) as total 
         FROM returns GROUP BY category' |=> 'returns'        -- branch 2
    )                                                         -- waits for both
    ~> 'INSERT INTO reports.summary 
        SELECT $sales::jsonb, $returns::jsonb, now()'         -- runs after join
);
```

**What this does:**
1. Run sales and returns queries in parallel
2. When both complete, insert combined results

### Example 5: Scheduled Cleanup with Sleep

```sql
SELECT durable.start(
    durable.loop(                                             -- infinite loop
        'DELETE FROM temp_data 
         WHERE created_at < now() - interval ''7 days''' |=> 'deleted'
        ~> 'INSERT INTO audit_log (action, details) 
            VALUES (''cleanup'', $deleted)'                   -- log results
        ~> durable.sleep(3600)                                -- sleep 1 hour
    ),                                                        -- then repeat
    'hourly-cleanup'                                          -- instance label
);
```

**What this does:**
1. Delete old temp data
2. Log the cleanup
3. Sleep for 1 hour
4. Repeat forever (survives restarts)

### Example 6: Multi-Step Validation Pipeline

```sql
SELECT durable.start(
    'SELECT * FROM submissions 
     WHERE status = ''pending'' LIMIT 1' |=> 'submission'     -- fetch one
    ~> durable.if(
        'SELECT $submission IS NOT NULL',                     -- check if found
        -- THEN: validate the submission
        'UPDATE submissions SET status = ''validating'' 
         WHERE id = $submission.id'
            ~> durable.join(                                  -- parallel validation
                'SELECT validate_schema($submission.data)' |=> 'schema_ok',
                'SELECT validate_rules($submission.data)' |=> 'rules_ok'
            )
            ~> durable.if(
                'SELECT $schema_ok AND $rules_ok',            -- both passed?
                'UPDATE submissions SET status = ''approved'' 
                 WHERE id = $submission.id',                  -- approve
                'UPDATE submissions SET status = ''rejected'' 
                 WHERE id = $submission.id'                   -- reject
            ),
        -- ELSE: nothing to do
        'SELECT ''no pending submissions'''
    ),
    'submission-validator'
);
```

---

## Monitoring & Visualization

### Check Function Status

```sql
SELECT * FROM durable.instance_info('abc12345');
```

### View Function Graph

```sql
-- Live instance with execution status
SELECT durable.explain('abc12345');

-- Dry-run: visualize without executing
SELECT durable.explain($$
    'SELECT 1' |=> 'a'
    ~> 'SELECT 2' |=> 'b'
    ~> durable.if('SELECT $a > 0', 'SELECT yes', 'SELECT no')
$$);
```

Example output:
```
SQL |=> 'a': SELECT 1
→ SQL |=> 'b': SELECT 2
→ IF
    ✓ then:
      SQL: SELECT yes
    ✗ else:
      SQL: SELECT no
```

### List All Instances

```sql
SELECT * FROM durable.list_instances();
```

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                         PostgreSQL                             │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                pg_durable Extension (pgrx)               │  │
│  │                                                          │  │
│  │  ┌────────────────────────────────────────────────────┐  │  │
│  │  │                  SQL DSL Layer                     │  │  │
│  │  │                                                    │  │  │
│  │  │  durable.sql()   → Creates SQL node                │  │  │
│  │  │  ~> operator     → Creates THEN node linking nodes │  │  │
│  │  │  |=> operator    → Sets result_name on node        │  │  │
│  │  │  durable.start() → Creates instance, triggers run  │  │  │
│  │  │                                                    │  │  │
│  │  └────────────────────────────────────────────────────┘  │  │
│  │                                                          │  │
│  │  ┌────────────────────────────────────────────────────┐  │  │
│  │  │           Duroxide Runtime (background worker)     │  │  │
│  │  │                                                    │  │  │
│  │  │  • Runs as background worker in PostgreSQL         │  │  │
│  │  │  • Polls durable.instances for new work            │  │  │
│  │  │  • Loads function graph from durable.nodes         │  │  │
│  │  │  • Executes as duroxide function                   │  │  │
│  │  │  • Each step = duroxide activity (checkpointed)    │  │  │
│  │  │  • Survives crash via replay                       │  │  │
│  │  │                                                    │  │  │
│  │  └────────────────────────────────────────────────────┘  │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                     durable Schema                       │  │
│  │                                                          │  │
│  │  durable.nodes (id, instance_id, node_type, query,       │  │
│  │                 status, result, result_name,             │  │
│  │                 left_node, right_node)                   │  │
│  │                                                          │  │
│  │  durable.instances (id, label, root_node, status, out)   │  │
│  │                                                          │  │
│  │  duroxide internal tables (SQLite store for replay)      │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

**Key insight:** The duroxide runtime runs inside the PostgreSQL extension as a background worker, not as a separate process. This simplifies deployment and ensures the runtime has direct access to PostgreSQL internals.

---

## Under the Covers: DSL Translation

The ergonomic SQL syntax translates to explicit function calls and database operations.

### Auto-Wrap Translation

Plain SQL strings are automatically wrapped:

| You Write | Translates To |
|-----------|---------------|
| `'SELECT 1' ~> 'SELECT 2'` | `durable.sql('SELECT 1') ~> durable.sql('SELECT 2')` |
| `'SELECT x' \|=> 'var'` | `durable.sql('SELECT x') \|=> 'var'` |
| `durable.if('SELECT true', 'a', 'b')` | `durable.if(durable.sql('SELECT true'), durable.sql('a'), durable.sql('b'))` |
| `durable.join('SELECT 1', 'SELECT 2')` | `durable.join(durable.sql('SELECT 1'), durable.sql('SELECT 2'))` |
| `durable.loop('SELECT 1')` | `durable.loop(durable.sql('SELECT 1'))` |
| `durable.start('SELECT 1')` | `durable.start(durable.sql('SELECT 1'))` |

### Detection Logic

The system detects whether a string is already a `Durofut` (function node) or plain SQL:

```rust
// A Durofut is valid JSON with node_id (8 hex chars) and node_type
fn is_durofut(s: &str) -> bool {
    if let Ok(v) = serde_json::from_str::<Value>(s) {
        if let (Some(id), Some(_)) = (v["node_id"].as_str(), v["node_type"].as_str()) {
            return id.len() == 8 && id.chars().all(|c| c.is_ascii_hexdigit());
        }
    }
    false
}
```

### Node Creation

Each DSL function creates a row in `durable.nodes`:

```sql
-- durable.sql('SELECT count(*) FROM users')
INSERT INTO durable.nodes (id, node_type, query)
VALUES ('a1b2c3d4', 'SQL', 'SELECT count(*) FROM users');
-- Returns: {"node_id":"a1b2c3d4","node_type":"SQL",...}
```

### Sequence (~>) Translation

The `~>` operator creates a `THEN` node linking two nodes:

```sql
-- 'SELECT 1' ~> 'SELECT 2'
-- Step 1: Create SQL node for 'SELECT 1' → id='aaaa1111'
-- Step 2: Create SQL node for 'SELECT 2' → id='bbbb2222'  
-- Step 3: Create THEN node linking them
INSERT INTO durable.nodes (id, node_type, left_node, right_node)
VALUES ('cccc3333', 'THEN', 'aaaa1111', 'bbbb2222');
```

### Naming (|=>) Translation

The `|=>` operator sets `result_name` on a node:

```sql
-- 'SELECT 1' |=> 'my_var'
-- Step 1: Create SQL node → id='aaaa1111'
-- Step 2: Update the node with result_name
UPDATE durable.nodes SET result_name = 'my_var' WHERE id = 'aaaa1111';
```

### Instance Creation

`durable.start()` creates an instance and triggers execution:

```sql
-- durable.start('SELECT 1' ~> 'SELECT 2', 'my-job')
-- Step 1: Build the graph (creates nodes as above)
-- Step 2: Create instance
INSERT INTO durable.instances (id, label, root_node, status)
VALUES ('inst0001', 'my-job', 'cccc3333', 'pending');
-- Step 3: Update all nodes with instance_id
UPDATE durable.nodes SET instance_id = 'inst0001' WHERE id IN (...);
-- Step 4: Background worker picks up and executes
```

### Runtime Execution

The background worker executes nodes recursively:

```rust
async fn execute_node(node_id: &str, ctx: &mut Context) -> Result<Value> {
    let node = load_node(node_id)?;
    
    match node.node_type.as_str() {
        "SQL" => {
            // Execute via duroxide activity (checkpointed)
            let result = ctx.activity("ExecuteSQL", &node.query).await?;
            update_node_result(node_id, &result)?;
            if let Some(name) = node.result_name {
                ctx.variables.insert(name, result.clone());
            }
            Ok(result)
        }
        "THEN" => {
            execute_node(&node.left_node, ctx).await?;
            execute_node(&node.right_node, ctx).await
        }
        "IF" => {
            let cond = execute_node(&node.condition_node, ctx).await?;
            if cond.as_bool() {
                execute_node(&node.left_node, ctx).await
            } else {
                execute_node(&node.right_node, ctx).await
            }
        }
        "JOIN" => {
            // Execute branches in parallel
            let (a, b) = tokio::join!(
                execute_node(&node.left_node, ctx),
                execute_node(&node.right_node, ctx)
            );
            Ok(json!({"left": a?, "right": b?}))
        }
        // ... other node types
    }
}
```

### Durability via Replay

Each activity execution is checkpointed to SQLite:

1. **First execution**: Activity runs, result stored in SQLite
2. **On crash**: PostgreSQL restarts, background worker resumes
3. **Replay**: Duroxide replays from SQLite - completed activities return cached results
4. **Continue**: Execution resumes from where it left off

This is why durable functions survive crashes without re-executing completed steps.
