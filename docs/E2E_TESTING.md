# E2E Testing Guide for pg_durable

This guide explains how to set up and run end-to-end tests for pg_durable.

## Prerequisites

1. **Docker** - Required to run the test container
   ```bash
   # Verify Docker is installed and running
   docker --version
   docker ps
   ```

2. **Rust toolchain** - For building the extension
   ```bash
   # Install via rustup if needed
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   ```

## Quick Start

From the project root:

```bash
# Run all E2E tests
./scripts/test-e2e-local.sh
```

That's it! The script will:
1. Build and install the extension into the local pgrx PostgreSQL
2. Start PostgreSQL in the required phase configuration
3. Wait for the background worker to be ready
4. Run the matching SQL test files
5. Report results by phase
6. Stop PostgreSQL unless `--keep` was requested

## What Gets Tested

The test suite is organized into 23 files. Files `01`–`09` open with `SET SESSION AUTHORIZATION df_e2e_user` so the test logic runs as a non-privileged user. Files `10`–`16` run as `postgres` throughout and use inline `SET SESSION AUTHORIZATION` where needed.

### Setup & Special

| File | Description |
|------|-------------|
| `00_setup_playground.sql` | Shared test infrastructure — creates `playground.*` tables and helper functions (not a test) |
| `00_requires_shared_preload.sql` | Verifies that the extension requires `shared_preload_libraries`; runs in `--no-preload` phase only |

### Non-Privileged Tests (runs as `df_e2e_user`)

