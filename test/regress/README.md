# pg_durable pg_regress Tests

This directory contains the **pg_regress test suite** for pg_durable, using PostgreSQL's standard regression testing framework.

## Overview

pg_durable has two test suites:

1. **pg_regress suite** (this directory) - Simple, deterministic tests for core DSL functionality
2. **E2E suite** (`tests/e2e/`) - Complex scenario tests with Docker

## Running pg_regress Tests

### Prerequisites

1. Build and install pg_durable:
   ```bash
   cargo pgrx install --release --pg-config $(cargo pgrx info pg-config pg17)
   ```

2. Start PostgreSQL with the test database:
   ```bash
   ./scripts/pg-start.sh contrib_regression
   ```

   **Important**: This sets the `pg_durable.database_name` GUC to tell the background worker which database to connect to. pg_regress will create the `contrib_regression` database when tests run.

### Run all tests

As a one-liner from the repository root:
```bash
PG_CONFIG=$(cargo pgrx info pg-config pg17) make installcheck
```

### How Background Worker Connection Works

When PostgreSQL starts, the pg_durable background worker attempts to connect to the database specified by the `pg_durable.database_name` GUC (default: `postgres`). For pg_regress tests, this must be set to `contrib_regression`.

**Retry logic:** If the database doesn't exist yet (common during startup), the worker retries the connection every 5 seconds until:
- The database is created by pg_regress, OR
- PostgreSQL shuts down

This allows pg_regress to create the test database after PostgreSQL starts, and the worker will automatically connect once it's available.

### Run specific test

```bash
cd test/regress
make installcheck REGRESS=simple
```

### View test results

- Test output: `regression.out`
- Diffs (on failure): `regression.diffs`

## Test Files

| Test | Description |
|------|-------------|
| `simple.sql` | Basic SQL execution, `df.sql()` |
| `sequence.sql` | Sequential execution (`~>`, `df.seq()`) |
| `variables.sql` | Variable binding (`\|=>`, `df.as()`) |
| `parallel.sql` | Parallel execution (`&`, `df.join()`) |
| `conditional.sql` | Conditional logic (`df.if()`, `?>`, `!>`) |

## Key Differences from E2E Tests

### Deterministic Output

pg_regress tests use `df.wait_for_completion()` instead of polling loops:

```sql
-- ✅ pg_regress style (deterministic)
SELECT df.start('SELECT 42', 'test') AS instance_id \gset
SELECT df.wait_for_completion(:'instance_id') AS status;

-- ❌ E2E style (non-deterministic)
DO $$
DECLARE
    attempts INT := 0;
BEGIN
    LOOP
        SELECT s INTO status FROM df.status(instance_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
END $$;
```

### No Timestamps or UUIDs in Output

- Tables don't include `TIMESTAMP DEFAULT now()`
- Tests don't output instance IDs (stored in psql variables instead)
- All SELECT results are explicitly ordered for determinism

### Simple, Focused Tests

- Each test focuses on one DSL feature
- Minimal setup and teardown
- Clear, readable output

## When to Use Each Test Suite

### Use pg_regress for:
- Testing core DSL operators and functions
- Quick iteration during development
- Verifying deterministic behavior
- Standard PostgreSQL extension testing

### Use E2E for:
- Complex multi-step scenarios
- HTTP calls and external dependencies
- Race conditions and cancellation
- Background worker behavior
- Timing-sensitive tests

## Adding New Tests

1. Create test file: `test/regress/sql/my_test.sql`
2. Add to Makefile: `REGRESS = simple sequence ... my_test`
3. Run test to generate expected output
4. Verify and commit both `.sql` and `.out` files

### Test Structure

```sql
-- Test description and purpose
DROP TABLE IF EXISTS test_table;
CREATE TABLE test_table (...);

-- Test A: First variant
SELECT df.start(...) AS instance_id \gset
SELECT df.wait_for_completion(:'instance_id') AS status;

-- Test B: Second variant
SELECT df.start(...) AS instance_id \gset
SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify results (with explicit ORDER BY)
SELECT * FROM test_table ORDER BY id;

-- Cleanup
DROP TABLE test_table;
```

## Troubleshooting

### Test failures

View the diff:
```bash
cat regression.diffs
```

### Background worker not running

The background worker must be running for tests to complete. Check:
```bash
# Check if worker is running
ps aux | grep pg_durable

# View worker logs
tail -f /path/to/postgresql.log
```

### Timeout errors

If tests timeout, the background worker may not be processing instances:
- Check worker is running
- Check PostgreSQL logs for errors
- Increase timeout in test: `df.wait_for_completion(instance_id, 60)`

## CI Integration

The CI workflow (`.github/workflows/ci.yml`) runs pg_regress tests automatically on every PR.

## References

- PostgreSQL pg_regress: https://www.postgresql.org/docs/current/regress.html
- pgrx testing: https://github.com/pgcentralfoundation/pgrx/blob/develop/TESTING.md
- pg_durable E2E tests: `../../tests/e2e/README.md`
