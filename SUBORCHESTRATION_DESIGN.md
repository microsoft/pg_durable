# Sub-Orchestration Reimplementation Using Function Templates

## Overview

This PR reimplements the sub-orchestration feature (#54) using the function templates system (#41), consolidating two separate concepts into a unified design.

## Problem Statement

PR #54 introduced sub-orchestration capabilities by creating a new `df.function_definitions` table and associated functions (`df.define()`, `df.undefine()`, `df.list_functions()`). However, PR #41 had already implemented a more comprehensive template system with `df.templates` that supports:
- Variable substitution with `{placeholder}` syntax
- Version tracking and soft deletes
- Audit trail (created_by, created_at)
- Template metadata and descriptions

Having both `function_definitions` and `templates` would create confusion and redundancy.

## Solution

Use `df.templates` as the single source of truth for reusable workflow definitions. The `df.call()` function now looks up templates instead of function definitions.

## Implementation Details

### 1. Template Management (src/templates.rs)

New module providing template lifecycle management:

```rust
df.create_template(name, dsl_template, description)
df.start_template(template_name, label, local_vars)
df.drop_template(name)                    // Soft delete
df.update_template(name, dsl, description)
df.get_template(name)
df.list_templates(name_pattern, created_by_user)
df.explain_template(template_name)
```

### 2. Schema Changes (src/lib.rs)

```sql
-- New table
CREATE TABLE df.templates (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    dsl_template TEXT NOT NULL,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by TEXT DEFAULT current_user,
    description TEXT
);

-- Modified table
ALTER TABLE df.instances ADD COLUMN template_id BIGINT
    REFERENCES df.templates(id);

-- Unique constraint for active templates
CREATE UNIQUE INDEX idx_templates_name_active_unique 
    ON df.templates(name) WHERE active = true;
```

### 3. Sub-Orchestration Functions (src/dsl.rs)

#### df.call(template_name_or_graph, input)
Invokes a sub-orchestration. Can reference:
- A template name: `df.call('validate_order')`
- An inline graph: `df.call('SELECT step1() ~> SELECT step2()')`

Creates a `CALL` node that will be executed as a sub-orchestration.

#### df.when_all(workflows, concurrency_limit)
Fan-out/fan-in pattern - executes multiple workflows in parallel and waits for all:
```sql
df.when_all('["task1", "task2", "task3"]')      -- Unlimited concurrency
df.when_all('["job1", "job2", "job3", "job4"]', 2)  -- Max 2 concurrent
```

Creates a `WHEN_ALL` node that schedules multiple sub-orchestrations in parallel.

#### df.when_any(workflows)
Race pattern - executes multiple workflows in parallel and returns when first completes:
```sql
df.when_any('["fetch_cache", "fetch_db", "fetch_api"]')
```

Creates a `WHEN_ANY` node that uses duroxide's `select_any()`.

### 4. Orchestration Handlers (src/orchestrations/execute_function_graph.rs)

Three new node type handlers added to the main execution switch:

```rust
"call" => execute_call_node(...)      // Sub-orchestration invocation
"when_all" => execute_when_all_node(...)  // Parallel fan-out/fan-in
"when_any" => execute_when_any_node(...)  // Parallel race
```

Each handler:
1. Parses config from node.query (JSON)
2. Serializes graph and execution context
3. Schedules sub-orchestration via `ctx.schedule_sub_orchestration(SUBTREE_NAME, ...)`
4. Awaits result(s)
5. Stores results in the results map if named

### 5. E2E Tests

Three comprehensive test files:
- `26_templates.sql` - Template CRUD operations and lifecycle
- `27_sub_orchestration_templates.sql` - Calling templates as sub-orchestrations
- `28_when_all_when_any.sql` - Parallel execution patterns

Each test follows the standard pattern:
1. Setup (create tables, templates)
2. Start durable function
3. Poll for completion (30s timeout)
4. Verify results
5. Cleanup

### 6. Documentation (USER_GUIDE.md)

Two new major sections:

**Function Templates:**
- Creating and managing templates
- Variable substitution
- Template versioning
- Examples for common patterns

**Sub-Orchestration:**
- Calling templates as sub-orchestrations
- Inline graph invocation
- Parallel execution with when_all/when_any
- Composition patterns
- Real-world examples (order processing, ETL, etc.)

## Key Design Decisions

### Why Templates Instead of Function Definitions?

1. **Variable Support**: Templates support `{variable}` placeholders, enabling true parameterization
2. **Versioning**: Templates track versions when DSL changes, function definitions did not
3. **Audit Trail**: Templates record creator and creation time
4. **Consistency**: One concept instead of two overlapping ones
5. **Richer Metadata**: Templates support descriptions and can be filtered by various criteria

### Backward Compatibility

This is a new feature, so there are no backward compatibility concerns. The old `df.define()`/`df.undefine()` from PR #54 were never merged to main.

### Duroxide Integration

Sub-orchestrations leverage duroxide's existing capabilities:
- `schedule_sub_orchestration()` - Schedule child orchestrations
- `join()` - Wait for multiple futures (used by when_all)
- `select_any()` - Race between multiple futures (used by when_any)

The existing `SUBTREE_NAME` orchestration is reused to execute individual nodes.

## Testing Strategy

### Unit Tests (Future Work)
- Template CRUD operations
- Variable substitution
- Template versioning

### E2E Tests (Completed)
- Template lifecycle (create, start, update, drop)
- Sub-orchestration invocation (template and inline)
- Parallel execution (when_all, when_any)
- Concurrency limits
- Error handling

### Integration Tests (Future Work)
- Template variables with global/local precedence
- Sub-orchestration with nested calls
- Error propagation from children to parents

## Migration Path

Since neither PR #41 nor PR #54 have been merged to main yet, there is no migration needed. Users will start with the unified template-based approach.

## Future Enhancements

1. **Template Library**: Curated collection of common templates
2. **Template Composition**: Templates that reference other templates
3. **Template Validation**: Syntax checking before creation
4. **Template Analytics**: Usage statistics per template
5. **Template Permissions**: Row-level security for templates

## Files Changed

```
src/templates.rs                                 +373 (new)
src/lib.rs                                       +43
src/dsl.rs                                       +238
src/orchestrations/execute_function_graph.rs     +169
tests/e2e/sql/26_templates.sql                   +202 (new)
tests/e2e/sql/27_sub_orchestration_templates.sql +143 (new)
tests/e2e/sql/28_when_all_when_any.sql           +209 (new)
USER_GUIDE.md                                    +307

Total: 1,679 additions across 8 files
```

## Review Checklist

- [x] Templates module implements all CRUD operations
- [x] Schema includes df.templates table with proper constraints
- [x] Sub-orchestration functions (call, when_all, when_any) implemented
- [x] Orchestration handlers for new node types
- [x] Comprehensive E2E tests covering all features
- [x] Documentation with examples and use cases
- [x] Table of contents updated
- [ ] Code compiles without warnings (blocked by auth issue)
- [ ] Tests pass (blocked by auth issue)

## Known Issues

Build is currently blocked by authentication to private git dependency `duroxide-pg-opt`. This will need to be resolved by:
1. CI with proper credentials configured
2. Actions setup steps to authenticate before build
3. Or adding to repository allowlist

The code has been carefully reviewed for:
- Rust syntax correctness
- SQL syntax in extension_sql! blocks
- Consistent error handling
- Proper use of pgrx APIs
- Following existing code patterns

Once authentication is resolved, the code should build cleanly.
