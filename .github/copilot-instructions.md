# pg_durable AI Coding Instructions

## Architecture Overview

pg_durable is a **PostgreSQL extension** (pgrx/Rust) providing durable SQL function execution. Everything runs inside the PostgreSQL server—no external services.

**Two execution contexts:**
1. **Backend processes** (user sessions): Build function graphs via DSL operators (`~>`, `|=>`, `&`, `|`)
2. **Background worker**: Executes graphs durably via [duroxide](https://github.com/microsoft/duroxide) runtime

**Data flow:** User calls `df.start()` → nodes saved to `df.nodes` → instance queued → background worker picks up → duroxide orchestration executes nodes → results in `df.instances`

## Key Files & Modules

| Path | Purpose |
|------|---------|
| [src/lib.rs](../src/lib.rs) | Extension entry, schema/table definitions, SQL operators |
| [src/dsl.rs](../src/dsl.rs) | DSL functions: `df.sql()`, `df.seq()`, `df.if()`, `df.loop()` |
| [src/worker.rs](../src/worker.rs) | Background worker setup, duroxide runtime initialization, and duroxide schema migration (`ApplyAll`) |
| [src/orchestrations/](../src/orchestrations/) | Duroxide orchestrations (⚠️ deterministic code only) |
| [src/activities/](../src/activities/) | Duroxide activities (I/O happens here) |
| [src/types.rs](../src/types.rs) | Core types: `Durofut`, `FunctionGraph`, `FunctionNode` |
| [tests/e2e/sql/](../tests/e2e/sql/) | SQL-based E2E tests (numbered, run sequentially) |
| [sql/pg_durable--0.1.1.sql](../sql/pg_durable--0.1.1.sql) | First version install SQL fixture (for upgrade testing) |
## Development Commands

```bash
# Build extension
cargo build                    # or: make build

# Run unit tests (pgrx)
./scripts/test-unit.sh         # uses: cargo pgrx test pg17

# Run E2E tests locally
./scripts/test-e2e-local.sh              # all tests
./scripts/test-e2e-local.sh --verbose    # -v, shows test output, use with filtering
./scripts/test-e2e-local.sh 04_parallel  # filter/specific test
./scripts/test-e2e-local.sh --keep       # keep server running for debugging

# Run upgrade tests (schema comparison + backward compat)
./scripts/test-upgrade.sh                # test upgrade from previous version
./scripts/test-upgrade.sh --verbose      # show detailed diff on failure

# Connect to test database (after --keep)
~/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -d postgres

# View background worker logs, do this especially when debugging E2E tests
tail -f ~/.pgrx/17.log

# Stop test server
./scripts/pg-stop.sh
```

## Critical Patterns

### Orchestrations Must Be Deterministic
Files in `src/orchestrations/` must be 100% deterministic—no I/O, no `Utc::now()`, no random numbers. All side effects go through activities.

### Activity Naming Convention
Each activity has a co-located `NAME` constant for IDE navigation:
```rust
// src/activities/execute_sql.rs
pub const NAME: &str = "pg_durable::activity::execute-sql";
```

### DSL Creates Graph Nodes
DSL functions like `df.sql()` insert rows into `df.nodes`. The `Durofut` struct represents a node reference passed between operators.

### E2E Test Structure
Tests in `tests/e2e/sql/` follow this pattern:
1. Create temp state table, call `df.start()`
2. Poll `df.status()` in a loop until completed/failed
3. Assert results, raise exception on failure
4. Cleanup and output `SELECT 'TEST PASSED'`

### Binary Backward Compatibility
The new `.so` must work against **all** previous versions' schemas (same major version) because customers may never run `ALTER EXTENSION UPDATE`. When changing SQL queries in Rust code, ensure they work against both old and new schemas (see [docs/upgrade-testing.md](../docs/upgrade-testing.md)). CI enforces this via `scripts/test-upgrade.sh`.

## Common Tasks

**Adding a new DSL function:** Add to [src/dsl.rs](../src/dsl.rs) with `#[pg_extern(schema = "df")]`

**Adding a new activity:** Create file in `src/activities/`, add `pub const NAME`, register in [src/registry.rs](../src/registry.rs)

**Adding E2E test:** Create numbered SQL file in `tests/e2e/sql/`, follow existing pattern (see [02_sequence.sql](../tests/e2e/sql/02_sequence.sql))

**Changing the `df` extension schema:** If the upgrade script doesn't exist yet, follow the "Preparing for the next version" section in [docs/upgrade-testing.md](../docs/upgrade-testing.md). Then: add DDL to the upgrade script (`sql/pg_durable--<prev>--<current>.sql`), ensure `.so` backward compat with all previous schemas, and add a section to "Version-Specific Changes" in [docs/upgrade-testing.md](../docs/upgrade-testing.md). Note: duroxide schema changes do not require extension upgrade script changes — the BGW applies them automatically at startup.

For Scenario A, treat the upgrade path as the contract for already-shipped versions: before release, fresh install for the new version should match what an existing customer gets by installing the previous version and applying the upgrade chain.

**Updating duroxide-pg-opt dependency**: Update the submodule (`cd duroxide-pg-opt && git fetch && git checkout <new-ref>`), then rebuild. The BGW's embedded migration files update automatically via `include_dir!`. No changes to extension SQL, upgrade scripts, or any checked-in SQL copies are needed.

**Writing a spec or design doc:** Include an "Upgrade & Migration" section covering: backward compatibility impact (B1 — will the new `.so` work against all previous schemas?), upgrade script DDL needed, and any runtime schema detection required. See [docs/upgrade-testing.md](../docs/upgrade-testing.md) for the full upgrade testing strategy.

## Dependencies

- **pgrx 0.16.1**: PostgreSQL extension framework (pinned version)
- **duroxide**: Durable execution runtime
- **duroxide-pg-opt**: duroxide provider/stores engine state in PostgreSQL (git submodule)
- **sqlx**: Async PostgreSQL from background worker
- **tokio**: Async runtime for background worker

---

## Development Workflow Guidelines

### Before Committing

1. **Clean warnings**: Run `cargo build --features pg17` and `cargo clippy --features pg17` — fix all warnings
2. **Format code**: Run `cargo fmt`
3. **Run tests**: `./scripts/test-unit.sh` then `./scripts/test-e2e-local.sh`

### Handling Unused Code Warnings

- **DO NOT** add `#[allow(unused)]` without understanding why
- **DO NOT** prefix with `_` just to silence warnings
- **DO** investigate if code is used in feature gates or tests
- **DO** delete genuinely unused code
- **DO** use `_name` only for trait-required but unused parameters

### After Code Changes: Update Docs & Tests

1. Run `git diff` to identify what changed
2. For new DSL functions → add E2E test in `tests/e2e/sql/`
3. For new operators → test both operator and function variants
4. Update `USER_GUIDE.md` if API surface changed

### Creating E2E Tests

**File naming**: `tests/e2e/sql/NN_<feature_or_scenario>.sql`

**Required structure**:
```sql
-- Setup: create temp tables and test data
DROP TABLE IF EXISTS test_foo;
CREATE TABLE test_foo (...);

-- Start the durable function
CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state SELECT df.start(
    'your DSL expression here',
    'test-label'
);

-- Poll until complete (30s timeout)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
END $$;

-- Cleanup
DROP TABLE _test_state;
DROP TABLE test_foo;
SELECT 'TEST PASSED' AS result;
```

### Merging to Main

1. Verify all tests pass (unit + E2E + upgrade)
2. Use descriptive commit messages in imperative mood
3. **DO NOT** use `--force` or skip hooks with `--no-verify`
4. After merge, optionally deploy: `./scripts/deploy-acr.sh`

### CI/CD Pipeline

Pull requests automatically run the CI workflow (`.github/workflows/ci.yml`):

1. **Format Check**: `cargo fmt --check`
2. **Clippy & Tests**: `cargo clippy`, `cargo pgrx test pg17`, and `./scripts/test-e2e-local.sh`
3. **Upgrade Tests**: `./scripts/test-upgrade.sh` (schema comparison + backward compat)

All checks must pass before a PR can be merged. Configure branch protection rules in GitHub to enforce this.

### ⚠️ IMPORTANT: Git Operations

**DO NOT** commit, merge, or push without asking the user first. Always present the proposed changes and get explicit approval before any git operations.
