# pg_durable Terminology Migration Guide

**For LLMs building on pg_durable**

This document summarizes the terminology changes in pg_durable. If you have existing code or prompts, update them according to this guide.

---

## Summary

The feature previously called "Durable Orchestrations" is now called **"Durable SQL Functions"**.

---

## Terminology Changes

| Old Term | New Term |
|----------|----------|
| orchestration | durable function (or just "function") |
| workflow | durable function |
| orchestration graph | function graph |
| orchestration node | function node |
| Start an orchestration | Start a durable function |
| orchestration_name (column) | **function_name** |
| orchestration_version (column) | **function_version** |
| OrchestrationGraph (Rust) | FunctionGraph |
| OrchestrationNode (Rust) | FunctionNode |
| OrchestrationInput (Rust) | FunctionInput |

---

## Breaking API Changes

### Monitoring Function Columns

**`durable.list_instances()`** - Column renamed:
```sql
-- Old
SELECT instance_id, label, orchestration_name, status FROM durable.list_instances();

-- New  
SELECT instance_id, label, function_name, status FROM durable.list_instances();
```

**`durable.instance_info()`** - Columns renamed:
```sql
-- Old
SELECT orchestration_name, orchestration_version FROM durable.instance_info('id');

-- New
SELECT function_name, function_version FROM durable.instance_info('id');
```

---

## Internal Code Changes (Rust)

### Struct Renames in `src/types.rs`

```rust
// Old
pub struct OrchestrationNode { ... }
pub struct OrchestrationGraph { ... }
pub struct OrchestrationInput { ... }

// New
pub struct FunctionNode { ... }
pub struct FunctionGraph { ... }
pub struct FunctionInput { ... }
```

### Function Renames in `src/runtime.rs`

```rust
// Old
pub fn start_duroxide_orchestration(...) -> ...
pub fn cancel_duroxide_orchestration(...) -> ...
async fn execute_orchestration_node(...) -> ...

// New
pub fn start_durable_function(...) -> ...
pub fn cancel_durable_function(...) -> ...
async fn execute_function_node(...) -> ...
```

### Activity Renames

```rust
// Old
"LoadOrchestrationGraph"

// New
"LoadFunctionGraph"
```

---

## Documentation Updates

| File | Changes |
|------|---------|
| `README.md` | Tagline, feature descriptions |
| `USER_GUIDE.md` | All sections, examples, TOC |
| `docs/pg_durable_mvp.md` | All references |

---

## What Stayed the Same

- **SQL DSL functions**: `durable.sql()`, `durable.start()`, `durable.if()`, etc.
- **Operators**: `~>`, `|=>`
- **Table names**: `durable.nodes`, `durable.instances`
- **Instance IDs**: Still 8-character hex
- **Duroxide internal API**: `start_orchestration()` calls unchanged (Duroxide's API)

---

## Migration Checklist

If you're updating code that uses pg_durable:

1. [ ] Update SQL queries that reference `orchestration_name` → `function_name`
2. [ ] Update SQL queries that reference `orchestration_version` → `function_version`
3. [ ] Update any documentation or comments referencing "orchestration"
4. [ ] If using Rust internals, update struct references

---

## Version

This migration applies to pg_durable versions after commit `1212f9d` (December 2025).