| File | Description |
|------|-------------|
| `01_core_primitives.sql` | `df.sql()`, `~>` sequence, `df.join()` / `&`, `df.sleep()`, `df.join3()`, `df.race()` / `\|` |
| `02_conditionals.sql` | `df.if()` / `?>` / `!>` true & false branches, `condition_node` validation, `df.if_rows()` |
| `03_loops.sql` | `df.loop()` / `@>` with `df.cancel()`, `df.break()` / `^?>` with while-condition |
| `04_variables_and_results.sql` | `\|=>` / `df.as()`, `df.setvar()` / `df.getvar()` / `{var}` templates, dot-notation (`$name.col`), `$name.*` expansion, result-name validation |
| `05_monitoring_and_explain.sql` | `df.list_instances()`, `df.instance_info()`, `df.status()`, `df.result()`, `df.explain()` dry-run and live modes |
| `06_http_and_ssrf.sql` | HTTP allow-list enforcement, SSRF protection (metadata endpoints, localhost, file://, bare IPs); requires `--features http` |
| `07_signals.sql` | `df.signal()` — send signals to a running workflow from within the polling loop |
| `08_scenarios.sql` | End-to-end workflow scenarios using `playground.*` tables (ETL, parallel counts, conditional load, order processing, three-step) |
| `09_graph_and_validation.sql` | `df.explain()` graph reuse, invalid `node_type` rejection |

### Superuser Tests (runs as `postgres`)

| File | Description |
|------|-------------|
| `10_connection_limits.sql` | `pg_durable.max_user_connections` defaults — concurrent workflows |
| `11_cross_connection.sql` | `df.signal()` / `df.cancel()` / `df.status()` via dblink from a separate backend; transaction commit/rollback semantics |
| `12_extension_lifecycle.sql` | BGW init after `CREATE EXTENSION`, schema cleanup after `DROP`, security: non-superuser block, pre-existing schema block |
| `13_user_isolation.sql` | Superuser-only queries, two-user table isolation, `SET ROLE`, SECURITY DEFINER, dropped-role error |
| `14_database.sql` | Wrong-database `CREATE EXTENSION` rejection; `df.start(query, label, database)` multi-database routing |
| `15_rls.sql` | RLS on `df.instances` / `df.nodes` / `df.vars` — per-user visibility, cross-user cancel/signal denied, column-level UPDATE, superuser bypass, per-user variable isolation |
| `16_heartbeat.sql` | Worker heartbeat liveness — `df._worker_epoch.last_seen_at` advances over time |

### Build-Phase Specific

| File | Phase | Description |
|------|-------|-------------|
| `44_connection_limit_backpressure.sql` | `connlimit-backpressure` | Backpressure: 4 workflows complete when `max_user_connections=2` |
| `45_connection_limit_timeout.sql` | `connlimit-timeout` | Timeout error after `execution_acquire_timeout` expires |
| `46_connection_limit_startup_validation.sql` | `connlimit-startup` | BGW refuses to start with invalid GUC value |
| `47_http_dsl_disabled.sql` | `http-disabled` | `df.http()` unavailable when built without `--features http` |
| `48_http_allow_all.sql` | `http-allow-all` | All HTTP destinations allowed when built with `--features http-allow-all` |

## Test Structure

```
pg_durable/
├── scripts/
│   └── test-e2e-local.sh     # Local test runner
└── tests/
    └── e2e/
        └── sql/
            ├── 00_setup_playground.sql      # Shared infrastructure (run first)
            ├── 00_requires_shared_preload.sql
            ├── 01_core_primitives.sql
            ├── 02_conditionals.sql
            ├── ...                          # 03–16 feature test files
            ├── 44_connection_limit_backpressure.sql
            ├── 45_connection_limit_timeout.sql
            ├── 46_connection_limit_startup_validation.sql
            ├── 47_http_dsl_disabled.sql
            └── 48_http_allow_all.sql
```

## Writing New Tests

Create a new `.sql` file in `tests/e2e/sql/`:

```sql
-- Test: Description of what this tests
-- Expected: What should happen

\set ON_ERROR_STOP on

-- Setup (optional)
DROP TABLE IF EXISTS test_mytable;
CREATE TABLE test_mytable (...);

-- Start the durable function
SELECT df.start(...) AS instance_id \gset

-- Wait for completion
DO $$
DECLARE
    status TEXT;
    attempts INT := 0;
BEGIN
    LOOP
        SELECT s INTO status FROM df.status(:'instance_id') s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed, got %', status;
    END IF;
END $$;

-- Verify results
DO $$
BEGIN
    -- Your assertions here
    IF (some condition fails) THEN
        RAISE EXCEPTION 'TEST FAILED: reason';
    END IF;
END $$;

-- Cleanup
DROP TABLE test_mytable;

-- Report success
SELECT 'TEST PASSED: my_test_name' AS result;
```

## Debugging Failed Tests

### View PostgreSQL logs

```bash
# Keep PostgreSQL running after the test run
./scripts/test-e2e-local.sh --keep

# Then inspect the background worker and server logs
tail -f ~/.pgrx/17.log
```

### Run single test manually

```bash
# Run one consolidated file locally
./scripts/test-e2e-local.sh 01_core_primitives --verbose --keep

# Or run a specific phase-scoped test
./scripts/test-e2e-local.sh --http-disabled 47_http_dsl_disabled --verbose --keep

# Connect to the kept server
~/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -d postgres
```

### Connect to the running local test server

If you kept PostgreSQL running during or after a test run:

```bash
# In another terminal while tests are running
~/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -d postgres
```

## CI Integration

Add to your CI pipeline:

```bash
./scripts/test-e2e-local.sh
```

## Makefile Targets

```bash
make test        # Run all tests (unit + E2E)
make test-e2e    # Run only E2E tests
make test-unit   # Run only pgrx unit tests
```

## Troubleshooting

### Docker not running
```
Error: Cannot connect to the Docker daemon
```
→ This guide does not use Docker for the local E2E workflow. Use `./scripts/test-e2e-local.sh` instead.

### PostgreSQL not initialized
```
Error: pgrx PostgreSQL 17 not installed
```
→ Run `cargo pgrx init`

### Tests timeout
```
TEST FAILED: status = pending
```
→ Background worker may not be starting. Check logs:
```bash
tail -f ~/.pgrx/17.log
```

### Build or install fails
```
Error: cargo pgrx install failed
```
→ Run `cargo build --features pg17` and then retry the test runner

