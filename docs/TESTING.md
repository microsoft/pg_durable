# pg_durable Testing Guide

This guide covers all testing scenarios for pg_durable.

## Quick Reference

| What | Command |
|------|---------|
| Unit tests | `./scripts/test-unit.sh` |
| pg_regress tests | `make test-regress` |
| E2E tests (local) | `./scripts/test-e2e-local.sh` |
| E2E tests (Docker) | `./scripts/test-e2e-docker.sh` |
| Stop PostgreSQL | `./scripts/pg-stop.sh` |
| Deploy to ACR | `./scripts/deploy-acr.sh` |

## Test Suites Overview

pg_durable has **three test suites**:

1. **Unit Tests** — Rust tests using pgrx (`#[pg_test]`)
2. **pg_regress Tests** — Standard PostgreSQL regression tests (deterministic, fast)
3. **E2E Tests** — Comprehensive scenario tests with Docker (complex scenarios)

### When to Use Each Suite

| Suite | Use For | Characteristics |
|-------|---------|-----------------|
| Unit | Testing individual Rust functions | Fast, isolated |
| pg_regress | Core DSL operators/functions | Deterministic, standard PostgreSQL testing |
| E2E | Complex scenarios, HTTP, timing | Comprehensive, may include variable timing |

---

## 1. Unit Tests (pgrx)

Runs Rust unit tests using `cargo pgrx test`. These test individual functions in isolation.

```bash
# Run all unit tests
./scripts/test-unit.sh

# Run tests matching a pattern
./scripts/test-unit.sh simple
```

**What it does:**
- Compiles the extension
- Starts a temporary PostgreSQL instance
- Runs `#[pg_test]` annotated functions
- Cleans up automatically

---

## 2. pg_regress Tests

Standard PostgreSQL regression tests for core DSL functionality. These tests are fast, deterministic, and use PostgreSQL's industry-standard testing framework.

```bash
# Run all pg_regress tests (resets PostgreSQL, installs extension, runs tests)
make test-regress

# Or if PostgreSQL is already running with PGDATABASE=contrib_regression:
make installcheck

# Run specific test
make installcheck REGRESS=simple

# View test output
cat regression.out

# View diffs (on failure)
cat regression.diffs
```

**What it tests:**
- Core DSL operators: `~>`, `|=>`, `&`, `?>`, `!>`
- DSL functions: `df.sql()`, `df.seq()`, `df.as()`, `df.join()`, `df.if()`
- Helper functions: `df.wait_for_completion()`

**Key features:**
- Deterministic output (no UUIDs, timestamps, or variable timing)
- Fast feedback (< 10 seconds for all tests)
- Standard PostgreSQL testing approach
- Familiar to PostgreSQL developers

Test SQL files are in `sql/`, expected output in `expected/`, and PGXS is configured in the root `Makefile`.

---

## 3. E2E Tests

End-to-end tests that exercise the full system including the background worker.

### 3a. Local E2E Tests

Fast iteration using local pgrx PostgreSQL. Best for development.

```bash
# Run all tests (starts/stops server automatically)
./scripts/test-e2e-local.sh

# Run specific test
./scripts/test-e2e-local.sh 04_parallel

# Run only the phases that share the standard build artifact
./scripts/test-e2e-local.sh --default-build-phases

# Run test multiple times (stability check)
./scripts/test-e2e-local.sh 04_parallel 5

# Keep server running after tests (for investigation)
./scripts/test-e2e-local.sh --keep

# Start fresh (wipe database)
./scripts/test-e2e-local.sh --clean
```

**Investigation mode (`--keep`):**
```bash
# Run tests, keep server running
./scripts/test-e2e-local.sh --keep 04_parallel

# Connect to database
~/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -d postgres

# View logs
tail -f ~/.pgrx/17.log

# When done, stop server
./scripts/pg-stop.sh
```

### 3b. Docker E2E Tests

Tests in a linux/amd64 container. Runs all the local e2e tests that don't require special settings.

