-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.break() inside JOIN and RACE branches propagates correctly to enclosing loop
-- Repro for: Bug: df.break() inside a JOIN branch is silently ignored
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test 1: df.break() inside a JOIN branch exits the loop ===

DROP TABLE IF EXISTS test_break_join_log;
CREATE TABLE test_break_join_log (id SERIAL, iteration INT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_break_join_state AS
SELECT df.start(
    df.loop(
        'INSERT INTO test_break_join_log (iteration) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_break_join_log))'
        ~> (
            df.break('done') & 'SELECT ''other_branch'''
        )
    ),
    'test-break-in-join'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_cnt INT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test_break_join_state;
    RAISE NOTICE 'Test 1 - df.break() in JOIN branch: instance %', v_instance_id;

    SELECT df.wait_for_completion(v_instance_id, 50) INTO v_status;

    SELECT COUNT(*) INTO v_cnt FROM test_break_join_log;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [break-in-join]: expected completed, got %', v_status;
    END IF;

    -- Loop should have run exactly 1 iteration before the break exited it
    IF v_cnt != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [break-in-join]: expected 1 iteration, got % (loop did not exit on break)', v_cnt;
    END IF;

    RAISE NOTICE 'PASSED: df.break() in JOIN branch exits the loop after 1 iteration';
END $$;

DROP TABLE _test_break_join_state;
DROP TABLE test_break_join_log;

-- === Test 2: df.break() inside the winning RACE branch exits the loop ===

DROP TABLE IF EXISTS test_break_race_log;
CREATE TABLE test_break_race_log (id SERIAL, iteration INT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_break_race_state AS
SELECT df.start(
    df.loop(
        'INSERT INTO test_break_race_log (iteration) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_break_race_log))'
        ~> df.race(df.break('race-done'), 'SELECT pg_sleep(10)')
    ),
    'test-break-in-race'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_cnt INT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test_break_race_state;
    RAISE NOTICE 'Test 2 - df.break() in RACE branch: instance %', v_instance_id;

    SELECT df.wait_for_completion(v_instance_id, 50) INTO v_status;

    SELECT COUNT(*) INTO v_cnt FROM test_break_race_log;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [break-in-race]: expected completed, got %', v_status;
    END IF;

    -- Loop should have run exactly 1 iteration before the break exited it
    IF v_cnt != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [break-in-race]: expected 1 iteration, got % (loop did not exit on break)', v_cnt;
    END IF;

    RAISE NOTICE 'PASSED: df.break() in RACE winning branch exits the loop after 1 iteration';
END $$;

DROP TABLE _test_break_race_state;
DROP TABLE test_break_race_log;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
