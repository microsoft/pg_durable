# pg_regress Test Suite Specification

## Overview

This specification describes the addition of a **pg_regress-compatible test suite** to pg_durable using the standard PostgreSQL regression testing framework. This aligns pg_durable with PostgreSQL community practices and enables testing against any PostgreSQL installation without Docker overhead.

## Background

**pg_regress** is PostgreSQL's official regression test driver:
- Ships with PostgreSQL core (`src/test/regress/`)
- Runs `.sql` test files and compares output against expected `.out` files
- **Industry standard** for testing PostgreSQL extensions
- Used by virtually all mature PostgreSQL extensions (PostGIS, pg_stat_statements, pgvector, etc.)
- Familiar to PostgreSQL developers, DBAs, and contributors
- Well-integrated with PostgreSQL build systems and package managers

**Why pg_regress matters for pg_durable:**

1. **Community expectations** - PostgreSQL extension users expect `make installcheck` to work
2. **Development workflow** - Test against installed PostgreSQL without Docker overhead
3. **Fork integration** - Required for integration into PostgreSQL distributions (Azure DB for PostgreSQL, Citus, AWS RDS, etc.)
4. **Package maintainers** - Linux distros (Debian, RHEL) use pg_regress for validation
5. **Contributor friendly** - Lower barrier to entry for PostgreSQL developers
6. **Production testing** - Test against actual production PostgreSQL installations

**Current pg_durable testing:**
- Custom E2E framework in `tests/e2e/` using Docker and shell scripts
- Tests use polling loops with variable timing
- Non-deterministic output (UUIDs, timestamps, variable wait times)
- Not compatible with pg_regress's output comparison model
- Requires Docker, longer feedback cycles
- Unfamiliar to most PostgreSQL developers

## Goals

1. **Industry standard testing** - Use the same testing approach as mature PostgreSQL extensions
2. **Faster development feedback** - Test against local PostgreSQL without Docker
3. **Enable fork integration** - Allow pg_durable to be tested in PostgreSQL distributions
4. **Lower contributor barrier** - Familiar testing approach for PostgreSQL developers
5. **Maintain existing E2E tests** - Keep comprehensive tests for complex scenarios
6. **Provide simple, deterministic tests** - Cover core DSL functionality with reproducible output

## Non-Goals

- Replace existing E2E test suite (both will coexist)
- Test every edge case with pg_regress (use E2E for complex scenarios)
- Test background worker internals (focus on SQL API surface)

## Design

### Dual Test Suite Approach

**pg_regress suite** (`sql/`, `expected/`):
- Simple, deterministic tests
- Core DSL functionality
- Fast feedback (no Docker)
- Standard PostgreSQL integration
- Runs against any PostgreSQL installation
- Familiar to PostgreSQL developers
- Quick iteration during development

**E2E suite** (`tests/e2e/`):
- Complex scenarios (keep existing)
- HTTP calls, external dependencies
- Race conditions, cancellation
- Background worker behavior
- Full integration testing with Docker
- Comprehensive scenario testing

### Directory Structure

```
sql/                  # pg_regress input test files
├── 00_init.sql
├── simple.sql
├── sequence.sql
├── parallel.sql
├── conditional.sql
└── variables.sql
expected/             # Expected output files (generated)
├── 00_init.out
├── simple.out
├── sequence.out
└── ...
Makefile              # PGXS configuration (at repo root)
```

### New Helper Function: df.wait_for_completion()

**Signature:**
```sql
df.wait_for_completion(
    instance_id TEXT,
    timeout_seconds INT DEFAULT 30
) RETURNS TEXT
```

**Behavior:**
- Polls instance status until completed/failed/cancelled
- Returns final status as text: `'completed'`, `'failed'`, or `'cancelled'`
- Raises exception on timeout
- Encapsulates non-deterministic polling logic

**Default timeout:** 30 seconds
- Matches current E2E tests (300 attempts × 0.1s = 30s)
- Long enough for simple tests on slow CI systems
- Short enough to fail fast on real issues

**Implementation location:** `src/dsl.rs`

**Example usage:**
```sql
-- Start instance
SELECT df.start('SELECT 42', 'test') AS instance_id \gset

-- Wait for completion (deterministic timeout)
SELECT df.wait_for_completion(:'instance_id');

-- Output: 'completed'
```

### Making Tests Deterministic

**Problems with current E2E tests:**

