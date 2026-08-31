# pg_durable Architecture: Function Graph Build & Execution

This document provides a detailed technical walkthrough of how pg_durable builds function graphs (Phase 1: DSL) and executes them durably (Phase 2: Orchestration).

---

## Table of Contents

1. [Overview](#overview)
2. [PostgreSQL Extension Architecture](#postgresql-extension-architecture)
3. [Phase 1: Function Graph Construction](#phase-1-function-graph-construction)
   - [Core Data Structures](#core-data-structures)
   - [DSL Functions](#dsl-functions)
   - [SQL Operators](#sql-operators)
   - [Node Linking](#node-linking)
   - [Variable Capture](#variable-capture)
4. [Phase 2: Orchestration Execution](#phase-2-orchestration-execution)
   - [Duroxide Integration](#duroxide-integration)
   - [Graph Loading](#graph-loading)
   - [Node Execution](#node-execution)
   - [Variable Substitution](#variable-substitution)
   - [Condition Evaluation](#condition-evaluation)
   - [Parallel Execution (JOIN/RACE)](#parallel-execution-joinrace)
   - [Loops and Continue-As-New](#loops-and-continue-as-new)
5. [Data Flow Diagram](#data-flow-diagram)
6. [Key Files Reference](#key-files-reference)

---

## Overview

pg_durable executes durable SQL functions in two distinct phases:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              USER SESSION                                    │
│                                                                              │
│  Phase 1: Graph Construction (synchronous, in user transaction)             │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  SELECT df.start(                                                      │  │
│  │      'SELECT 1' |=> 'a' ~> 'SELECT $a + 1'                            │  │
│  │  );                                                                    │  │
│  │                                                                        │  │
│  │  1. Operators (~>, |=>) call DSL functions (df.seq, df.as)            │  │
│  │  2. Each function creates a node in df.nodes                          │  │
│  │  3. df.start() links nodes, creates instance, enqueues to duroxide    │  │
│  │  4. Returns instance_id immediately (e.g., "a1b2c3d4")                │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ instance_id enqueued
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                          BACKGROUND WORKER                                   │
│                                                                              │
│  Phase 2: Graph Execution (async, durable via duroxide)                     │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  1. Duroxide dispatcher picks up orchestration                         │  │
│  │  2. LoadFunctionGraph activity loads nodes from df.nodes              │  │
│  │  3. ExecuteFunctionGraph orchestration walks the graph                │  │
│  │  4. Each SQL node → ExecuteSQL activity (checkpointed)                │  │
│  │  5. Results stored, status updated to 'completed'                     │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## PostgreSQL Extension Architecture

**Important**: pg_durable is a PostgreSQL extension built with [pgrx](https://github.com/pgcentralfoundation/pgrx). **Everything runs inside the PostgreSQL server process** — there are no external services, daemons, or network calls to external orchestrators.

### Process Model

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              POSTGRESQL SERVER                                       │
│                                                                                     │
│  ┌───────────────────────────────────────────────────────────────────────────────┐  │
│  │                         MAIN POSTGRES PROCESS                                 │  │
│  │                                                                               │  │
│  │   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │  │
│  │   │ Backend Process │  │ Backend Process │  │ Backend Process │  ...         │  │
│  │   │ (user session)  │  │ (user session)  │  │ (user session)  │              │  │
│  │   │                 │  │                 │  │                 │              │  │
│  │   │ • Runs SQL      │  │ • Runs SQL      │  │ • Runs SQL      │              │  │
│  │   │ • Calls df.*()  │  │ • Calls df.*()  │  │ • Calls df.*()  │              │  │
│  │   │ • Builds graph  │  │ • Builds graph  │  │ • Builds graph  │              │  │
│  │   │ • Uses SPI      │  │ • Uses SPI      │  │ • Uses SPI      │              │  │
│  │   └────────┬────────┘  └────────┬────────┘  └────────┬────────┘              │  │
│  │            │                    │                    │                        │  │
│  │            │         Enqueue via duroxide.start_orchestration()              │  │
│  │            │                    │                    │                        │  │
│  │            ▼                    ▼                    ▼                        │  │
│  │   ┌───────────────────────────────────────────────────────────────────────┐  │  │
│  │   │                     SHARED POSTGRESQL TABLES                          │  │  │
│  │   │                                                                       │  │  │
│  │   │   df.instances    df.nodes    df.vars    duroxide.*                  │  │  │
│  │   │   (instances)     (graph)     (config)   (orchestration state)       │  │  │
│  │   └───────────────────────────────────────────────────────────────────────┘  │  │
│  │            ▲                    ▲                    ▲                        │  │
│  │            │                    │                    │                        │  │
│  │            │          Poll & execute via sqlx                                │  │
│  │            │                    │                    │                        │  │
│  └────────────┼────────────────────┼────────────────────┼────────────────────────┘  │
│               │                    │                    │                           │
│  ┌────────────┴────────────────────┴────────────────────┴────────────────────────┐  │
│  │                      BACKGROUND WORKER PROCESS                                │  │
│  │                      (pg_durable_worker)                                      │  │
│  │                                                                               │  │
│  │   Registered via BackgroundWorkerBuilder in _PG_init()                       │  │
│  │   Started automatically when PostgreSQL starts                                │  │
│  │                                                                               │  │
│  │   ┌─────────────────────────────────────────────────────────────────────┐    │  │
│  │   │                      DUROXIDE RUNTIME                               │    │  │
│  │   │                                                                     │    │  │
│  │   │   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐ │    │  │
│  │   │   │ Orchestration│  │   Activity   │  │   PostgresProvider       │ │    │  │
│  │   │   │  Dispatcher  │  │  Dispatcher  │  │   (duroxide-pg)          │ │    │  │
│  │   │   │              │  │              │  │                          │ │    │  │
│  │   │   │ Polls for    │  │ Polls for    │  │ • Connects via sqlx     │ │    │  │
│  │   │   │ orchestration│  │ activity     │  │ • Stores state in       │ │    │  │
│  │   │   │ work items   │  │ work items   │  │   duroxide.* tables     │ │    │  │
│  │   │   └──────────────┘  └──────────────┘  └──────────────────────────┘ │    │  │
│  │   │                                                                     │    │  │
│  │   │   ┌─────────────────────────────────────────────────────────────┐  │    │  │
│  │   │   │              REGISTERED COMPONENTS                          │  │    │  │
│  │   │   │                                                             │  │    │  │
│  │   │   │  Orchestrations:          Activities:                       │  │    │  │
│  │   │   │  • execute-function-graph • load-function-graph            │  │    │  │
│  │   │   │  • execute-subtree        • execute-sql                    │  │    │  │
│  │   │   │                           • execute-http                   │  │    │  │
│  │   │   │                           • update-instance-status         │  │    │  │
│  │   │   │                           • update-node-status             │  │    │  │
│  │   │   └─────────────────────────────────────────────────────────────┘  │    │  │
│  │   └─────────────────────────────────────────────────────────────────────┘    │  │
│  └───────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Key Architectural Points

1. **No External Services**: Unlike systems like Temporal or Azure Durable Functions, pg_durable requires no external infrastructure. Everything is self-contained within PostgreSQL.

2. **Two Execution Contexts**:
   - **Backend Processes** (user sessions): Execute DSL functions synchronously via pgrx's SPI (Server Programming Interface). This is Phase 1 - graph construction.
   - **Background Worker**: A single persistent worker process (registered via `shared_preload_libraries`) that runs the duroxide runtime. This is Phase 2 - durable execution.

3. **Communication via Tables**: The two contexts communicate through PostgreSQL tables:
   - `df.nodes`, `df.instances`, `df.vars`: Application-level state (function graphs, instances, config)
   - `duroxide.*`: Orchestration runtime state (work queues, checkpoints, history)

4. **Background Worker Registration**:

```rust
// src/worker.rs - Called during extension load
pub fn register_background_worker() {
    BackgroundWorkerBuilder::new("pg_durable_worker")
        .set_function("background_worker_main")
        .set_library("pg_durable")
        .set_restart_time(Some(Duration::from_secs(1)))
        .enable_spi_access()
        .load();
}

// src/lib.rs - Extension initialization
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    worker::register_background_worker();
}
```

5. **Why This Matters**:
   - **Deployment**: Just install the extension. No separate services to manage.
   - **Durability**: State is stored in PostgreSQL tables with full ACID guarantees.
   - **Failover**: If PostgreSQL fails over, the new primary picks up where the old one left off.
   - **Backup**: Regular PostgreSQL backups include all orchestration state.
   - **Security**: Uses PostgreSQL's authentication and authorization.

---

## Phase 1: Function Graph Construction

### Core Data Structures

#### Durofut (Durable Future Reference)

A `Durofut` represents an abstract function graph, sub-graph or leaf node. It's serialized as JSON and passed between DSL functions.

```rust
// src/types.rs
pub struct Durofut {
    pub node_type: String,                  // SQL, THEN, IF, JOIN, LOOP, etc.
    pub left_node: Option<Box<Durofut>>,    // Embedded left child
    pub right_node: Option<Box<Durofut>>,   // Embedded right child
    pub query: Option<String>,              // SQL query or config JSON
    pub result_name: Option<String>,        // Named result (from |=> operator)
}
```

When serialized to JSON:
```json
{
  "node_type": "THEN",
  "left_node": {
    "node_type": "SQL",
    "query": "SELECT 1"
  },
  "right_node": {
    "node_type": "SQL",
    "query": "SELECT 2"
  }
}
```

#### FunctionNode (Database Representation)

`df.start(<function>)` adds a new row to `df.instances`, then iterates the nodes in the function graph bottom up, persisting each one to the `df.nodes` table along with the instance ID, a new ID for the node, and the IDs of its child nodes, if any.

```sql
CREATE TABLE df.nodes (
    id VARCHAR(8) PRIMARY KEY,
    instance_id VARCHAR(8),      -- Set by df.start()
    node_type TEXT NOT NULL,     -- SQL, THEN, IF, JOIN, LOOP, etc.
    query TEXT,                  -- SQL query or config JSON
    result_name TEXT,            -- Named result for $variable substitution
    left_node VARCHAR(8),        -- Left child ID
    right_node VARCHAR(8),       -- Right child ID
    status TEXT DEFAULT 'pending',
    result JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);
```

### DSL Functions

Each DSL function (`df.sql`, `df.sleep`, `df.join`, etc.) creates a Durofut and returns its JSON representation. All graph construction is stateless.

#### Example: `df.sql()`

```rust
// src/dsl.rs
#[pg_extern(schema = "df")]
pub fn sql(query: &str) -> String {
    Durofut {
        node_type: "SQL".to_string(),
        query: Some(query.to_string()),
        ..Default::default()
    }
    .to_json()
}
```

#### Example: `df.seq()` (Sequence/Then)

```rust
#[pg_extern(name = "seq", schema = "df")]
pub fn then_fn(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);       // Auto-wrap plain SQL if needed
    let b_fut = Durofut::ensure(b);
    
    Durofut {
        node_type: "THEN".to_string(),
        left_node: Some(Box::new(a_fut)),  // Embed first step
        right_node: Some(Box::new(b_fut)), // Embed second step
        ..Default::default()
    }
    .to_json()
}
```

#### Auto-Wrapping Plain SQL

The `Durofut::ensure()` function detects whether a string is already a Durofut JSON or plain SQL:

```rust
// src/types.rs
impl Durofut {
    pub fn ensure(s: &str) -> Self {
        if Self::is_durofut(s) {
            Self::from_json(s)           // Already a Durofut
        } else {
            // Plain SQL string
            Durofut {
                node_type: "SQL".to_string(),
                query: Some(s.to_string()),
                ..Default::default()
            }
        }
    }
    
    pub fn is_durofut(s: &str) -> bool {
        // Check if valid JSON with a recognized node_type
        serde_json::from_str::<Durofut>(s)
            .map(|d| VALID_NODE_TYPES.contains(&d.node_type.as_str()))
            .unwrap_or(false)
    }
}
```

This allows users to write `'SELECT 1' ~> 'SELECT 2'` instead of `df.sql('SELECT 1') ~> df.sql('SELECT 2')`.

### SQL Operators

Operators are syntactic sugar that call DSL functions:

```sql
-- src/lib.rs (extension_sql!)

-- Sequence: a ~> b calls df.seq(a, b)
CREATE OPERATOR ~> (
    FUNCTION = df.seq,
    LEFTARG = text,
    RIGHTARG = text
);

-- Name result: a |=> 'name' calls df.as_op(a, name)
CREATE OPERATOR |=> (
    FUNCTION = df.as_op,
    LEFTARG = text,
    RIGHTARG = text
);

-- Parallel join: a & b calls df.join(a, b)
CREATE OPERATOR & (
    FUNCTION = df.join,
    LEFTARG = text,
    RIGHTARG = text
);

-- Conditional: cond ?> then !> else
CREATE OPERATOR ?> (FUNCTION = df.if_then_op, ...);
CREATE OPERATOR !> (FUNCTION = df.if_else_op, ...);

-- Loop prefix: @> body calls df.loop(body)
CREATE OPERATOR @> (FUNCTION = df.loop_prefix_op, RIGHTARG = text);
```

### Node Insertion

When `df.start()` is called, it validates the complete graph and recursively inserts all nodes.
Opaque children are parsed one level at a time, and config children are materialized through the
same helper used by `df.explain()`:

```rust
fn insert_nodes(node: &Durofut, instance_id: &str) -> Result<String, String> {
    let left_id = insert_optional_child(node.left_node.as_deref(), instance_id)?;
    let right_id = insert_optional_child(node.right_node.as_deref(), instance_id)?;

    // condition_node and extra_nodes are first-class Durofut children. The
    // persisted query keeps the worker-facing child-ID representation.
    let query = node.transform_config_children(|child| insert_nodes(child, instance_id))?;

    insert_node_row(node, query, left_id, right_id, instance_id)
}
```

### Variable Capture

Variables set via `df.setvar()` are captured at `df.start()` time:

```rust
// Capture vars from df.vars table
let vars: HashMap<String, String> = Spi::connect(|client| {
    let mut vars = HashMap::new();
    for row in client.select("SELECT name, value FROM df.vars", None, &[]) {
        vars.insert(row.get("name"), row.get("value"));
    }
    vars
});

// Pass to orchestration
let input = FunctionInput {
    instance_id: instance_id.clone(),
    label: label.map(|s| s.to_string()),
    vars,  // Captured snapshot - immutable during execution
};
```

---

## Phase 2: Orchestration Execution

### Duroxide Integration

pg_durable uses [duroxide](https://github.com/microsoft/duroxide) for durable execution. Key concepts:

- **Orchestrations**: Deterministic functions that make scheduling decisions
- **Activities**: Non-deterministic I/O operations (SQL queries, HTTP calls)
- **Replay**: On restart, orchestrations replay to reconstruct state

```rust
// src/registry.rs - Register orchestrations and activities
pub fn register_orchestrations(registry: &mut OrchestrationRegistry) {
    registry.register(
        execute_function_graph::NAME,
        execute_function_graph::execute,
    );
    registry.register(
        execute_function_graph::SUBTREE_NAME,
        execute_function_graph::execute_subtree,
    );
}

pub fn register_activities(registry: &mut ActivityRegistry<PgPool>) {
    registry.register(load_function_graph::NAME, load_function_graph::execute);
    registry.register(execute_sql::NAME, execute_sql::execute);
    registry.register(execute_http::NAME, execute_http::execute);
    // ...
}
```

### Graph Loading

The `LoadFunctionGraph` activity loads the graph from PostgreSQL:

```rust
// src/activities/load_function_graph.rs
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    instance_id: String,
) -> Result<String, String> {
    // Get root node ID
    let root_node_id: String = sqlx::query_scalar(
        "SELECT root_node FROM df.instances WHERE id = $1"
    ).bind(&instance_id).fetch_one(&pool).await?;
    
    // Load all nodes for this instance
    let rows = sqlx::query(
        "SELECT id, node_type, query, result_name, left_node, right_node
         FROM df.nodes WHERE instance_id = $1"
    ).bind(&instance_id).fetch_all(&pool).await?;
    
    // Build FunctionGraph
    let mut nodes = BTreeMap::new();  // BTreeMap for deterministic order
    for row in rows {
        let node = FunctionNode {
            id: row.get("id"),
            node_type: row.get("node_type"),
            query: row.get("query"),
            result_name: row.get("result_name"),
            left_node: row.get("left_node"),
            right_node: row.get("right_node"),
        };
        nodes.insert(node.id.clone(), node);
    }
    
    let graph = FunctionGraph { instance_id, root_node_id, nodes };
    Ok(serde_json::to_string(&graph)?)
}
```

`df.start()` commits the duroxide start independently while its `df.instances`
and `df.nodes` writes remain in the caller's transaction. New orchestration
inputs therefore carry the originating top-level transaction ID. Graph
admission uses a single-shot probe: load immediately when the graph is visible,
otherwise inspect `pg_xact_status()`, then wait with deterministic durable
timers while the transaction is in progress. An abort terminates the engine
record without executing SQL; a committed transaction whose graph is still
absent identifies a savepoint rollback. The wait periodically uses
`continue_as_new` to bound replay history and never holds a management
connection between probes. Historical orchestration inputs omit the transaction
ID and continue scheduling the original load activity with its original input,
preserving in-flight replay compatibility.

### Node Execution

Internal node handlers return `NodeResult`, a `Result` whose error arm is a typed
`NodeError` rather than a plain `String`. This lets `df.break()` propagate through the
compound nodes (`THEN`, `IF`, `JOIN`, `RACE`) automatically via the `?` operator, instead
of every handler having to recognise an in-band JSON break sentinel:

```rust
// src/orchestrations/execute_function_graph.rs
pub enum NodeError {
    /// df.break() fired. Carries the break value. Caught only by execute_loop_node.
    Break(String),
    /// A genuine failure. Surfaces as a failed instance.
    Failure(String),
}

pub type NodeResult = Result<String, NodeError>;

// Any `?` on an existing Result<_, String> auto-converts the error to Failure, so
// activity calls and helpers need no per-call changes.
impl From<String> for NodeError {
    fn from(e: String) -> Self {
        NodeError::Failure(e)
    }
}
```

`execute_loop_node` is the only handler that catches `NodeError::Break` (turning it into the
loop's `Ok` result); `NodeError::Failure` keeps propagating. The orchestration boundary
functions (`execute` / `execute_subtree`) still return `Result<String, String>` because they
are registered with duroxide:

- `execute`: an uncaught top-level `Break` becomes a clear `Err` ("df.break() was called
  outside of a loop"), so the instance fails instead of completing with a sentinel value.
- `execute_subtree` (used by JOIN/RACE branches): a `Break` is carried out-of-band in the
  subtree envelope's `control` field and re-raised as `NodeError::Break` by
  `parse_subtree_envelope` in the parent orchestration.

The orchestration walks the graph recursively:

```rust
// src/orchestrations/execute_function_graph.rs
pub async fn execute(ctx: OrchestrationContext, input_json: String) -> Result<String, String> {
    let input: FunctionInput = serde_json::from_str(&input_json)?;
    
    // Load graph via activity (checkpointed)
    let graph_json = ctx
        .schedule_activity(load_function_graph::NAME, input.instance_id.clone())
        .into_activity()
        .await?;
    
    let graph: FunctionGraph = serde_json::from_str(&graph_json)?;
    let mut results: HashMap<String, String> = HashMap::new();
    
    // Execute starting from root node
    let exec_ctx = ExecutionContext {
        vars: input.vars.clone(),
        label: input.label.clone(),
    };
    
    let result = execute_function_node_with_vars(
        &ctx, &graph, &graph.root_node_id, &mut results, &exec_ctx
    ).await?;
    
    // Update status to completed
    ctx.schedule_activity(update_instance_status::NAME, ...).await;
    
    Ok(result)
}

async fn execute_function_node_with_vars(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node_id: &str,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> NodeResult {
    let node = graph.nodes.get(node_id).ok_or("Node not found")?;
    
    ctx.trace_info(format!("Executing node {} (type: {})", node_id, node.node_type));
    
    let result = match node.node_type.as_str() {
        "SQL" => execute_sql_node(ctx, node, results, exec_ctx).await?,
        "THEN" => execute_then_node(ctx, graph, node, results, exec_ctx).await?,
        "IF" => execute_if_node(ctx, graph, node, node_id, results, exec_ctx).await?,
        "JOIN" => execute_join_node(ctx, graph, node, node_id, results, exec_ctx).await?,
        "RACE" => execute_race_node(ctx, graph, node, node_id, results, exec_ctx).await?,
        "LOOP" => execute_loop_node(ctx, graph, node, results, exec_ctx).await?,
        "SLEEP" => execute_sleep_node(ctx, node).await?,
        "HTTP" => execute_http_node(ctx, node, results, exec_ctx).await?,
        "SIGNAL" => execute_signal_node(ctx, node).await?,
        "BREAK" => execute_break_node(ctx, node, node_id).await?,
        other => return Err(NodeError::Failure(format!("Unknown node type: {other}"))),
    };
    
    // Store named results for $variable substitution
    if let Some(ref name) = node.result_name {
        results.insert(name.clone(), result.clone());
    }
    
    Ok(result)
}
```

#### SQL Node Execution

```rust
async fn execute_sql_node(
    ctx: &OrchestrationContext,
    node: &FunctionNode,
    results: &HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> Result<String, String> {
    let query = node.query.as_ref().ok_or("SQL node has no query")?;
    
    // Substitute variables: $name, {var}, {sys_instance_id}
    let sys_vars = SystemVars {
        instance_id: exec_ctx.instance_id.clone(),
        label: exec_ctx.label.clone(),
    };
    let substituted = substitute_all(query, results, &exec_ctx.vars, &sys_vars);
    
    ctx.trace_info(format!("Executing SQL: {}", substituted));
    
    // Schedule activity (checkpointed by duroxide)
    ctx.schedule_activity(execute_sql::NAME, substituted)
        .into_activity()
        .await
}
```

#### THEN Node Execution (Sequence)

```rust
async fn execute_then_node(
    ctx: &OrchestrationContext,
    graph: &FunctionGraph,
    node: &FunctionNode,
    results: &mut HashMap<String, String>,
    exec_ctx: &ExecutionContext,
) -> Result<String, String> {
    // Execute left (first step)
    let left_id = node.left_node.as_ref().ok_or("THEN missing left")?;
    let _ = execute_function_node_with_vars(ctx, graph, left_id, results, exec_ctx).await?;
    
    // Execute right (second step)
    let right_id = node.right_node.as_ref().ok_or("THEN missing right")?;
    execute_function_node_with_vars(ctx, graph, right_id, results, exec_ctx).await
}
```

### Variable Substitution

Three types of variables are substituted:

1. **Result variables** (`$name`): From `|=>` operator, stores previous step results
2. **User variables** (`{name}`): From `df.setvar()`, captured at start
3. **System variables** (`{sys_instance_id}`, `{sys_label}`): Runtime metadata

```rust
// src/types.rs
pub fn substitute_all(
    query: &str,
    results: &HashMap<String, String>,
    vars: &HashMap<String, String>,
    sys_vars: &SystemVars,
) -> String {
    let mut result = query.to_string();
    
    // 1. System vars: {sys_*}
    result = result.replace("{sys_instance_id}", &sys_vars.instance_id);
    result = result.replace("{sys_label}", sys_vars.label.as_deref().unwrap_or(""));
    
    // 2. User vars: {name}
    for (name, value) in vars {
        result = result.replace(&format!("{{{}}}", name), value);
    }
    
    // 3. Result vars: $name (with smart extraction from SQL results)
    for (name, value) in results {
        let pattern = format!("${}", name);
        if result.contains(&pattern) {
            // Extract first column of first row from SQL result JSON
            let replacement = extract_value_for_substitution(value);
            result = result.replace(&pattern, &replacement);
        }
    }
    
    result
}
```

### Condition Evaluation

For `IF`, `LOOP(body, condition)`, and conditional operators:

```rust
// src/types.rs
pub fn evaluate_condition(result: &str) -> Result<bool, String> {
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(result) {
        // Extract first column of first row
        if let Some(rows) = json.get("rows").and_then(|r| r.as_array()) {
            if let Some(first_row) = rows.first() {
                if let Some(obj) = first_row.as_object() {
                    if let Some((_, value)) = obj.iter().next() {
                        return Ok(is_truthy(value));
                    }
                }
            }
        }
        return Ok(is_truthy(&json));
    }
    // Fallback for plain strings
    let lower = result.to_lowercase();
    Ok(matches!(lower.as_str(), "true" | "t" | "yes" | "1"))
}

pub fn is_truthy(value: &serde_json::Value) -> bool {
    match value {
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_i64().map(|i| i != 0).unwrap_or(false),
        Value::String(s) => matches!(s.to_lowercase().as_str(), "true" | "t" | "yes" | "1"),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
        Value::Null => false,
    }
}
```

### Parallel Execution (JOIN/RACE)

JOIN and RACE use duroxide's sub-orchestration support:

```rust
async fn execute_join_node(...) -> Result<String, String> {
    let left_id = node.left_node.as_ref().ok_or("JOIN missing left")?;
    let right_id = node.right_node.as_ref().ok_or("JOIN missing right")?;
    
    // Create sub-orchestration inputs
    let left_input = create_subtree_input(graph, left_id, results);
    let right_input = create_subtree_input(graph, right_id, results);
    
    // Schedule parallel sub-orchestrations
    let left_handle = ctx.schedule_orchestration(SUBTREE_NAME, &left_id, left_input);
    let right_handle = ctx.schedule_orchestration(SUBTREE_NAME, &right_id, right_input);
    
    // Wait for all to complete (duroxide handles parallelism)
    let (left_result, right_result) = tokio::join!(
        left_handle.into_orchestration(),
        right_handle.into_orchestration()
    );
    
    // Combine results
    let results = vec![left_result?, right_result?];
    Ok(serde_json::to_string(&results)?)
}
```

For RACE, duroxide's `select` is used to return the first completed result.

### Loops and Continue-As-New

Loops use duroxide's `continue_as_new` to avoid unbounded history growth. Their execution context is determined by graph position, but only one rule is needed:

- A loop that is the root of the *current* orchestration's node tree runs **inline**, and its `continue_as_new` starts that orchestration's next generation. This applies both to a loop at the function graph's root (hosted by `execute_function_graph`) and to a loop at the root of a subtree (hosted by `execute_subtree`). It is safe because there is no upstream prefix to re-execute: re-entering from the root lands back on the same loop node.
- Any deeper loop is spawned as an `execute_subtree` child rooted at the loop node, which then runs it inline per the rule above. Its `continue_as_new` advances only that child, preserving prefix and suffix work in the waiting parent. A loop used directly as a JOIN or RACE branch needs no special case — every branch is an `execute_subtree` child.

`execute_subtree` is therefore structurally identical to `execute_function_graph`: both root an execution context at their own node and host an inline root loop. They differ only in the input envelope they re-enter with on `continue_as_new` (`FunctionInput` vs `SubtreeInput`), in the fact that only the root orchestration touches instance-level status, and in where their graph comes from — `execute_function_graph` loads it from `df.nodes` on its first generation, while `execute_subtree` receives it inline from its parent. The graph is loaded exactly once per instance and then carried inline through every child input and every `continue_as_new` generation, so `submitted_by` is fixed for the instance's lifetime and a post-start `df.nodes` tamper is never read. Role deletion and privilege revocation are still enforced per node execution, by connecting *as* `submitted_by` for SQL and by re-checking `EXECUTE` privilege per HTTP request.

Both paths call `run_loop_iteration`, which executes the body, catches `NodeError::Break`, evaluates the optional post-body condition, and propagates `NodeError::Failure`. A child stamps its LOOP node `running` on each generation and `completed` or `failed` on exit; because `continue_as_new` returns a future that never resolves, a continuing generation never stamps a terminal status. If a live loop loses a RACE, the parent records the loop node as terminal `failed` with a cancellation reason because duroxide cancellation stops the child before it can run its own terminal stamp.

Node status stamps contain the full composed orchestration lineage: `{root_instance}::{generation}::{child_node}::{generation}...`. Read-time inference and the write fence walk that lineage so stale writes and superseded nested branches are evaluated at every ancestor generation.

---

## Data Flow Diagram

```
User Session                                      Background Worker
─────────────                                     ─────────────────

SELECT df.start(
  'SELECT 1' |=> 'a'
  ~> 'SELECT $a + 1'
);
    │
    ├─► df.sql('SELECT 1')
    │       └─► INSERT INTO df.nodes (id='abc', type='SQL', query='SELECT 1')
    │       └─► Returns: {"node_id":"abc","node_type":"SQL",...}
    │
    ├─► df.as_op(..., 'a')
    │       └─► UPDATE df.nodes SET result_name='a' WHERE id='abc'
    │       └─► Returns: {"node_id":"abc","result_name":"a",...}
    │
    ├─► df.sql('SELECT $a + 1')
    │       └─► INSERT INTO df.nodes (id='def', type='SQL', query='SELECT $a + 1')
    │
    ├─► df.seq(abc, def)
    │       └─► INSERT INTO df.nodes (id='ghi', type='THEN', left='abc', right='def')
    │
    └─► df.start(ghi, NULL)
            ├─► INSERT INTO df.instances (id='xyz', root_node='ghi')
            ├─► UPDATE df.nodes SET instance_id='xyz' WHERE id IN ('abc','def','ghi')
            ├─► Capture vars from df.vars
            └─► duroxide.start_orchestration('xyz', input)
                    │
                    │                                     ┌─────────────────────────┐
                    └────────────────────────────────────►│ Duroxide Dispatcher     │
                                                          │                         │
                                                          │ Picks up orchestration  │
                                                          │ instance 'xyz'          │
                                                          └───────────┬─────────────┘
                                                                      │
                                                                      ▼
                                                          ┌─────────────────────────┐
                                                          │ execute_function_graph  │
                                                          │                         │
                                                          │ 1. LoadFunctionGraph    │
                                                          │    (activity)           │
                                                          │                         │
                                                          │ 2. Execute THEN node    │
                                                          │    → Execute SQL 'abc'  │
                                                          │      (activity)         │
                                                          │    → Store result 'a'   │
                                                          │    → Execute SQL 'def'  │
                                                          │      with $a substituted│
                                                          │                         │
                                                          │ 3. Update status        │
                                                          └─────────────────────────┘
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `src/types.rs` | Core types: `Durofut`, `FunctionNode`, `FunctionGraph`, variable substitution |
| `src/dsl.rs` | DSL functions: `df.sql`, `df.join`, `df.if`, `df.loop`, etc. |
| `src/lib.rs` | Schema setup, SQL operators (`~>`, `|=>`, `&`, `?>`, `!>`, `@>`) |
| `src/client.rs` | Duroxide client for `df.start()`, `df.signal()`, `df.cancel()` |
| `src/worker.rs` | Background worker setup and duroxide runtime initialization |
| `src/registry.rs` | Orchestration and activity registration |
| `src/orchestrations/execute_function_graph.rs` | Main orchestration: graph walking, node execution |
| `src/activities/load_function_graph.rs` | Load graph from `df.nodes` |
| `src/activities/execute_sql.rs` | Execute SQL via sqlx |
| `src/activities/execute_http.rs` | Execute HTTP requests via reqwest |

---

## Summary

1. **Phase 1 (DSL)**: User calls DSL functions via SQL. Each function creates a node in `df.nodes`. Operators chain nodes into a graph. `df.start()` links all nodes to an instance and enqueues to duroxide.

2. **Phase 2 (Execution)**: Background worker's duroxide runtime picks up the orchestration. `LoadFunctionGraph` activity loads the graph. Orchestration walks the graph, scheduling activities for each step. Results flow between nodes via `$variable` substitution. Loops use `continue_as_new` for durability.

The key insight is that **graph construction is synchronous** (in user transaction) while **execution is asynchronous and durable** (in background worker via duroxide replay).
