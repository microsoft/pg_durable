# Sub-Orchestration Feature Implementation Summary

## Overview

This implementation adds comprehensive sub-orchestration and workflow composition capabilities to pg_durable, enabling modular, reusable, and composable durable functions.

## Features Implemented

### 1. Sub-Orchestration Calls (`df.call()`)

**Purpose:** Invoke child workflows from within parent workflows, with the parent waiting for the child to complete.

**Syntax:**
```sql
-- Inline workflow
df.call('SELECT process_data($id)')

-- Named function
df.call('my_workflow')

-- With input
df.call('validate_order', '{"order_id": 123}')
```

**Technical Details:**
- Adds `CALL` node type to the graph
- Uses duroxide's `schedule_sub_orchestration` for execution
- Supports both inline SQL/graph expressions and named function references
- Results can be captured with `|=>` operator
- Fully durable and replay-safe

**Files Modified:**
- `src/dsl.rs` - Added `df.call()` DSL function
- `src/orchestrations/execute_function_graph.rs` - Added `execute_call_node()` handler
- `docs/grammar.md` - Added CALL node type documentation

### 2. Named Function Definitions

**Purpose:** Define reusable workflow templates with names, creating a library of composable functions.

**Syntax:**
```sql
-- Define a function
SELECT df.define('workflow_name', 'SELECT step1() ~> SELECT step2()', 'Description');

-- Call it
SELECT df.start(df.call('workflow_name'));

-- List all functions
SELECT * FROM unnest(df.list_functions());

-- Remove a function
SELECT df.undefine('workflow_name');
```

**Technical Details:**
- New table: `df.function_definitions` stores named workflow templates
- Functions can be defined once and called from multiple workflows
- `df.call()` automatically detects named vs inline workflows
- Named functions are referenced by root node ID

**Files Modified:**
- `src/lib.rs` - Added `df.function_definitions` table
- `src/dsl.rs` - Added `df.define()`, `df.undefine()`, `df.list_functions()`
- `src/dsl.rs` - Updated `df.call()` to support named function lookup

### 3. Fan-Out/Fan-In Helpers

**Purpose:** Enable dynamic parallel execution with variable-sized arrays of workflows.

**Syntax:**
```sql
-- Wait for all branches (fan-out/fan-in)
df.when_all('["task1", "task2", "task3"]')
df.when_all('[...]', 2)  -- with concurrency limit

-- Race between branches (fan-out/first-wins)
df.when_any('["source1", "source2"]')
```

**Technical Details:**
- `df.when_all()` - Executes all workflows in parallel, waits for all to complete
- `df.when_any()` - Races workflows, returns first to complete (currently limited to 2)
- Uses duroxide's `join()` and `select2()` for parallel orchestration
- Returns JSON array of results (when_all) or single result (when_any)
- Supports optional concurrency limit parameter (documented, not enforced yet)

**Files Modified:**
- `src/dsl.rs` - Added `df.when_all()` and `df.when_any()` DSL functions
- `src/orchestrations/execute_function_graph.rs` - Added handlers for WHEN_ALL and WHEN_ANY nodes
- `docs/grammar.md` - Added node type documentation

## Testing

**E2E Tests Added:**
- `17_sub_orchestration_call.sql` - Basic inline sub-orchestration invocation
- `18_named_sub_functions.sql` - Named function definition, calling, and management
- `19_fan_out_when_all.sql` - Dynamic parallel execution with when_all
- `20_complex_composition.sql` - Complex scenario combining all features

**Test Coverage:**
- ✅ Inline sub-orchestration calls
- ✅ Named function definition and invocation
- ✅ Function listing and removal
- ✅ Fan-out/fan-in with when_all
- ✅ Complex compositions combining multiple patterns
- ✅ Sequential then parallel then fan-out workflows
- ✅ Result capture with |=> operator

## Documentation

**Updated Files:**
- `USER_GUIDE.md` - New "Sub-Orchestrations" section with comprehensive examples
- `USER_GUIDE.md` - Updated Quick Reference Card
- `USER_GUIDE.md` - Updated Key Features table
- `docs/grammar.md` - Added new node types to grammar reference

**Documentation Includes:**
- Basic sub-orchestration call examples
- Named function management examples
- Fan-out/fan-in pattern examples
- Complex real-world scenarios (order processing)
- Best practices and use cases
- API reference for all new functions

## Architecture Notes

### Duroxide Integration

