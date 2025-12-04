# pg_durable MVP

**Minimal Viable Proof-of-Concept**

---

## Goal

Prove the core architecture works end-to-end:
1. SQL DSL functions build a workflow graph
2. Graph is stored in PostgreSQL tables
3. duroxide runtime loads and executes the graph
4. Execution is durable (survives restarts)

---

## MVP Scope

### Functions

| Function | Description |
|----------|-------------|
| `durable.sql(query, ...args)` | Execute SQL, return result as JSON |
| `durable.then(a, b)` | Sequential: run a, then b |
| `durable.as(name, fut)` | Name a future's result for `$name` reference |
| `durable.start(fut)` | Start a workflow, return instance ID |

### Operators

| Operator | Expands To | Description |
|----------|------------|-------------|
| `a ~> b` | `durable.then(a, b)` | Sequential composition |
| `a => 'name'` | `durable.as('name', a)` | Name result for `$name` reference |

### Variable References

Results can be referenced in subsequent steps:
- `$name` — The full result JSON
- `$name.rows` — The rows array
- `$name.rows[0].column` — Specific value

---

## What Users Can Build with MVP

### Example 1: Sequential SQL Workflow

```sql
SELECT durable.start(
    durable.sql('SELECT count(*) as total FROM users') => 'users'
    ~> durable.sql('SELECT count(*) as total FROM orders') => 'orders'  
    ~> durable.sql('INSERT INTO daily_stats (date, users, orders) VALUES (now(), $1, $2)',
        $users.rows[0].total, $orders.rows[0].total)
);
```

**What this does:**
1. Count users
2. Count orders
3. Insert both counts into a stats table

**Why it's useful:**
- Each step is checkpointed — if the runtime crashes after step 2, it resumes at step 3
- The workflow survives database restarts (state is in tables)
- No external job scheduler needed

### Example 2: ETL Pipeline

```sql
SELECT durable.start(
    durable.sql('SELECT id, raw_data FROM staging.events WHERE processed = false LIMIT 100') => 'batch'
    ~> durable.sql('INSERT INTO warehouse.events SELECT id, parse_json(raw_data) FROM staging.events WHERE id = ANY($1)',
        $batch.rows[*].id) => 'loaded'
    ~> durable.sql('UPDATE staging.events SET processed = true WHERE id = ANY($1)',
        $batch.rows[*].id)
);
```

**What this does:**
1. Fetch unprocessed events
2. Transform and load into warehouse
3. Mark as processed

### Example 3: Data Aggregation

```sql
SELECT durable.start(
    durable.sql('SELECT category, sum(amount) as total FROM orders GROUP BY category') => 'sales'
    ~> durable.sql('SELECT category, count(*) as total FROM returns GROUP BY category') => 'returns'
    ~> durable.sql('INSERT INTO reports.summary SELECT $1::jsonb, $2::jsonb, now()',
        $sales, $returns)
);
```

### Example 4: Audit Trail

