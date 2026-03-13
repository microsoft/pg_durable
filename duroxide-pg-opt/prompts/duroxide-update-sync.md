# Duroxide Upstream Update Sync

**Purpose:** Prompt for syncing duroxide-pg-opt with upstream duroxide changes.

---

## Important Guidelines

> **DO NOT** push to any remote git repository or publish to crates.io unless explicitly asked by the user.
> 
> **DO** ask the user for confirmation before:
> - Pushing commits to remote branches
> - Creating pull requests  
> - Publishing to crates.io
> - Any other action that affects external systems
>
> When in doubt about how to proceed, **ask the user** for guidance.

---

## When to Use

Use this prompt when:
- A new version of duroxide has been released
- You need to check for breaking changes or new features affecting the provider
- You want to ensure compatibility with the latest duroxide version

---

## Instructions for AI Agent

Perform the following steps in order:

### Step 1: Check Current Version

```bash
grep -A2 'duroxide' Cargo.toml
```

Note the current version specification.

### Step 2: Check for New Releases

```bash
gh release list --repo microsoft/duroxide --limit 5
```

### Step 3: Update Dependency

```bash
cargo update duroxide && cargo fetch
```

### Step 4: Locate New Source

```bash
find ~/.cargo/registry/src -type d -name "duroxide-*" | sort -V | tail -1
```

### Step 5: Read CHANGELOG.md

Read the CHANGELOG.md from the duroxide source to understand what changed:

```bash
cat $(find ~/.cargo/registry/src -type d -name "duroxide-*" | sort -V | tail -1)/CHANGELOG.md
```

**Key things to look for:**
- Breaking changes to `Provider` or `ProviderAdmin` traits
- New trait methods that need implementation
- Changes to `WorkItem`, `Event`, or `ProviderError` types
- New validation tests in `provider_validations`
- Changes to stress test infrastructure
- Memory optimizations or API changes

### Step 6: Read Provider Implementation Guide

```bash
cat $(find ~/.cargo/registry/src -type d -name "duroxide-*" | sort -V | tail -1)/docs/provider-implementation-guide.md
```

**Key things to compare:**
- New required trait methods
- Updated signatures for existing methods
- New error handling requirements
- Schema changes needed
- Instance creation or locking behavior changes

### Step 7: Read Provider Testing Guide

```bash
cat $(find ~/.cargo/registry/src -type d -name "duroxide-*" | sort -V | tail -1)/docs/provider-testing-guide.md
```

**Key things to check:**
- New validation tests to add
- Updated test counts (e.g., "92 tests" → "95 tests")
- Changes to `ProviderFactory` or `ProviderStressFactory` traits
- New stress test scenarios

### Step 8: Verify Build

```bash
cargo build
```

Check for:
- Compilation errors indicating breaking changes
- Missing trait implementations
- Type mismatches

If code changes are needed, implement them. If migrations are needed:
1. Create new migration file `migrations/NNNN_description.sql`
2. Create companion diff file `migrations/NNNN_diff.md` — each changed function must be shown **in full** with `+`/`-` diff markers (not small-context unified diff). See [migrations/0004_diff.md](../migrations/0004_diff.md) for format.
3. **Note:** `0001_initial_schema.sql` is the baseline schema; avoid modifying it

### Step 9: Sync E2E Tests from Duroxide Main Repo