The implementation leverages duroxide's native sub-orchestration capabilities:
- `schedule_sub_orchestration()` - Schedules child orchestrations
- `join()` - Waits for multiple orchestrations in parallel
- `select2()` - Races between two orchestrations

### Graph Structure

Sub-orchestrations are executed using the existing `execute_subtree` orchestration:
- Child graphs are serialized and passed as input
- Results are captured and returned to parent
- All execution is durable and replay-safe

### Design Decisions

1. **Named vs Inline:** `df.call()` auto-detects based on string format
   - Names don't start with `{`, `SELECT`, `INSERT`, etc.
   - Enables natural API: `df.call('my_func')` vs `df.call('SELECT ...')`

2. **Reuse of execute_subtree:** Rather than creating new orchestration types, reuses the existing subtree orchestration mechanism originally built for JOIN/RACE

3. **when_any Limitation:** Currently limited to 2 branches using duroxide's `select2()`
   - Could be extended with recursive select2 calls or different strategy
   - Documented as current limitation

4. **Concurrency Limit:** API accepts parameter but doesn't enforce it yet
   - Would require batching implementation
   - Documented as future enhancement

## Database Schema Changes

### New Table: df.function_definitions
```sql
CREATE TABLE df.function_definitions (
    name TEXT PRIMARY KEY,
    root_node VARCHAR(8) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
```

### New Node Types
- `CALL` - Sub-orchestration invocation
- `WHEN_ALL` - Dynamic parallel join
- `WHEN_ANY` - Dynamic parallel race

## API Reference

### New Functions

| Function | Purpose |
|----------|---------|
| `df.call(graph_or_name, input)` | Invoke sub-orchestration (inline or named) |
| `df.define(name, graph, description)` | Define named function |
| `df.undefine(name)` | Remove named function |
| `df.list_functions()` | List all defined functions |
| `df.when_all(workflows_array, limit)` | Fan-out/fan-in pattern |
| `df.when_any(workflows_array)` | Fan-out/first-wins pattern |

### Usage Examples

```sql
-- Define reusable functions
SELECT df.define('validate', 'SELECT check_data()', 'Validation workflow');

-- Compose them
SELECT df.start(
    df.seq(
        df.call('validate'),
        df.join(
            df.call('process_a'),
            df.call('process_b')
        )
    )
);

-- Fan-out pattern
SELECT df.start(
    df.when_all('[
        "SELECT task(1)",
        "SELECT task(2)",
        "SELECT task(3)"
    ]')
);
```

## Benefits

1. **Modularity** - Break complex workflows into manageable pieces
2. **Reusability** - Define once, use many times across workflows
3. **Maintainability** - Update sub-workflows independently
4. **Composability** - Build sophisticated patterns from simple blocks
5. **Library Building** - Create organizational workflow libraries
6. **Parallel Patterns** - Support both fixed and dynamic parallelism
7. **Observability** - Sub-orchestrations are traced and logged

## Future Enhancements (Out of Scope)

These were discussed in the requirements but not implemented:

1. **Parent Cancellation Propagation** - Automatically cancel children when parent is cancelled
2. **Parent/Child Tracking** - Add parent_instance_id column to df.instances for tree view
3. **Fire-and-Forget Mode** - Option to not wait for child completion
4. **Retry Policies** - Automatic retry of failed sub-orchestrations
5. **Deterministic Child IDs** - Deduplication of sub-orchestration instances
6. **Concurrency Limiting** - Actual enforcement of concurrency_limit in when_all
7. **when_any N-way** - Support for more than 2 branches in when_any

## Compatibility

- ✅ Backward compatible - no breaking changes to existing APIs
- ✅ Works with all existing node types (SQL, THEN, IF, LOOP, etc.)
- ✅ Compatible with result capture (`|=>`) and variable substitution
- ✅ Integrates seamlessly with existing monitoring and explain functions

## Performance Considerations

- Sub-orchestrations add overhead (serialization, new orchestration instance)
- Use for logical composition, not micro-optimization
- For simple parallel SQL, prefer `df.join()` or `&` operator
- Fan-out with many branches can create many concurrent orchestrations

## Conclusion

This implementation provides a complete sub-orchestration and workflow composition system for pg_durable. It enables building complex, modular, and reusable durable functions with both fixed and dynamic parallel execution patterns. The implementation is durable, replay-safe, and fully integrated with the existing pg_durable architecture.
