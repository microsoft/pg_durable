# Clean Up Compiler and Linter Warnings

## Objective
Eliminate all compiler warnings, clippy lints, and formatting issues across the pg_durable codebase without taking shortcuts.

## Scope
- Main library (`src/`)
- All modules (`src/types.rs`, `src/dsl.rs`, `src/runtime.rs`, `src/monitoring.rs`, `src/explain.rs`)
- Test code in `src/lib.rs`

## Tools to Run

### 1. Cargo Build
```bash
cargo build --features pg17
```

Look for:
- Unused imports
- Unused variables
- Unused functions/types
- Dead code
- Deprecated API usage

### 2. Cargo Clippy
```bash
cargo clippy --features pg17
```

Common clippy warnings to address:
- `needless_lifetimes` - Remove unnecessary explicit lifetimes
- `derivable_impls` - Replace manual `impl Default` with `#[derive(Default)]`
- `question_mark` - Use `?` operator instead of manual error checking
- `redundant_pattern_matching` - Simplify match expressions
- `manual_map` - Replace match with `.map()`
- `useless_conversion` - Remove `.into()` when type already matches

### 3. Cargo Format
```bash
cargo fmt
```

Ensures consistent formatting across all code.

### 4. PGRX Tests
```bash
cargo pgrx test --features pg17
```

Ensures all pgrx tests compile and pass.

## Handling Unused Code

### ❌ DO NOT
- Add `#[allow(unused)]` or `#[allow(dead_code)]` without understanding why
- Prefix variables with `_` to silence warnings unless they're truly meant to be ignored
- Remove code that's part of public API or used in feature-gated code
- Remove error handling just to simplify code

### ✅ DO
1. **Investigate first**: Understand why the code is unused
2. **Check feature gates**: Code might be used under `#[cfg(feature = "...")]`
3. **Check tests**: Code might only be used in test scenarios
4. **Remove genuinely unused code**: If it's truly not needed, delete it
5. **For intentionally unused parameters**: Use `_name` pattern when the parameter is required by a trait but not used in a specific implementation

## Example Workflow

```bash
# 1. Build and capture warnings
cargo build --features pg17 2>&1 | tee build-warnings.txt

# 2. Run clippy
cargo clippy --features pg17 2>&1 | tee clippy-warnings.txt

# 3. Review warnings
cat build-warnings.txt | grep "warning:"
cat clippy-warnings.txt | grep "warning:"

# 4. Fix warnings iteratively
# ... make fixes ...

# 5. Verify fixes
cargo build --features pg17
cargo clippy --features pg17

# 6. Format
cargo fmt

# 7. Test everything still works
cargo pgrx test --features pg17
```

## Common Warning Fixes

### 1. Unused Import
```rust
// ❌ Before
use std::collections::HashMap;  // warning: unused import

// ✅ After - Remove if truly unused
// (import removed)
```

### 2. Unused Variable
```rust
// ❌ Wrong fix
let _result = expensive_operation();  // Misleading - operation still runs

// ✅ Correct - If value is genuinely not needed, remove the binding
expensive_operation();

// ✅ Correct - If required by trait but unused in this impl
fn process(&self, _ctx: Context) { }  // Trait requires ctx parameter
```

### 3. Dead Code
```rust
// If function is truly unused:
// ❌ Don't suppress
#[allow(dead_code)]
fn unused_helper() { }

// ✅ Remove it
// (function removed)

// If used in tests:
// ✅ Add appropriate cfg
#[cfg(test)]
fn test_helper() { }
```

### 4. Clippy: Question Mark
```rust
// ❌ Before
if result.is_err() {
    return result;
}

// ✅ After
result?;
```

## PGRX-Specific Considerations

### Extension SQL
The `extension_sql!` macro generates SQL that PostgreSQL executes. Warnings about unused items inside these blocks may be false positives.

### Background Workers
Code in the background worker (`src/runtime.rs`) runs in a separate PostgreSQL process. Ensure you test with:
```bash
./scripts/test-e2e-local.sh
```

### Schema Functions
Functions decorated with `#[pg_extern(schema = "df")]` are called from SQL, not Rust. They may appear unused to the compiler but are essential.

## Validation Checklist

Before considering the cleanup complete:

- [ ] `cargo build --features pg17` produces zero warnings
- [ ] `cargo clippy --features pg17` produces zero warnings
- [ ] `cargo fmt --check` produces no diff
- [ ] `cargo pgrx test --features pg17` passes completely
- [ ] `./scripts/test-e2e-local.sh` passes all tests
- [ ] Spot-check: Run a few E2E tests to ensure they work

## When to Ask

Stop and ask the user if:
- You need to remove a large amount of code (>100 lines)
- Warning fix requires changing public API (SQL functions)
- You're unsure if code is used in production scenarios
- Fix would require significant refactoring

## Anti-Patterns

**Don't do these:**
- Blindly adding `#[allow(dead_code)]` everywhere
- Prefixing everything with `_` to silence warnings
- Removing error handling to eliminate unused Result
- Deleting code you don't understand
- Changing SQL APIs just to reduce warnings

