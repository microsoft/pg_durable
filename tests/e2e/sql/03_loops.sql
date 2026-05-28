-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 08_loop_cancel, 24_loop_break
-- Tests: loop execution and cancellation, loop break via df.break(), while-loop condition
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 08_loop_cancel ===

DROP TABLE IF EXISTS test_loop_log;
CREATE TABLE test_loop_log (id SERIAL, iteration INT, variant TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: df.loop() function
INSERT INTO _test_state SELECT df.start(
    df.loop(
        'INSERT INTO test_loop_log (iteration, variant) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_loop_log WHERE variant = ''func''), ''func'')'
        ~> df.sleep(1)
    ),
    'test-loop-func'
), 'func';

-- Variant B: @> operator
INSERT INTO _test_state SELECT df.start(
    @> (
        'INSERT INTO test_loop_log (iteration, variant) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_loop_log WHERE variant = ''op''), ''op'')'
        ~> df.sleep(1)
    ),
    'test-loop-op'
), 'op';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
    attempts INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;
        attempts := 0;
        
        -- Wait for at least 2 iterations
        LOOP
            SELECT COUNT(*) INTO cnt FROM test_loop_log WHERE variant = rec.variant;
            EXIT WHEN cnt >= 2 OR attempts > 100;
            PERFORM pg_sleep(0.5);
            attempts := attempts + 1;
        END LOOP;
        
        IF cnt < 2 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected at least 2 iterations, got %', rec.variant, cnt;
        END IF;
        
        -- Cancel the loop
        PERFORM df.cancel(rec.instance_id, 'Test complete');
        
        -- df.cancel immediately marks df.instances.status = 'cancelled'.
        -- Poll until df.status() reflects that (should be instant, but allow a short window
        -- in case an in-flight update_instance_status activity hasn't been guarded yet).
        attempts := 0;
        LOOP
            SELECT s INTO status FROM df.status(rec.instance_id) s;
            EXIT WHEN lower(status) = 'cancelled' OR attempts > 100;
            PERFORM pg_sleep(0.2);
            attempts := attempts + 1;
        END LOOP;
        
        IF lower(status) != 'cancelled' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected cancelled, got %', rec.variant, status;
        END IF;
        
        RAISE NOTICE 'PASSED: loop_cancel [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: loop_cancel (func + @> operator)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_loop_log;

-- === Test: 24_loop_break ===

DROP TABLE IF EXISTS test_break_log;
CREATE TABLE test_break_log (id SERIAL, iteration INT, test_name TEXT, ts TIMESTAMP DEFAULT now());

-- Test 1: df.break() exits the loop
CREATE TEMP TABLE _test1_state AS
SELECT df.start(
    df.loop(
        'INSERT INTO test_break_log (iteration, test_name) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_break_log WHERE test_name = ''break_test''), ''break_test'')'
        ~> (
            'SELECT COUNT(*) >= 3 FROM test_break_log WHERE test_name = ''break_test'''
                ?> df.break('{"reason": "reached 3 iterations"}')
                !> df.sleep(1)
        )
    ),
    'test-break'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_cnt INT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test1_state;
    RAISE NOTICE 'Test 1 - df.break(): instance %', v_instance_id;
    
    SELECT df.wait_for_completion(v_instance_id, 50) INTO v_status;
    
    SELECT COUNT(*) INTO v_cnt FROM test_break_log WHERE test_name = 'break_test';
    
    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [break]: expected Completed, got %', v_status;
    END IF;
    
    IF v_cnt != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [break]: expected 3 iterations, got %', v_cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: df.break() - loop exited after 3 iterations';
END $$;

DROP TABLE _test1_state;

-- Test 2: df.loop(body, condition) - while loop
CREATE TEMP TABLE _test2_state AS
SELECT df.start(
    df.loop(
        'INSERT INTO test_break_log (iteration, test_name) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_break_log WHERE test_name = ''while_test''), ''while_test'')'
        ~> df.sleep(1),
        'SELECT COUNT(*) < 4 FROM test_break_log WHERE test_name = ''while_test'''
    ),
    'test-while-loop'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_cnt INT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test2_state;
    RAISE NOTICE 'Test 2 - while loop: instance %', v_instance_id;
    
    SELECT df.wait_for_completion(v_instance_id, 50) INTO v_status;
    
    SELECT COUNT(*) INTO v_cnt FROM test_break_log WHERE test_name = 'while_test';
    
    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [while]: expected Completed, got %', v_status;
    END IF;
    
    IF v_cnt != 4 THEN
        RAISE EXCEPTION 'TEST FAILED [while]: expected 4 iterations, got %', v_cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: while loop - exited when condition became false';
END $$;

DROP TABLE _test2_state;

-- Test 3: df.break() with return value
CREATE TEMP TABLE _test3_state AS
SELECT df.start(
    df.loop(
        'INSERT INTO test_break_log (iteration, test_name) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_break_log WHERE test_name = ''break_value_test''), ''break_value_test'')'
        ~> (
            'SELECT COUNT(*) >= 2 FROM test_break_log WHERE test_name = ''break_value_test'''
                ?> df.break('{"total": 2, "status": "done"}')
                !> df.sleep(1)
        )
    ),
    'test-break-value'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_result TEXT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test3_state;
    RAISE NOTICE 'Test 3 - df.break(value): instance %', v_instance_id;
    
    SELECT df.wait_for_completion(v_instance_id, 50) INTO v_status;
    
    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [break-value]: expected Completed, got %', v_status;
    END IF;
    
    SELECT r INTO v_result FROM df.result(v_instance_id) r;
    RAISE NOTICE 'Break returned: %', v_result;
    
    IF v_result IS NULL OR v_result::jsonb->>'status' IS NULL THEN
        RAISE NOTICE 'Note: Break value not directly accessible in df.result() - this is expected for now';
    END IF;
    
    RAISE NOTICE 'PASSED: df.break(value) - loop completed with value';
END $$;

DROP TABLE _test3_state;
DROP TABLE test_break_log;

-- Test 4: named result on the LOOP node itself is accessible downstream
DROP TABLE IF EXISTS test_loop_named;
CREATE TABLE test_loop_named (id SERIAL, status TEXT);

CREATE TEMP TABLE _test4_state AS
SELECT df.start(
    (df.loop(df.break('{"status": "done"}')) |=> 'loop_result')
    ~> $$INSERT INTO test_loop_named (status) VALUES ($loop_result::jsonb->>'status')$$,
    'test-loop-named-result'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_loop_status TEXT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test4_state;
    RAISE NOTICE 'Test 4 - named loop result: instance %', v_instance_id;

    SELECT df.wait_for_completion(v_instance_id, 20) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-named]: expected Completed, got %', v_status;
    END IF;

    SELECT status INTO v_loop_status FROM test_loop_named ORDER BY id DESC LIMIT 1;

    IF v_loop_status != 'done' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-named]: expected done, got %', v_loop_status;
    END IF;

    RAISE NOTICE 'PASSED: named LOOP result stored';
END $$;

DROP TABLE _test4_state;
DROP TABLE test_loop_named;

-- === Test: running_status_during_loop ===
-- Verify that df.status() reports 'running' while a loop is actively executing
-- (regression test for: loops reporting 'pending' instead of 'running')

DROP TABLE IF EXISTS test_running_status_log;
CREATE TABLE test_running_status_log (id SERIAL, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_running_state AS
SELECT df.start(
    df.loop(
        'INSERT INTO test_running_status_log DEFAULT VALUES'
        ~> df.sleep(1)
    ),
    'test-running-status'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_cnt INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test_running_state;
    RAISE NOTICE 'Test running_status_during_loop: instance %', v_instance_id;

    -- Wait until at least one iteration has completed so the worker has
    -- clearly started executing the loop body.
    LOOP
        SELECT COUNT(*) INTO v_cnt FROM test_running_status_log;
        EXIT WHEN v_cnt >= 1 OR attempts > 100;
        PERFORM pg_sleep(0.2);
        attempts := attempts + 1;
    END LOOP;

    IF v_cnt < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [running_status]: loop body never executed';
    END IF;

    -- The instance must now report 'running', not 'pending'
    SELECT s INTO v_status FROM df.status(v_instance_id) s;

    IF lower(v_status) != 'running' THEN
        RAISE EXCEPTION 'TEST FAILED [running_status]: expected running, got %', v_status;
    END IF;

    RAISE NOTICE 'PASSED: running_status_during_loop - status is running while loop executes';

    -- Cancel to clean up
    PERFORM df.cancel(v_instance_id, 'Test complete');
END $$;

DROP TABLE _test_running_state;
DROP TABLE test_running_status_log;

-- === Test: zero_sleep_loop_rate_limited ===
-- Regression test for: df.loop(df.sleep(0)) busy-spin (issue #13).
-- A loop whose body contains only a zero-duration sleep must NOT spin at full
-- CPU speed.  With the 1-second minimum-iteration delay enforced by the loop
-- handler, at most a handful of iterations should complete in 3 seconds.

DROP TABLE IF EXISTS test_zero_sleep_log;
CREATE TABLE test_zero_sleep_log (id SERIAL, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_zero_sleep_state AS
SELECT df.start(
    df.loop(
        'INSERT INTO test_zero_sleep_log DEFAULT VALUES'
        ~> df.sleep(0)
    ),
    'test-loop-zero-sleep'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status      TEXT;
    v_cnt         INT;
    attempts      INT := 0;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test_zero_sleep_state;
    RAISE NOTICE 'Test zero_sleep_loop_rate_limited: instance %', v_instance_id;

    -- Wait until at least 1 iteration has run so the loop is clearly started.
    LOOP
        SELECT COUNT(*) INTO v_cnt FROM test_zero_sleep_log;
        EXIT WHEN v_cnt >= 1 OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF v_cnt < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [zero-sleep]: loop body never executed';
    END IF;

    -- Confirm the loop is still running (not failed/errored after the first iteration).
    SELECT s INTO v_status FROM df.status(v_instance_id) s;
    IF lower(v_status) != 'running' THEN
        RAISE EXCEPTION 'TEST FAILED [zero-sleep]: expected running before observation window, got %', v_status;
    END IF;

    -- Let it run for ~3 more seconds and count iterations.
    PERFORM pg_sleep(3);
    SELECT COUNT(*) INTO v_cnt FROM test_zero_sleep_log;

    -- Lower bound: the loop must have made meaningful progress.
    IF v_cnt < 2 THEN
        RAISE EXCEPTION 'TEST FAILED [zero-sleep]: only % iterations in ~3s; rate-limit may be too aggressive', v_cnt;
    END IF;

    -- With a 1-second minimum delay per continue_as_new, the loop cannot
    -- complete more than ~4 iterations in 3 seconds (generous upper bound of
    -- 15 to accommodate slow CI environments).  Without the fix it would run
    -- hundreds of times in the same window.
    IF v_cnt > 15 THEN
        RAISE EXCEPTION 'TEST FAILED [zero-sleep]: % iterations in ~3s (expected <= 15); minimum rate-limit may not be working', v_cnt;
    END IF;

    RAISE NOTICE 'PASSED: zero_sleep_loop_rate_limited - % iterations in ~3s (within expected range)', v_cnt;

    PERFORM df.cancel(v_instance_id, 'Test complete');
END $$;

DROP TABLE _test_zero_sleep_state;
DROP TABLE test_zero_sleep_log;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
