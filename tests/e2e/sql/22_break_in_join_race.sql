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

-- === Test 3: df.break() at the top level (outside any loop) fails with a clear error ===
-- Before issue #148 the break sentinel travelled as a normal Ok result, so a top-level
-- df.break() would COMPLETE the instance with a `{"__break__": true, ...}` value. With the
-- typed NodeError::Break, an uncaught break surfaces as a failure instead.

CREATE TEMP TABLE _test_break_toplevel_state AS
SELECT df.start(
    df.break('top-level-oops'),
    'test-break-top-level'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test_break_toplevel_state;
    RAISE NOTICE 'Test 3 - top-level df.break(): instance %', v_instance_id;

    SELECT df.wait_for_completion(v_instance_id, 50) INTO v_status;

    -- The key behavioural change: an uncaught break is a failure, not a completed
    -- instance carrying a break sentinel as its result.
    IF v_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [break-top-level]: expected failed (break outside a loop), got %', v_status;
    END IF;

    RAISE NOTICE 'PASSED: top-level df.break() fails instead of completing with a sentinel';
END $$;

DROP TABLE _test_break_toplevel_state;

-- === Test 4: df.break() nested in an IF inside a JOIN branch inside a loop exits the loop ===
-- Acceptance criterion for issue #148: `df.if(..., df.break('x'), ...)` inside a JOIN inside a
-- loop correctly exits the outer loop. Exercises the deepest propagation path:
-- BREAK -> IF branch -> JOIN branch (subtree boundary, re-raised from the SubtreeEnvelope) ->
-- enclosing loop. Every compound node must unwind the break via `?` for the loop to exit; if
-- any link swallowed it, the loop would spin forever instead of completing after one iteration.

DROP TABLE IF EXISTS test_break_nested_log;
CREATE TABLE test_break_nested_log (id SERIAL, iteration INT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_break_nested_state AS
SELECT df.start(
    df.loop(
        'INSERT INTO test_break_nested_log (iteration) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_break_nested_log))'
        ~> (
            df.if(
                'SELECT COUNT(*) >= 1 FROM test_break_nested_log',
                df.break('nested-done'),
                'SELECT ''keep-going'''
            ) & 'SELECT ''other_branch'''
        )
    ),
    'test-break-nested-if-in-join'
) AS instance_id;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
    v_cnt INT;
    v_result TEXT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test_break_nested_state;
    RAISE NOTICE 'Test 4 - df.break() in IF in JOIN in loop: instance %', v_instance_id;

    SELECT df.wait_for_completion(v_instance_id, 50) INTO v_status;

    SELECT COUNT(*) INTO v_cnt FROM test_break_nested_log;
    SELECT df.result(v_instance_id) INTO v_result;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [break-nested]: expected completed, got %', v_status;
    END IF;

    -- Iteration 1: count is 1 (>= 1), the IF takes the break branch. The break unwinds out of
    -- the IF, out of the JOIN, and is caught by the loop, which exits after a single iteration.
    IF v_cnt != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [break-nested]: expected 1 iteration, got % (nested break did not exit the loop)', v_cnt;
    END IF;

    -- The break value must propagate intact to the loop result. df.break('nested-done')
    -- surfaces as the JSON-encoded string "nested-done" (quotes included); assert exact
    -- equality (not a substring match) so a corrupted or wrapped value is caught. IS DISTINCT
    -- FROM also fails safely if the result is NULL.
    IF v_result IS DISTINCT FROM '"nested-done"' THEN
        RAISE EXCEPTION 'TEST FAILED [break-nested]: expected loop result "nested-done", got %', v_result;
    END IF;

    RAISE NOTICE 'PASSED: df.break() nested in IF-in-JOIN exits the enclosing loop with the break value';
END $$;

DROP TABLE _test_break_nested_state;
DROP TABLE test_break_nested_log;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