1. **Non-deterministic timing:**
```sql
-- ❌ Variable number of iterations
LOOP
    SELECT s INTO status FROM df.status(rec.instance_id) s;
    EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 300;
    PERFORM pg_sleep(0.1);
    attempts := attempts + 1;
END LOOP;
```

2. **Variable instance IDs in output:**
```sql
-- ❌ UUID changes every run
RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;
-- Output: Testing operator variant: f47ac10b-58cc-4372-a567-0e02b2c3d479
```

3. **Timestamps in tables:**
```sql
-- ❌ Non-deterministic timestamps
CREATE TABLE test_log (id SERIAL, step INT, ts TIMESTAMP DEFAULT now());
```

**Solutions:**

1. **Use `df.wait_for_completion()` instead of polling loops**
2. **Remove timestamps from test tables**
3. **Avoid RAISE NOTICE with instance IDs**
4. **Order all SELECT results explicitly**

## Test Conversion List

### Phase 1: Core DSL (Priority 1)

Convert these tests from `tests/e2e/sql/` to pg_regress format:

| E2E Test | pg_regress Name | Description |
|----------|-----------------|-------------|
| `01_simple_sql.sql` | `simple.sql` | Basic SQL execution, `df.sql()` |
| `02_sequence.sql` | `sequence.sql` | Sequential execution (`~>`, `df.seq()`) |
| `03_variables.sql` | `variables.sql` | Variable binding (`\|=>`, `df.as()`) |
| `04_parallel_join.sql` | `parallel.sql` | Parallel execution (`&`, `df.join()`) |
| `05_conditional_true.sql` + `06_conditional_false.sql` | `conditional.sql` | Conditional logic (`df.if()`) |

**Coverage:** Basic DSL operators and functions

### Phase 2: Advanced DSL (Priority 2)

| E2E Test | pg_regress Name | Description |
|----------|-----------------|-------------|
| `24_loop_break.sql` | `loops.sql` | Loop execution (`df.loop()`, break conditions) |
| `23_transactions.sql` | `transactions.sql` | Transaction semantics |
| `10_explain.sql` | `explain.sql` | Execution plan inspection |

**Coverage:** Advanced features with deterministic behavior

### Phase 3: Management API (Priority 3)

| New Test | pg_regress Name | Description |
|----------|-----------------|-------------|
| N/A | `management.sql` | Status, cancel, cleanup operations |
| N/A | `labels.sql` | Label-based queries |

**Coverage:** Management and observability

### Excluded from pg_regress

These tests remain E2E-only (non-deterministic or complex):

| E2E Test | Reason |
|----------|--------|
| `07_sleep.sql` | Timing-dependent |
| `08_loop_cancel.sql` | Race conditions, background worker timing |
| `09_monitoring.sql` | Real-time metrics, variable timing |
| `11-16_scenario_*.sql` | Complex multi-table scenarios |
| `17_race.sql` | Explicitly tests race conditions |
| `18_http.sql` | External HTTP dependencies |
| `19_github_api.sql` | External API dependencies |
| `21_signals.sql` | Complex timing, external signal sending |
| `22_cross_connection.sql` | Multi-connection complexity |
| `25_extension_creation_security.sql` | Security-specific, complex |

## Example Conversion

### Before (E2E format)

**File:** `tests/e2e/sql/02_sequence.sql`

```sql
DROP TABLE IF EXISTS test_sequence_log;
CREATE TABLE test_sequence_log (id SERIAL, step INT, variant TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''op'')',
    'test-sequence-op'
), 'operator';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    attempts INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;
        attempts := 0;
        
        LOOP
            SELECT s INTO status FROM df.status(rec.instance_id) s;
            EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        
        IF lower(status) != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;
    END LOOP;
END $$;

SELECT step, variant FROM test_sequence_log ORDER BY id;
DROP TABLE _test_state;
DROP TABLE test_sequence_log;
SELECT 'TEST PASSED' AS result;
```

### After (pg_regress format)

**File:** `sql/sequence.sql`

```sql
-- Test sequential execution using ~> operator and df.seq() function
DROP TABLE IF EXISTS test_sequence_log;
CREATE TABLE test_sequence_log (id SERIAL, step INT, variant TEXT);

-- Test A: Using ~> operator
SELECT df.start(
    'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''op'')',
    'test-sequence-op'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id');

-- Test B: Using df.seq() function
SELECT df.start(
    df.seq(
        df.seq(
            'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''fn'')',
            'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''fn'')'
        ),
        'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''fn'')'
    ),
    'test-sequence-fn'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id');

-- Verify results (deterministic output)
SELECT step, variant FROM test_sequence_log ORDER BY id;

-- Cleanup
DROP TABLE test_sequence_log;
```

