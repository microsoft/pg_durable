# DSL Graph Construction Refactor: Nested JSON Design

## Motivation

The current DSL implementation inserts nodes into `df.nodes` during graph construction (e.g., inside `df.sql()`, `df.join()`, etc.). This creates several problems:

1. **Premature database writes**: Graph construction performs I/O before `df.start()` is called
2. **Orphaned nodes**: Errors during graph construction leave partial state in the database with no `instance_id`
3. **No transaction management**: Nodes inserted before `df.start()` don't participate in transaction rollback
4. **Complex explain mode**: Requires temporary tables and session variables to avoid polluting the database
5. **No optimization opportunities**: Graph cannot be analyzed or transformed before execution
6. **Accidental pollution**: Users experimenting with DSL expressions create database state

### Example of Current Issues

```sql
-- Error creates orphaned node
SELECT df.sql('SELECT 1') ~> df.sql('SYNTAX ERROR');
-- First node inserted to df.nodes with no instance_id, never cleaned up

-- Transaction rollback doesn't help
BEGIN;
SELECT df.sql('SELECT 1');
ROLLBACK;
-- Node still in df.nodes
```

## Design Approach: Nested JSON

### Core Concept

DSL functions return **self-contained JSON** that embeds the complete subtree, not just references to database-stored nodes. Graph construction becomes pure functional composition with no side effects.

### Data Structure

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Durofut {
    pub node_type: String,
    pub query: Option<String>,
    pub result_name: Option<String>,
    // Children are embedded, not referenced by ID
    // Node IDs are generated during df.start(), not during construction
    pub left_node: Option<Box<Durofut>>,
    pub right_node: Option<Box<Durofut>>,
}
```

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

## Implementation Plan

### Phase 1: Update Type Definitions

**File**: `src/types.rs`

1. **Change `Durofut` structure**:
   ```rust
   pub struct Durofut {
       pub node_type: String,
       pub query: Option<String>,
       pub result_name: Option<String>,
       // Embed children directly, not by ID reference
       // node_id is removed - IDs generated during df.start()
       pub left_node: Option<Box<Durofut>>,
       pub right_node: Option<Box<Durofut>>,
   }
   ```

2. **Update serialization**:
   - `to_json()` - already works with serde
   - `from_json()` - already works with serde
   - `is_durofut()` - simplified to just check deserialization
   - `ensure()` - no node_id needed

3. **Remove `insert_node()` method** - no longer needed in DSL functions

4. **Remove `is_explain_mode()` function** - no longer needed

5. **Update `ensure()` to not set node_id**:

### Phase 2: Update DSL Functions

**File**: [src/dsl.rs](../src/dsl.rs)

All DSL functions updated to embed children as `Box<Durofut>` instead of storing ID references. No database writes during construction — just JSON composition.

**Before** (old pattern — `join` as example):
```rust
let durofut = Durofut {
    node_id: short_id(),
    left_node: Some(a_fut.node_id),  // ID reference
    right_node: Some(b_fut.node_id), // ID reference
    ...
};
durofut.insert_node();  // Database write
```

**After** (new pattern):
```rust
let durofut = Durofut {
    node_type: "JOIN".to_string(),
    left_node: Some(Box::new(a_fut)),  // Embed child
    right_node: Some(Box::new(b_fut)), // Embed child
    ..Default::default()
};
durofut.to_json()  // No database write, no node_id
```

See [src/dsl.rs](../src/dsl.rs) for the full implementation.

### Phase 3: Update `df.start()`

**File**: [src/dsl.rs](../src/dsl.rs)

`link_nodes()` replaced with `insert_nodes()` — a recursive function that:
1. Generates node IDs via `short_id()` during insertion (post-order traversal)
2. Inserts children before parents so their IDs are available
3. Handles config-embedded children (IF condition, JOIN3 extras, LOOP condition) via `transform_config_children()`
4. No `HashSet` needed — single tree traversal

See `start()` → `insert_nodes()` in [src/dsl.rs](../src/dsl.rs) for the full implementation.

### Phase 4: Update `df.explain()`

**File**: [src/explain.rs](../src/explain.rs)

Drastically simplified — no temp tables or database access needed for DSL expressions:

1. `explain()` dispatches between instance IDs (8-char hex) and DSL expressions
2. `explain_expression()` parses the nested JSON via `Durofut::ensure()`, then builds an in-memory node map with generated IDs (N1, N2, ...)
3. `collect_nodes()` walks the tree recursively, handling config-embedded children via `transform_config_children()`
4. Visualization uses the existing `build_tree_visualization()`

**Removed**: `is_explain_mode()` checks, `df._explain_mode` session variable, `_durable_explain_nodes` temp table.

See [src/explain.rs](../src/explain.rs) for the full implementation.

### Phase 5: Test Updates

#### Unit Tests

**File**: `src/lib.rs` or test modules

- Update any tests that inspect `df.nodes` before `df.start()`
- Tests should now only verify JSON structure, not database state
- Add tests for nested graph construction

Example:
```rust
#[pg_test]
fn test_nested_graph_construction() {
    let result = Spi::get_one::<String>(
        "SELECT df.sql('SELECT 1') ~> df.sql('SELECT 2')"
    ).expect("query failed");

    let graph: Durofut = serde_json::from_str(&result).expect("parse failed");
    assert_eq!(graph.node_type, "THEN");
    assert!(graph.left_node.is_some());
    assert!(graph.right_node.is_some());
}
```

#### E2E Tests

**Directory**: `tests/e2e/sql/`

Most E2E tests should work **without changes** because they:
1. Build DSL expression
2. Call `df.start()`
3. Wait for completion
4. Assert results

**Tests that will need updates**:
- `10_explain.sql` - Must change from `$$...$$` syntax to passing Durofut JSON or plain SQL directly to `df.explain()`
- Any test that queries `df.nodes` before calling `df.start()`
- Tests that verify node count or structure before execution

**What to verify after changes**:
- All existing E2E tests pass
- Node insertion happens correctly in `df.start()`
- `instance_id` is always set on all nodes
- No orphaned nodes in `df.nodes` after errors

### Phase 6: Documentation Updates

#### USER_GUIDE.md

Update sections on:
- **Graph Construction**: Clarify that DSL functions don't write to database
- **df.explain()**: Update to show it works on DSL expressions directly (no temp tables)
- **Debugging**: Update guidance on inspecting graph JSON

Example addition:
```markdown
### Understanding Graph Construction

