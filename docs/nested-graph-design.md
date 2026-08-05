# DSL Graph Construction Refactor: Nested JSON Design

## Motivation

The original DSL implementation inserted nodes into `df.nodes` during graph construction (e.g., inside `df.sql()`, `df.join()`, etc.). This created several problems:

1. **Premature database writes**: Graph construction performs I/O before `df.start()` is called
2. **Abandoned nodes**: Successfully constructed graphs that are never passed to `df.start()` leave rows with no instance
3. **Complex explain mode**: Requires temporary tables and session variables to avoid polluting the database
4. **No optimization opportunities**: Graph cannot be analyzed or transformed before execution
5. **Accidental pollution**: Users experimenting with DSL expressions create database state

### Example of the Previous Issue

```sql
-- Constructing a graph without starting it left unowned rows behind.
SELECT df.sql('SELECT 1');
```

## Design Approach: Nested JSON

### Core Concept

DSL functions return **self-contained JSON** that embeds the complete subtree, not just references to database-stored nodes. Graph construction becomes pure functional composition with no side effects.

### Data Structure

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Durofut {
    pub node_type: String,
    pub left_node: Option<Box<RawValue>>,
    pub right_node: Option<Box<RawValue>>,
    pub condition_node: Option<Box<RawValue>>,
    pub extra_nodes: Vec<Box<RawValue>>,
    pub query: Option<String>,
    pub result_name: Option<String>,
}
```

### Serialization Boundary

`Durofut` is the transient graph-construction envelope returned by DSL functions. Its child fields
hold opaque JSON objects as `RawValue`, so deserializing one node does not recursively deserialize
its whole subtree. Walkers parse each child with a fresh deserializer as they descend. This avoids
serde_json's recursion ceiling while preserving the configured graph depth and node-count limits.

Conditions for IF/LOOP and additional JOIN branches are first-class `condition_node` and
`extra_nodes` fields. They do not live inside the escaped `query` string, so nested config graphs
grow linearly and use the same traversal path as left and right children.

The left-fold composers `df.seq()`, `df.join()`, and `df.race()` remember their most recent output
in backend-local state. When that exact output is the next call's left operand, they embed it
verbatim and validate only the newly arrived right operand. Other left operands pass through normal
`Durofut` parsing or SQL wrapping. This avoids rescanning an increasingly large left-deep graph at
every composition step without trusting caller-crafted text; `flatten_graph` remains the path-aware
validation boundary for the complete graph.

`flatten_graph` is the single materialization and validation pass used by both `df.start()` and `df.explain()`. It walks the envelope iteratively, enforces node-type, depth, and node-count limits, and reports failures with paths such as `root.left.condition_node`. IDs are assigned when children are discovered, allowing the parent `FunctionNode` to be emitted before its children. Persisting that pre-order output is valid because the same-instance node foreign keys are `DEFERRABLE INITIALLY DEFERRED`; changing that constraint requires changing the materialization order too.

The envelope is distinct from durable execution state. During `df.start()`, config children are
materialized as node rows and `df.nodes.query` retains the worker-facing format with child IDs:

```json
{"condition_node":"a1b2c3d4"}
```

Changing the envelope therefore does not change queued or in-flight instances, `FunctionNode`, or
duroxide replay state. Serialized `Durofut` text is an unversioned DSL representation and is not a
cross-version persistence contract.

### Example Flow

```sql
-- df.sql() creates: {"node_type":"SQL","query":"SELECT 1",...}
SELECT df.sql('SELECT 1');

-- df.seq() embeds both children (no node IDs yet)
SELECT df.sql('SELECT 1') ~> df.sql('SELECT 2');
-- Returns:
-- {
--   "node_type":"THEN",
--   "left_node": {"node_type":"SQL","query":"SELECT 1",...},
--   "right_node": {"node_type":"SQL","query":"SELECT 2",...}
-- }

-- Node IDs are generated when df.start() inserts into df.nodes
SELECT df.start(df.sql('SELECT 1') ~> df.sql('SELECT 2'));
-- Now inserts all nodes with generated IDs and instance_id
```

### Benefits

✅ **No database writes during construction** - Pure string manipulation
✅ **Transaction-safe** - Only `df.start()` writes to the database
✅ **No leaks on error** - Failed DSL calls leave no state
✅ **Simple explain mode** - Just parse JSON and visualize
✅ **Identical graphs produce identical JSON** - Enables caching and comparison
✅ **Graph optimization** - Full graph available for analysis before execution
✅ **User-friendly** - Can inspect intermediate graphs as JSON
✅ **Stateless** - No TLS, no registry, no cleanup required

### Trade-offs

⚠️ **Larger JSON payloads** - Full tree instead of node IDs
- Typical overhead: 200-500 bytes for common graphs vs. ~45 bytes + DB lookup
- Still negligible for typical graphs (< 100 nodes)
- Mitigated by only passing through function boundaries, not stored long-term

## Discarded Approaches

### 1. Thread-Local Storage (TLS)

**Approach**: Store node arena in `thread_local!` registry, DSL functions return lightweight handles.

**Why Rejected**:
- PostgreSQL's `longjmp` error handling bypasses Rust destructors
- TLS doesn't participate in subtransaction rollback
- Memory leaks accumulate across queries in same session
- Incompatible with parallel query execution
- Background workers create separate TLS instances
- Requires complex manual cleanup on every error path
- Current database approach already has similar issues

### 2. UUID-Keyed Global Registry

**Approach**: `DashMap<Uuid, Arena<Node>>` with composite `GraphRef` type returned from SQL.

**Why Rejected**:
- Memory leaks when errors occur before `df.start()`
- No automatic cleanup mechanism
- Graph merging adds complexity (how to unify separate arenas?)
- Requires PostgreSQL composite type overhead on every function call
- Still needs manual cleanup strategy
- More complex than nested JSON with no compelling benefit

### 3. Use Temporary Tables for Graph Construction

**Approach**: Create session-scoped temp tables for node storage during DSL construction, then copy to permanent tables in `df.start()`.

```sql
CREATE TEMP TABLE _dsl_nodes (LIKE df.nodes) ON COMMIT DROP;
-- DSL functions insert to _dsl_nodes
-- df.start() copies to df.nodes with instance_id
```

**Why Rejected**:
- Still requires database I/O during graph construction (slower than in-memory)
- Temp tables don't survive across function call boundaries reliably
- `ON COMMIT DROP` semantics complicate multi-statement DSL composition
- `ON COMMIT PRESERVE ROWS` leaks across queries in the same transaction
- Adds complexity without solving the fundamental issue
- Still need to handle cross-temp-table references for `Durofut.ensure()`
- PostgreSQL temp table overhead for every DSL session
- Nested JSON is simpler and faster

## Compatibility

The SQL API and durable execution format are unchanged. `df.start()` still materializes graphs as
flat `df.nodes` rows, and queued or in-flight instances continue to use the same `FunctionNode`
representation.

The serialized `Durofut` envelope is an internal, unversioned DSL representation. Its shape may
change between releases, so applications should not persist it as a cross-version workflow format.