**File:** `expected/sequence.out`

```
DROP TABLE
CREATE TABLE
 wait_for_completion 
---------------------
 completed
(1 row)

 wait_for_completion 
---------------------
 completed
(1 row)

 step | variant 
------+---------
    1 | op
    2 | op
    3 | op
    1 | fn
    2 | fn
    3 | fn
(6 rows)

DROP TABLE
```

## Implementation Plan

### Step 1: Add df.wait_for_completion()

**File:** `src/dsl.rs`

Add new function:
```rust
#[pg_extern(schema = "df")]
fn wait_for_completion(
    instance_id: &str,
    timeout_seconds: default!(i32, 30),
) -> Result<String, Box<dyn std::error::Error>> {
    // Poll status every 100ms
    // Return final status or error on timeout
}
```

### Step 2: Create pg_regress Directory Structure

Test files live at the repo root:
```bash
mkdir -p sql expected
```

### Step 3: PGXS Configuration in Root Makefile

The root `Makefile` includes PGXS at the bottom:

```makefile
# pg_regress configuration for pg_durable
EXTENSION = pg_durable
DATA = pg_durable--1.0.sql

# Test files (in order)
REGRESS = simple sequence variables parallel conditional loops transactions explain management labels

# PostgreSQL configuration
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```

### Step 4: Convert Phase 1 Tests

1. Convert 5 core DSL tests to pg_regress format
2. Run tests: `make installcheck`
3. Capture expected output
4. Verify reproducibility

### Step 5: Update Documentation

- Update `test/regress/README.md` noting files are at repo root
- Update main `README.md` with pg_regress instructions
- Update `docs/TESTING.md` with dual approach

### Step 6: Add CI Integration

Update `.github/workflows/ci.yml`:
```yaml
- name: Run pg_regress tests
  run: |
    PG_CONFIG=$(cargo pgrx info pg-config pg17) make installcheck
```

## Success Criteria

- [ ] `df.wait_for_completion()` function implemented and tested
- [ ] 5 Phase 1 tests converted and passing
- [ ] Expected output files generated and committed
- [ ] `make installcheck` works against running PostgreSQL instance
- [ ] E2E tests still pass (no regression)
- [ ] Documentation updated
- [ ] CI runs both test suites

## Alternative Approaches Considered

### Output Normalization

Some extensions add custom normalization frameworks (sed-like substitution rules) to handle non-deterministic output like UUIDs or timing values.

**Example:**
```
# normalize.rules
s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/INSTANCE_ID/g
s/\d+\.\d+ ms/N ms/g
```

**Why we're not using this approach:**

1. **Not standard pg_regress** - Requires custom Rust code and build infrastructure
2. **Harder debugging** - Test failures show normalized output, not actual values
3. **Fork complexity** - PostgreSQL forks wouldn't recognize this approach
4. **Unnecessary** - Making tests truly deterministic (via `df.wait_for_completion()`, removing timestamps, avoiding UUID output) is simpler and more maintainable

**When normalization might be useful:**
- If testing EXPLAIN output with variable costs/timing
- If PostgreSQL version differences cause output variations
- For these cases, use PostgreSQL's built-in alternate expected files (`test.out`, `test_1.out`) instead

## Future Considerations

- **Performance:** pg_regress tests should complete in <10 seconds total
- **Isolation:** Each test should clean up its own tables
- **Parallel execution:** pg_regress supports parallel test execution, but our tests need sequential execution due to shared background worker
- **Version compatibility:** Test across PostgreSQL 14, 15, 16, 17

## Open Questions

1. Should `df.wait_for_completion()` return just status, or include additional metadata (execution time, node count)?
   - **Answer:** Return only status for simplicity. Use `df.result()` for metadata if needed.

2. Should we support `make check` (in-tree build) or only `make installcheck` (installed extension)?
   - **Answer:** Both. pg_regress supports both modes.

3. What should happen if background worker is not running?
   - **Answer:** `df.wait_for_completion()` should timeout with clear error message.

## References

- PostgreSQL pg_regress documentation: https://www.postgresql.org/docs/current/regress.html
- pgrx testing guide: https://github.com/pgcentralfoundation/pgrx/blob/develop/TESTING.md
- Example pg_regress extension: https://github.com/citusdata/citus/tree/main/src/test/regress
