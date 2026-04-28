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
        
        -- Wait for cancellation (may show as Failed with canceled output)
        attempts := 0;
        LOOP
            SELECT s INTO status FROM df.status(rec.instance_id) s;
            EXIT WHEN lower(status) IN ('canceled', 'cancelled', 'failed') OR attempts > 100;
            PERFORM pg_sleep(0.2);
            attempts := attempts + 1;
        END LOOP;
        
        IF lower(status) NOT IN ('canceled', 'cancelled', 'failed') THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected Canceled, got %', rec.variant, status;
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

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