**IMPORTANT:** Check for new or changed e2e tests in the duroxide main repo ([github.com/microsoft/duroxide](https://github.com/microsoft/duroxide/tree/main/tests)) and copy them.

Use the GitHub MCP tools to fetch test file contents from the duroxide repo's `tests/e2e_samples.rs` and `tests/session_e2e_tests.rs`, then compare with local tests:

```bash
# List local tests
grep -o 'async fn [a-z_0-9]*' tests/e2e_samples.rs | sort
grep -o 'async fn [a-z_0-9]*' tests/session_e2e_tests.rs | sort
```

Compare against the lists from the duroxide repo (fetched via GitHub).

When copying tests from the duroxide main repo to this provider repo:
- Replace `common::create_sqlite_store_disk()` → `common::create_postgres_store()`
- Replace `create_runtime(activities, orchestrations)` → `Runtime::start_with_store(store.clone(), activities, orchestrations)`
- Replace `create_runtime_with_options(activities, orchestrations, options)` → `Runtime::start_with_options(store.clone(), activities, orchestrations, options)`
- Add `common::cleanup_schema(&schema).await;` after `rt.shutdown(None).await;`
- Increase short timeouts (5s/10s) to 30s for PostgreSQL latency
- For tests with `max_sessions_per_runtime: 1`, add `dispatcher_long_poll_timeout: Duration::from_secs(2)` to prevent capacity-blocked slots from sleeping for the full long-poll timeout
- Add any new imports (`semver::Version`, `std::sync::atomic::*`, etc.)

> ⚠️ **Do not skip this step.** Provider e2e tests must stay in sync with the main repo to ensure feature parity.

### Step 10: Run ALL Tests

**IMPORTANT:** Run the complete test suite, not just validation tests.

```bash
cargo nextest run
```

This runs:
- Provider validation tests (`postgres_provider_test.rs`) 
- E2E sample tests (`e2e_samples.rs`)
- Basic tests (`basic_tests.rs`)
- Regression tests (`regression_tests.rs`)
- Long-poll tests (`longpoll_tests.rs`)
- Multi-node tests (`multi_node_tests.rs`)
- Any other test files

Check for:
- Compilation errors from API changes (e.g., renamed methods)
- New tests that need wrappers added
- Failing tests indicating behavioral changes
- Removed tests that should be cleaned up

If tests fail due to breaking changes (like renamed APIs), fix them before proceeding.

### Step 11: Search for STOPGAP Markers

```bash
grep -rn "STOPGAP\|BLOCKED\|TODO.*duroxide" --include="*.rs" .
```

For each marker, check if the related issue is now fixed and if cleanup can be performed.

### Step 12: Generate Summary Report

After completing the above, provide a summary with:

1. **Version Change:** `X.Y.Z` → `A.B.C`
2. **Breaking Changes:** List any breaking changes affecting this provider
3. **Code Changes Made:** Any fixes applied (e.g., API renames)
4. **New Features:** Features that could be leveraged
5. **New Tests:** New validation tests to add (with count)
6. **Test Results:** Full test suite results (passed/failed/skipped)
7. **Action Items:** Prioritized list of remaining tasks

---

## Provider Trait Changes Checklist

When duroxide updates the Provider trait:

1. **New methods added:**
   - [ ] Implement in `src/provider.rs`
   - [ ] Add corresponding stored procedure in `migrations/` if needed
   - [ ] Create migration diff file (`NNNN_diff.md`)

2. **Method signature changes:**
   - [ ] Update implementation in `src/provider.rs`
   - [ ] Update stored procedure if return type changed
   - [ ] Check all usages in tests

3. **New validation tests:**
   - [ ] Add to `tests/postgres_provider_test.rs`
   - [ ] Use `provider_validation_test!` macro

4. **API renames (like `utcnow()` → `utc_now()`):**
   - [ ] Update all test files that use the renamed API
   - [ ] Check `tests/e2e_samples.rs` and other test files

---

## Example Summary Template

```markdown
## Duroxide Update Summary

**Version Change:** 0.1.11 → 0.1.13

### Breaking Changes
- `utcnow()` renamed to `utc_now()` (Rust naming convention)

### Code Changes Made
- Fixed `tests/e2e_samples.rs`: `ctx.utcnow()` → `ctx.utc_now()`

### New Features
- System calls reimplemented as regular activities
- Reserved activity prefix `__duroxide_syscall:`

### New Validation Tests
- Count: 102 (unchanged from previous)
- New tests: None

### Test Results
- **Total:** 212 tests
- **Passed:** 212 ✅
- **Failed:** 0
- **Skipped:** 20 (stress/perf tests)

### Action Items
1. ✅ Update Cargo.lock (done)
2. ✅ Fix breaking API changes (done)
3. ⏳ Bump duroxide-pg-opt version
4. ⏳ Update CHANGELOG.md
```

---

## Quick Reference

```bash
# Check duroxide version in Cargo.lock
grep -A1 'name = "duroxide"' Cargo.lock | head -2

# Find all duroxide trait implementations
grep -n "impl.*Provider.*for PostgresProvider" src/provider.rs

# Count validation tests
grep -c "provider_validation_test" tests/postgres_provider_test.rs

# Run specific test module
cargo nextest run atomicity_tests

# Run all tests (RECOMMENDED)
cargo nextest run

# Run just validation tests
cargo nextest run --test postgres_provider_test

# Quick version check without full sync
cargo update duroxide --dry-run 2>&1 | grep duroxide

# Search for workarounds that might be cleanable
grep -rn "STOPGAP\|BLOCKED\|TODO.*duroxide" --include="*.rs" .
```