```bash
# Run all tests (builds image if needed)
./scripts/test-e2e-docker.sh

# Run specific test
./scripts/test-e2e-docker.sh 04_parallel

# Run test multiple times
./scripts/test-e2e-docker.sh 04_parallel 5

# Keep container running after tests
./scripts/test-e2e-docker.sh --keep

# Force rebuild image
./scripts/test-e2e-docker.sh --rebuild
```

> ⚠️ **Important**: If you change Rust code (`src/`), you must use `--rebuild` to rebuild the Docker image. Test SQL file changes are picked up automatically.

Docker intentionally skips `00_requires_shared_preload.sql` and connection-limit tests `44` through `46`. Use `./scripts/test-e2e-local.sh` for the full phased SQL E2E coverage.

**Investigation mode (`--keep`):**
```bash
# Run tests, keep container running
./scripts/test-e2e-docker.sh --keep

# Connect to database
docker exec -it pg_durable_e2e psql -U postgres

# View logs
docker logs -f pg_durable_e2e

# When done, stop container
./scripts/pg-stop.sh --docker
```

---

## Stopping Servers

```bash
# Stop local PostgreSQL
./scripts/pg-stop.sh

# Stop Docker container
./scripts/pg-stop.sh --docker

# Stop both
./scripts/pg-stop.sh --all
```

---

## Deploying to ACR

After running Docker E2E tests, deploy the same image to Azure Container Registry:

```bash
# Login to ACR (one time)
az acr login --name ${ACR_REGISTRY%%.*}

# Deploy existing image (fast - no rebuild)
./scripts/deploy-acr.sh

# Deploy with specific tag
./scripts/deploy-acr.sh --tag v0.1.0

# Force rebuild and deploy
./scripts/deploy-acr.sh --rebuild
```

---

## Test Files

Tests are in `tests/e2e/sql/`:

| File | Description |
|------|-------------|
| `00_setup_playground.sql` | Creates test schema and data |
| `01_simple_sql.sql` | Basic SQL execution |
| `02_sequence.sql` | Sequential execution (`~>`) |
| `03_variables.sql` | Variable substitution (`\|=>`) |
| `04_parallel_join.sql` | Parallel execution (`durable.join`) |
| `05_conditional_true.sql` | Conditional (true branch) |
| `06_conditional_false.sql` | Conditional (false branch) |
| `07_sleep.sql` | Timer/delay |
| `08_loop_cancel.sql` | Loop and cancellation |
| `09_monitoring.sql` | Monitoring functions |
| `10_explain.sql` | Visualization |
| `11-16_scenario_*.sql` | User guide scenarios |

---

## Writing New Tests

Create a new `.sql` file in `tests/e2e/sql/`:

```sql
-- Test: Description
-- Expected: What should happen

-- Start function (auto-commits, visible to background worker)
SELECT durable.start(
    'SELECT 42',
    'test-label'
);

-- Wait for completion
SELECT pg_sleep(2);

-- Verify result
DO $$
DECLARE
    inst_status TEXT;
BEGIN
    SELECT status INTO inst_status 
    FROM durable.instances 
    WHERE label = 'test-label';
    
    IF lower(inst_status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', inst_status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED';
END $$;

SELECT 'TEST PASSED' AS result;
```

**Important:** `durable.start()` must be a standalone SELECT (not inside DO block) so it auto-commits and the background worker can see the instance.

---

## Troubleshooting

### Tests stuck in "pending"

The instance wasn't committed before the background worker looked for it. Make sure `durable.start()` is outside any DO block.

### Can't see duroxide logs

Restart with logging:
```bash
~/.pgrx/17.*/pgrx-install/bin/pg_ctl -D ~/.pgrx/data-17 -l ~/.pgrx/17.log restart
```

### Extension changes not taking effect

Rebuild and restart:
```bash
cargo pgrx install --pg-config=$(ls ~/.pgrx/17.*/pgrx-install/bin/pg_config)
~/.pgrx/17.*/pgrx-install/bin/pg_ctl -D ~/.pgrx/data-17 restart
```

### Docker build fails

Check Docker is running and has enough resources. Try:
```bash
docker system prune -f
./scripts/test-e2e-docker.sh --rebuild
```

