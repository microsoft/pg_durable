-- Test: Loop resilience - failed iterations don't kill the loop
-- Tests that a loop continues executing after individual iteration failures.
-- Expected: Loop absorbs iteration failures and continues to next iteration.

-- ============================================================================
-- Test 1: Loop continues after intermittent failures
-- ============================================================================

DROP TABLE IF EXISTS test_loop_resilience;
CREATE TABLE test_loop_resilience (id SERIAL, iteration INT, ts TIMESTAMP DEFAULT now());
DROP SEQUENCE IF EXISTS loop_resilience_seq;
CREATE SEQUENCE loop_resilience_seq START 1;

-- This function fails on every 3rd call (iterations 3, 6, 9) but succeeds otherwise.
-- Uses a shared sequence so retries of the same iteration count separately.
CREATE OR REPLACE FUNCTION test_loop_flaky_insert() RETURNS TEXT AS $$
DECLARE
    v_iter INT;
BEGIN
    v_iter := nextval('loop_resilience_seq');

    IF v_iter % 3 = 0 THEN
        RAISE EXCEPTION 'simulated failure on call %', v_iter;
    END IF;

    INSERT INTO test_loop_resilience (iteration) VALUES (v_iter);
    RETURN format('inserted iteration %s', v_iter);
END;
$$ LANGUAGE plpgsql;

-- Loop with a flaky body. The body SQL calls test_loop_flaky_insert which
-- fails on every 3rd call. With loop resilience, the loop should continue
-- past failures and run until the condition becomes false.
--
-- Note: Because retries also consume sequence values, the actual sequence values
-- in the table will vary. We verify the loop completed and inserted some rows.
CREATE TEMP TABLE _test1_state AS
SELECT df.start(
    df.loop(
        df.sql('SELECT test_loop_flaky_insert()'),
        'SELECT currval(''loop_resilience_seq'') < 10'
    ),
    'test-loop-resilience'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_cnt INT;
    v_seq_val INT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test1_state;
    RAISE NOTICE 'Test 1 - Loop resilience: instance %', v_instance_id;

    -- Wait longer since the loop has multiple iterations with retries and backoff
    SELECT df.wait_for_completion(v_instance_id, 60) INTO v_status;

    SELECT COUNT(*) INTO v_cnt FROM test_loop_resilience;
    SELECT last_value INTO v_seq_val FROM loop_resilience_seq;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-resilience]: expected completed, got %. Rows: %, seq: %',
            v_status, v_cnt, v_seq_val;
    END IF;

    -- We should have some rows (iterations that succeeded)
    IF v_cnt < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-resilience]: expected at least 1 row, got %', v_cnt;
    END IF;

    RAISE NOTICE 'PASSED: Loop continued past failures. % successful inserts, sequence reached %',
        v_cnt, v_seq_val;
END $$;

DROP TABLE _test1_state;

-- ============================================================================
-- Test 2: Loop terminates after too many consecutive failures
-- ============================================================================

DROP TABLE IF EXISTS test_loop_consecutive_fail;
CREATE TABLE test_loop_consecutive_fail (id SERIAL, attempt INT, ts TIMESTAMP DEFAULT now());

-- This function always fails. With retry count of 1 (no retries) and
-- consecutive failure limit of 10, the loop should fail after 10 iterations.
CREATE OR REPLACE FUNCTION test_loop_always_fail() RETURNS TEXT AS $$
BEGIN
    INSERT INTO test_loop_consecutive_fail (attempt) VALUES (
        (SELECT COALESCE(MAX(attempt), 0) + 1 FROM test_loop_consecutive_fail)
    );
    RAISE EXCEPTION 'always fails';
END;
$$ LANGUAGE plpgsql;

-- Set max_retries to 1 (no retries) so each iteration fails quickly
SET pg_durable.max_retries = 1;

CREATE TEMP TABLE _test2_state AS
SELECT df.start(
    df.loop(
        df.sql('SELECT test_loop_always_fail()')
    ),
    'test-consecutive-fail'
) AS instance_id;

-- Reset max_retries to default
SET pg_durable.max_retries = 3;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_attempts INT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test2_state;
    RAISE NOTICE 'Test 2 - Consecutive failure limit: instance %', v_instance_id;

    -- This should fail once the consecutive failure limit (10) is hit
    SELECT df.wait_for_completion(v_instance_id, 60) INTO v_status;

    SELECT COUNT(*) INTO v_attempts FROM test_loop_consecutive_fail;

    IF v_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [consecutive-fail]: expected failed, got %. Attempts: %',
            v_status, v_attempts;
    END IF;

    RAISE NOTICE 'PASSED: Loop terminated after % consecutive failures', v_attempts;
END $$;

DROP TABLE _test2_state;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP FUNCTION IF EXISTS test_loop_flaky_insert();
DROP FUNCTION IF EXISTS test_loop_always_fail();
DROP TABLE IF EXISTS test_loop_resilience;
DROP TABLE IF EXISTS test_loop_consecutive_fail;
DROP SEQUENCE IF EXISTS loop_resilience_seq;

SELECT 'TEST PASSED' AS result;