DSL functions build graph structures in memory without touching the database:

```sql
-- This creates JSON, not database records
SELECT df.sql('SELECT 1') ~> df.sql('SELECT 2');

-- Only df.start() writes to the database
SELECT df.start(df.sql('SELECT 1') ~> df.sql('SELECT 2'));
```

You can inspect the graph structure by examining the JSON:
```sql
SELECT df.sql('SELECT 1') ~> df.sql('SELECT 2');
-- Returns: {"node_type":"THEN",...}
```
```

#### docs/ARCHITECTURE.md

Update:
- Data flow section to reflect new construction model
- Remove mention of temp tables for explain mode
- Add section on stateless DSL design

#### README.md

Update quick start examples if they reference graph construction details.

## Implementation Checklist

All items completed in commit `fdfbd44` and subsequent fixes:

- [x] Update `Durofut` struct in `types.rs` to use `Box<Durofut>` for children
- [x] Remove `insert_node()` method from `Durofut`
- [x] Update `Durofut::ensure()` to not call `insert_node()`
- [x] Remove `is_explain_mode()` function from `types.rs`
- [x] Update all DSL functions in `dsl.rs` to embed children instead of storing IDs
- [x] Remove `insert_node()` calls from all DSL functions
- [x] Update `df.as_named()` to remove UPDATE query
- [x] Replace `link_nodes()` with `insert_nodes()` in `df.start()`
- [x] Add helper function for config node extraction (`for_each_config_child`, `transform_config_children`)
- [x] Simplify `df.explain()` in `explain.rs` to parse nested JSON
- [x] Remove temp table logic from `explain_expression()`
- [x] Remove `df._explain_mode` session variable usage
- [x] Update unit tests to verify JSON structure
- [x] Run all E2E tests and fix any failures
- [x] Update `USER_GUIDE.md` with new graph construction model
- [x] Update `docs/ARCHITECTURE.md` with stateless design
- [x] Update `README.md` if needed (checked — no stale references)
- [x] Run `cargo fmt --all`
- [x] Run `cargo clippy --features pg17` and fix warnings
- [x] Run `./scripts/test-unit.sh`
- [x] Run `./scripts/test-e2e-local.sh`

## Migration Notes

### Backward Compatibility

**Breaking changes**:
- Durofut JSON structure changes (children embedded vs. referenced)
- Code relying on inspecting `df.nodes` before `df.start()` will break

**Non-breaking**:
- All SQL APIs remain the same (`df.sql()`, `df.start()`, etc.)
- Existing workflows continue to work
- Database schema unchanged

### Rollout Strategy

Completed — shipped in commit `fdfbd44` on branch `pinodeca/nested-graph` (PR #5).

## Success Criteria

✅ All unit tests pass
✅ All E2E tests pass
✅ No database writes during DSL construction
✅ No orphaned nodes in `df.nodes`
✅ `df.explain()` works on DSL expressions
✅ No clippy warnings or format issues
✅ Documentation updated and clear

## Future Enhancements

Once this is in place, we can:
- **Graph optimization**: Dead code elimination, common subexpression elimination
- **Validation**: Check for errors before execution (invalid SQL syntax, missing variables)
- **Visualization**: Web UI for graph structure
- **Compilation**: Pre-compile graphs to optimized execution plans
- **Debugging**: Step through graph execution with breakpoints
