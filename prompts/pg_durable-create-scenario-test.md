# Create Scenario Test for Durable SQL Function

## Objective
Generate an E2E test file in `tests/e2e/sql/` that models a real-world durable function pattern. The test should validate complex orchestration behavior using pg_durable's DSL.

## Input
Describe a durable function pattern you want to test (e.g., "order processing pipeline", "batch ETL job", "cron-style health check").

## Output
Create a new test file in `tests/e2e/sql/` following the established pattern.

## Test File Structure

### File Location
- **Path**: `tests/e2e/sql/NN_scenario_<descriptive_name>.sql`
- **Numbering**: Use next available number (11+) for scenarios

### File Template

```sql
-- Scenario Test: [Pattern Name]
-- Based on: [Real-world pattern or USER_GUIDE example]
-- Demonstrates: [list of DSL features used]
--
-- Pattern: [Brief description of what this tests]

-- ============================================================================
-- Setup: Create tables and helper functions
-- ============================================================================

DROP TABLE IF EXISTS test_table CASCADE;
CREATE TABLE test_table (
    id SERIAL PRIMARY KEY,
    -- ... fields relevant to the scenario
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT now()
);

-- Mock helper functions (if needed)
CREATE OR REPLACE FUNCTION mock_process(item_id INT) RETURNS INT AS $$
BEGIN
    -- Simulate processing
    PERFORM pg_sleep(0.1);
    UPDATE test_table SET status = 'completed' WHERE id = item_id;
    RETURN item_id;
END;
$$ LANGUAGE plpgsql;

-- Seed test data
INSERT INTO test_table (...) VALUES (...);

-- ============================================================================
-- Test: Main Durable Function
-- ============================================================================

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    -- DSL expression here
    -- Use operators: ~>, |=>, &, |, ?>, !>, @>
    -- Use functions: df.sql(), df.sleep(), df.join(), df.if(), df.loop(), etc.
    'step 1' |=> 'result1'
    ~> 'step 2 using $result1',
    'scenario-name'
);

-- ============================================================================
-- Wait and Verify
-- ============================================================================

-- For non-loop scenarios: wait for completion
SELECT pg_sleep(N);

-- For loop scenarios: wait for iterations, then cancel
-- SELECT pg_sleep(N);
-- SELECT df.cancel((SELECT instance_id FROM _test_state), 'Test complete');

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    -- Additional variables for verification
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing scenario: %', inst_id;
    
    -- Wait for completion (with timeout)
    LOOP
        SELECT s INTO inst_status FROM df.status(inst_id) s;
        EXIT WHEN lower(inst_status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    -- Verify expected status
    IF lower(inst_status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', inst_status;
    END IF;
    
    -- Additional assertions specific to scenario
    -- Example: verify data was processed
    -- IF (SELECT COUNT(*) FROM test_table WHERE status = 'completed') < 1 THEN
    --     RAISE EXCEPTION 'TEST FAILED: expected completed items';
    -- END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_name';
END $$;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP TABLE _test_state;
DROP TABLE test_table;
DROP FUNCTION IF EXISTS mock_process(INT);
SELECT 'TEST PASSED' AS result;
```

## DSL Features Reference

### Operators
| Operator | Name | Example |
|----------|------|---------|
| `~>` | Sequence | `'step1' ~> 'step2'` |
| `\|=>` | Name | `'SELECT 1' \|=> 'myvar'` |
| `&` | Join | `'task1' & 'task2'` |
| `\|` | Race | `'fast' \| df.sleep(30)` |
| `?>` | If-Then | `'cond' ?> 'then_branch'` |
| `!>` | Else | `'cond' ?> 'then' !> 'else'` |
| `@>` | Loop | `@> (body ~> df.sleep(60))` |

### Functions
| Function | Description |
|----------|-------------|
| `df.sql(query)` | Execute SQL (usually auto-wrapped) |
| `df.sleep(seconds)` | Pause for N seconds |
| `df.join(a, b)` | Run in parallel, wait for all |
| `df.join3(a, b, c)` | Three-way parallel |
| `df.race(a, b)` | Run in parallel, first wins |
| `df.if(cond, then, else)` | Conditional branch |
| `df.loop(body)` | Repeat forever |
| `df.wait_for_schedule(cron)` | Wait for cron match |