```sql
SELECT durable.start(
    durable.sql('INSERT INTO audit_log (action, timestamp) VALUES (''start'', now())')
    ~> durable.sql('DELETE FROM temp_data WHERE created_at < now() - interval ''7 days''') => 'deleted'
    ~> durable.sql('INSERT INTO audit_log (action, timestamp, details) VALUES (''cleanup'', now(), $1)',
        '{"rows_deleted": ' || $deleted.row_count || '}')
);
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        PostgreSQL                                │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                   pg_durable Extension (pgrx)               │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │                   SQL DSL Layer                       │  │ │
│  │  │                                                        │  │ │
│  │  │  durable.sql()   → Creates SQL node in duro_nodes    │  │ │
│  │  │  durable.then()  → Creates THEN node linking nodes   │  │ │
│  │  │  durable.as()    → Wraps node with result_name       │  │ │
│  │  │  durable.start() → Creates instance, spawns runtime  │  │ │
│  │  │                                                        │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │              duroxide Runtime (in-process)            │  │ │
│  │  │                                                        │  │ │
│  │  │  • Runs as background worker in PostgreSQL           │  │ │
│  │  │  • Polls duro_instances for new work                 │  │ │
│  │  │  • Loads workflow graph from duro_nodes              │  │ │
│  │  │  • Executes as duroxide orchestration                │  │ │
│  │  │  • Each step = duroxide activity (checkpointed)      │  │ │
│  │  │  • Survives crash via replay                         │  │ │
│  │  │                                                        │  │ │
│  │  │  Activities:                                          │  │ │
│  │  │    execute_sql  — Run SQL, return JSON result        │  │ │
│  │  │                                                        │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    durable Schema                           │ │
│  │                                                              │ │
│  │  duro_nodes (id, instance_id, node_type, config, status,   │ │
│  │              result, result_name, left_node, right_node)   │ │
│  │                                                              │ │
│  │  duro_instances (id, root_node, status)                    │ │
│  │                                                              │ │
│  │  duroxide internal tables (managed by duroxide-pg)         │ │
│  │                                                              │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** The duroxide runtime runs inside the PostgreSQL extension as a background worker, not as a separate process. This simplifies deployment and ensures the runtime has direct access to PostgreSQL internals.

---

## Implementation Steps

### Step 1: pgrx Extension with duroxide Hello World

**Goal:** Create a pgrx extension that runs duroxide orchestrations as a background worker.

**Tasks:**
1. Initialize pgrx project:
   ```bash
   cargo pgrx init
   cargo pgrx new pg_durable
   ```
2. Add dependencies to `Cargo.toml`:
   ```toml
   [dependencies]
   pgrx = "0.12"
   duroxide = "0.1"
   duroxide-pg = "0.1"
   tokio = { version = "1", features = ["full"] }
   serde = { version = "1.0", features = ["derive"] }
   serde_json = "1.0"
   uuid = { version = "1.0", features = ["v4", "serde"] }
   ```
3. Create `durable` schema on extension load
4. Configure duroxide-pg to use `durable` schema for its internal tables
5. Implement background worker that runs duroxide runtime:
   ```rust
   #[pg_guard]
   pub extern "C" fn _PG_init() {
       BackgroundWorkerBuilder::new("pg_durable_worker")
           .set_function("bg_worker_main")
           .set_library("pg_durable")
           .enable_spi_access()
           .load();
   }
   
   #[pg_guard]
   #[no_mangle]
   pub extern "C" fn bg_worker_main(_arg: pg_sys::Datum) {
       // Initialize duroxide runtime
       // Poll for work and execute orchestrations
   }
   ```
6. Implement trivial hello world orchestration:
   ```rust
   async fn hello_world(ctx: OrchestrationContext, name: String) -> Result<String, String> {
       let greeting = ctx.schedule_activity("SayHello", name.clone())
           .into_activity().await?;
       Ok(greeting)
   }
   ```
7. Implement `SayHello` activity using SPI to log a message
8. Add SQL function to trigger the orchestration:
   ```rust
   #[pg_extern]
   fn hello(name: &str) -> String {
       // Start hello_world orchestration
       // Return orchestration ID
   }
   ```

**Success Criteria:**
- [ ] Extension loads without error
- [ ] Background worker starts
- [ ] `SELECT durable.hello('World')` starts orchestration
- [ ] Orchestration runs to completion
- [ ] duroxide tables exist in `durable` schema
- [ ] Kill PostgreSQL → restart → orchestration resumes via replay

### Step 2: Generic SQL Activity

**Goal:** Create an activity that can execute any SQL query using SPI.

**Tasks:**
1. Implement `execute_sql` activity using pgrx SPI:
   ```rust
   fn execute_sql(query: String, params: Vec<Value>) -> Result<Value, String> {
       Spi::connect(|client| {
           let result = client.select(&query, None, None)?;
           // Convert to JSON
           Ok(json!({
               "rows": rows_to_json(result),
               "row_count": result.len()
           }))
       })
   }
   ```
2. Register with duroxide activity registry
3. Test with simple queries via SPI
4. Test with parameterized queries
5. Verify result JSON structure: `{rows: [...], row_count: N}`

**Success Criteria:**
- [ ] Can execute `SELECT * FROM pg_tables LIMIT 5`
- [ ] Can execute `INSERT ... RETURNING *`
- [ ] Parameters are properly substituted
- [ ] Errors are properly propagated

### Step 3: Workflow Tables

**Goal:** Create the tables that store workflow definitions and state.

**Tasks:**
1. Create `durofut` composite type:
   ```sql
   CREATE TYPE durable.durofut AS (
       node_id UUID,
       node_type TEXT
   );
   ```
2. Create `duro_nodes` table (simplified for MVP):
   ```sql
   CREATE TABLE durable.duro_nodes (
       id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       instance_id UUID,
       node_type TEXT NOT NULL,  -- 'SQL', 'THEN'
       config JSONB,
       status TEXT DEFAULT 'pending',
       result JSONB,
       result_name TEXT,
       left_node UUID,
       right_node UUID
   );
   ```
3. Create `duro_instances` table:
   ```sql
   CREATE TABLE durable.duro_instances (
       id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       root_node UUID NOT NULL,
       status TEXT DEFAULT 'pending'
   );
   ```

**Success Criteria:**
- [ ] Tables are created on extension load
- [ ] Can manually insert into tables
- [ ] Foreign key relationships work correctly

### Step 4: DSL Functions

**Goal:** Implement the SQL functions that build the workflow graph.

**Tasks:**
1. `durable.sql(query, ...args)`:
   ```rust
   #[pg_extern]
   fn sql(query: &str) -> Durofut {
       // Insert node into duro_nodes
       // Return durofut with node_id
   }
   ```
2. `durable.then(a, b)`:
   ```rust
   #[pg_extern]
   fn then(a: Durofut, b: Durofut) -> Durofut {
       // Insert THEN node linking a.node_id and b.node_id
   }
   ```
3. `durable.as(name, fut)`:
   ```rust
   #[pg_extern]
   fn as_named(name: &str, fut: Durofut) -> Durofut {
       // Update fut's node with result_name = name
   }
   ```
4. Implement `~>` operator (calls `then()`)
5. Implement `=>` operator (calls `as_named()`)

**Success Criteria:**
- [ ] `SELECT durable.sql('SELECT 1')` returns durofut
- [ ] `SELECT durable.sql('A') ~> durable.sql('B')` creates linked nodes
- [ ] `SELECT durable.sql('A') => 'result'` sets result_name

### Step 5: Control Plane

**Goal:** Implement `durable.start()` and wire it to the background worker.

**Tasks:**
1. `durable.start(fut)`:
   ```rust
   #[pg_extern]
   fn start(fut: Durofut) -> Uuid {
       // Create instance in duro_instances
       // Set instance_id on all nodes in the graph
       // Notify background worker (via pg_notify or shared memory)
       // Return instance ID
   }
   ```
2. Background worker polls for new instances:
   ```rust
   // In bg_worker_main
   loop {
       Spi::connect(|client| {
           let instances = client.select(
               "SELECT id, root_node FROM durable.duro_instances WHERE status = 'pending'",
               None, None
           )?;
           for instance in instances {
               spawn_orchestration(instance);
           }
       });
       std::thread::sleep(poll_interval);
   }
   ```
3. Orchestration loads graph and executes via duroxide:
   ```rust
   async fn execute_graph(ctx: OrchestrationContext, root_node: Uuid) -> Result<Value, String> {
       let node = load_node(root_node)?;  // Uses SPI
       match node.node_type.as_str() {
           "SQL" => {
               ctx.schedule_activity("execute_sql", node.config).into_activity().await
           }
           "THEN" => {
               execute_graph(ctx.clone(), node.left_node).await?;
               execute_graph(ctx, node.right_node).await
           }
           _ => Err("Unknown node type".to_string())
       }
   }
   ```

**Success Criteria:**
- [ ] `SELECT durable.start(...)` returns UUID
- [ ] Background worker picks up new instance within 1 second
- [ ] Instance status changes to 'running' then 'completed'

### Step 6: Variable Substitution

**Goal:** Enable referencing results from previous steps.

**Tasks:**
1. Implement context that tracks named results
2. Before executing a node, substitute `$name` references in config
3. Support `$name.rows[0].column` syntax via JSON path

**Implementation:**
```rust
fn substitute_vars(config: &Value, context: &HashMap<String, Value>) -> Value {
    // Walk JSON, replace $name.path with actual values
}
```

**Success Criteria:**
- [ ] `$users` resolves to full result JSON
- [ ] `$users.rows[0].total` resolves to specific value
- [ ] Substitution works in SQL query parameters

### Step 7: End-to-End Test

**Goal:** Prove durability works.

**Test Scenario:**
```sql
SELECT durable.start(
    durable.sql('SELECT 1 as step1') => 'a'
    ~> durable.sql('SELECT 2 as step2') => 'b'
    ~> durable.sql('INSERT INTO test_results VALUES ($1, $2)', $a.rows[0].step1, $b.rows[0].step2)
);
```

**Test Steps:**
1. Start workflow
2. Wait for step 1 to complete
3. Kill runtime process
4. Verify step 1 result is in duroxide state
5. Restart runtime
6. Verify workflow resumes from step 2
7. Verify final INSERT has correct values

**Success Criteria:**
- [ ] Workflow completes correctly when uninterrupted
- [ ] Workflow completes correctly after crash/restart
- [ ] No duplicate SQL executions after restart
- [ ] Final result is correct

---

## Non-Goals for MVP

The following are explicitly **out of scope** for MVP:

- `durable.func()` — user-defined function dispatch
- `durable.join()`, `durable.race()` — parallel execution
- `durable.if()`, `durable.loop()`, `durable.for_each()` — control flow
- `durable.sleep()` — durable timers
- `durable.wait_*()` — wait primitives
- `durable.http_*()` — HTTP calls
- Error handling, retry, saga patterns
- `durable.status()`, `durable.cancel()` — control plane queries
- `&` and `|` operators

These will be added in subsequent phases after MVP is validated.

---

## Timeline

| Step | Description | Effort |
|------|-------------|--------|
| 1 | duroxide-pg hello world | 0.5 day |
| 2 | Generic SQL activity | 0.5 day |
| 3 | Extension skeleton | 0.5 day |
| 4 | DSL functions + operators | 1 day |
| 5 | Control plane + runtime integration | 1 day |
| 6 | Variable substitution | 0.5 day |
| 7 | End-to-end testing | 0.5 day |

**Total: ~4.5 days**

---

## Success Metrics

MVP is complete when:

1. ✅ User can write a 3-step SQL workflow using `~>` and `=>`
2. ✅ Workflow executes correctly
3. ✅ Killing runtime mid-workflow → restart → workflow completes
4. ✅ No duplicate step executions after restart
5. ✅ Variable substitution works (`$name.rows[0].column`)
6. ✅ Instance status reflects actual state
