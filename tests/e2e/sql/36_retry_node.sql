-- Test: Node retry on transient SQL failure
-- Tests that SQL activities are retried on failure up to max_retries attempts.
-- Uses a function that fails on the first N calls and succeeds on the Nth.
-- Expected: The durable function completes successfully after retries.
--
-- Key design note: Each activity retry runs in a separate transaction. If the
-- function raises an exception, the transaction is rolled back, so any INSERTs
-- in that transaction are lost. We use SEQUENCES to count attempts because
-- nextval() is never rolled back, even if the calling transaction aborts.

-- ============================================================================
-- Test 1: SQL node succeeds after transient failures (retried by duroxide)
-- ============================================================================

DROP SEQUENCE IF EXISTS test_retry_seq;
CREATE SEQUENCE test_retry_seq START 1;
DROP TABLE IF EXISTS test_retry_log;
CREATE TABLE test_retry_log (id SERIAL, attempt INT, ts TIMESTAMP DEFAULT now());

-- This function tracks attempts via a sequence (survives rollback).
-- It fails the first 2 calls and succeeds on the 3rd.
CREATE OR REPLACE FUNCTION test_retry_flaky() RETURNS TEXT AS $$
DECLARE
    v_attempt INT;
BEGIN
    v_attempt := nextval('test_retry_seq');

    IF v_attempt < 3 THEN
        RAISE EXCEPTION 'Transient failure on attempt %', v_attempt;
    END IF;

    INSERT INTO test_retry_log (attempt) VALUES (v_attempt);
    RETURN format('success on attempt %s', v_attempt);
END;
$$ LANGUAGE plpgsql;

-- pg_durable.max_retries defaults to 3, so this should succeed:
-- Attempt 1: fail, Attempt 2: fail, Attempt 3: succeed
CREATE TEMP TABLE _test1_state AS
SELECT df.start(
    df.sql('SELECT test_retry_flaky()'),
    'test-retry-succeed'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_logged INT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test1_state;
    RAISE NOTICE 'Test 1 - SQL retry: instance %', v_instance_id;

    SELECT df.wait_for_completion(v_instance_id, 30) INTO v_status;

    SELECT COUNT(*) INTO v_logged FROM test_retry_log;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [retry-succeed]: expected completed, got %. Rows logged: %', v_status, v_logged;
    END IF;

    -- The successful attempt (3rd) should have inserted a row
    IF v_logged < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [retry-succeed]: expected at least 1 logged row, got %', v_logged;
    END IF;

    RAISE NOTICE 'PASSED: SQL node retried and succeeded (% rows logged)',
        v_logged;
END $$;

DROP TABLE _test1_state;

-- ============================================================================
-- Test 2: SQL node fails permanently when retries are exhausted
-- ============================================================================

DROP SEQUENCE IF EXISTS test_retry_fail_seq;
CREATE SEQUENCE test_retry_fail_seq START 1;

-- This function always fails. Sequence tracks how many times it was called.
CREATE OR REPLACE FUNCTION test_retry_always_fail() RETURNS TEXT AS $$
DECLARE
    v_attempt INT;
BEGIN
    v_attempt := nextval('test_retry_fail_seq');
    RAISE EXCEPTION 'permanent failure on attempt %', v_attempt;
END;
$$ LANGUAGE plpgsql;

-- With default max_retries=3, this function should fail after 3 attempts
CREATE TEMP TABLE _test2_state AS
SELECT df.start(
    df.sql('SELECT test_retry_always_fail()'),
    'test-retry-exhaust'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_attempts INT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test2_state;
    RAISE NOTICE 'Test 2 - Retry exhausted: instance %', v_instance_id;

    SELECT df.wait_for_completion(v_instance_id, 30) INTO v_status;

    -- Sequence value tells us how many times the function was called
    SELECT last_value INTO v_attempts FROM test_retry_fail_seq;

    IF v_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [retry-exhaust]: expected failed, got %. Attempts: %', v_status, v_attempts;
    END IF;

    -- Should have exactly 3 attempts (max_retries=3)
    IF v_attempts != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [retry-exhaust]: expected 3 attempts, got %', v_attempts;
    END IF;

    RAISE NOTICE 'PASSED: SQL node failed after exhausting % retry attempts', v_attempts;
END $$;

DROP TABLE _test2_state;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP FUNCTION IF EXISTS test_retry_flaky();
DROP FUNCTION IF EXISTS test_retry_always_fail();
DROP TABLE IF EXISTS test_retry_log;
DROP SEQUENCE IF EXISTS test_retry_seq;
DROP SEQUENCE IF EXISTS test_retry_fail_seq;

SELECT 'TEST PASSED' AS result;