### Variable Substitution
```sql
'SELECT id FROM orders LIMIT 1' |=> 'order_id'
~> 'UPDATE orders SET status = ''processing'' WHERE id = $order_id'
```

## Scenario Patterns to Model

### 1. Sequential Pipeline
```sql
-- ETL: Extract -> Transform -> Load
'SELECT * FROM staging' |=> 'data'
~> 'INSERT INTO target SELECT * FROM staging WHERE ...'
~> 'DELETE FROM staging WHERE processed = true'
```

### 2. Parallel Processing with Join
```sql
-- Run multiple queries in parallel
'SELECT COUNT(*) FROM users' & 'SELECT COUNT(*) FROM orders'
~> 'INSERT INTO metrics (users, orders) VALUES (...)'
```

### 3. Conditional Logic
```sql
-- Process based on condition
'SELECT COUNT(*) > 10 FROM task_queue'
    ?> 'INSERT INTO logs VALUES (''high load'')'
    !> 'INSERT INTO logs VALUES (''normal load'')'
```

### 4. Race with Timeout
```sql
-- Process with timeout protection
(
    'SELECT long_running_process($id)'
    | df.sleep(30)  -- 30 second timeout
)
```

### 5. Cron-Style Loop
```sql
-- Run every 5 minutes
@> (
    df.wait_for_schedule('*/5 * * * *')
    ~> 'INSERT INTO heartbeats (ts) VALUES (now())'
)
```

### 6. Batch Processing Loop
```sql
-- Process items in batches until queue empty
@> (
    'SELECT get_next_batch(10)' |=> 'batch'
    ~> 'SELECT $batch IS NOT NULL'
        ?> 'SELECT process_batch($batch)'
        !> df.sleep(60)  -- Wait if queue empty
)
```

## Test Design Principles

### 1. Keep Tests Fast
- Use short sleep durations (1-2 seconds max)
- Limit iterations for loops (2-3 before cancel)
- Use 30 second max wait time for completion

### 2. Model Real Patterns
- Don't over-simplify; keep realistic complexity
- Preserve business logic flow
- Use mock functions that return deterministic results

### 3. Comprehensive Assertions
- Check status is 'completed' (or 'cancelled' for loops)
- Verify data was processed correctly
- Check expected side effects (table updates, etc.)

### 4. Clean Up Properly
- Drop all test tables
- Drop all test functions
- Use CASCADE when dropping tables with dependencies

### 5. Handle Loop Cancellation
```sql
-- df.cancel() sets df.instances.status = 'cancelled' (British spelling, lowercase).
IF lower(inst_status) != 'cancelled' THEN
    RAISE EXCEPTION 'TEST FAILED: expected cancelled, got %', inst_status;
END IF;
```

## Variable Substitution Limitations

**Note**: Variable substitution replaces `$name` with the raw value. This works well for:
- Integer IDs: `$order_id` → `123`
- Simple strings without special characters

For complex string values, use a job/ID pattern instead:
```sql
-- ❌ May break with special characters
'SELECT content FROM docs LIMIT 1' |=> 'content'
~> 'SELECT process($content)'  -- Breaks if content has quotes

-- ✅ Use ID reference pattern
'SELECT id FROM docs LIMIT 1' |=> 'doc_id'
~> 'SELECT process_doc($doc_id)'  -- Function fetches content by ID
```

## Validation Checklist

Before finalizing the test:

- [ ] Test file follows naming convention: `NN_scenario_<name>.sql`
- [ ] Header comments explain what's being tested
- [ ] Setup creates all needed tables/functions
- [ ] Test uses appropriate DSL features
- [ ] Wait time is sufficient but not excessive
- [ ] Assertions verify expected behavior
- [ ] Cleanup removes all test artifacts
- [ ] Test passes: `./scripts/test-e2e-local.sh NN_scenario`
- [ ] Test runs in < 30 seconds

## Running the Test

```bash
# Run specific test
./scripts/test-e2e-local.sh NN_scenario

# Run with debugging
./scripts/test-e2e-local.sh --keep NN_scenario

# Then connect to investigate
psql -h localhost -p 28817 -d postgres

# Check instance status
SELECT * FROM df.list_instances();
SELECT * FROM df.instance_info('instance_id');
```

## Ask Before Creating

If the scenario:
- Requires external services
- Uses features not yet implemented
- Would take more than 30 seconds to run
- Needs more than 3 helper functions

Then summarize the proposed test and ask for guidance before proceeding.

