-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Regression tests for: df.loop whose body CONTAINS a JOIN or RACE
-- (https://github.com/microsoft/pg_durable/issues/230)
--
-- A loop iterates via continue_as_new.  Each generation that runs a JOIN/RACE inside the
-- body spawns child sub-orchestrations whose instance ids are derived from the loop's
-- current execution (generation).  If those child ids collided across generations the
-- second iteration would replay the first iteration's history ("instance already exists" /
-- stale subtree result).  The loop must run >= 2 iterations and every branch must run once
-- per iteration.

SET SESSION AUTHORIZATION df_e2e_user;

-- === Test 1: JOIN inside a NON-ROOT loop body, >= 3 iterations ===
--
-- Graph: INSERT prefix ~> df.loop( (INSERT left & INSERT right) ~> break after 3 )
-- Expected: prefix = 1 row, left = 3 rows, right = 3 rows (both branches every iteration).

DROP TABLE IF EXISTS test_loopjoin_prefix;
DROP TABLE IF EXISTS test_loopjoin_left;
DROP TABLE IF EXISTS test_loopjoin_right;
CREATE TABLE test_loopjoin_prefix (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());
CREATE TABLE test_loopjoin_left   (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());
CREATE TABLE test_loopjoin_right  (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _t1 AS
SELECT df.start(
    df.seq(
        'INSERT INTO test_loopjoin_prefix DEFAULT VALUES',
        df.loop(
            (
                'INSERT INTO test_loopjoin_left DEFAULT VALUES'
                & 'INSERT INTO test_loopjoin_right DEFAULT VALUES'
            )
            ~> (
                'SELECT COUNT(*) >= 3 FROM test_loopjoin_left'
                    ?> df.break()
                    !> df.sleep(1)
            )
        )
    ),
    'test-loop-contains-join'
) AS instance_id;

DO $$
DECLARE
    v_id     TEXT;
    v_status TEXT;
    v_prefix INT;
    v_left   INT;
    v_right  INT;
BEGIN
    SELECT instance_id INTO v_id FROM _t1;
    RAISE NOTICE 'Test 1 - JOIN inside loop body: instance %', v_id;

    SELECT df.wait_for_completion(v_id, 90) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-join]: expected completed, got %', v_status;
    END IF;

    SELECT COUNT(*) INTO v_prefix FROM test_loopjoin_prefix;
    SELECT COUNT(*) INTO v_left   FROM test_loopjoin_left;
    SELECT COUNT(*) INTO v_right  FROM test_loopjoin_right;

    IF v_prefix != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-join]: prefix ran % time(s) (expected 1)', v_prefix;
    END IF;

    IF v_left != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-join]: left branch ran % time(s) (expected 3)', v_left;
    END IF;

    IF v_right != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-join]: right branch ran % time(s) (expected 3)', v_right;
    END IF;

    RAISE NOTICE 'PASSED: JOIN inside loop body — both branches ran once per iteration (3 iterations)';
END $$;

DROP TABLE _t1;
DROP TABLE test_loopjoin_prefix;
DROP TABLE test_loopjoin_left;
DROP TABLE test_loopjoin_right;

-- === Test 2: RACE inside a NON-ROOT loop body, >= 2 iterations ===
--
-- Graph: INSERT prefix ~> df.loop( body ~> race(fast-or-break, slow) )
-- The race's first branch returns fast (no break) on iteration 1 and breaks on iteration 2,
-- so the loop runs exactly 2 iterations.  The slow branch (pg_sleep) never wins.

DROP TABLE IF EXISTS test_looprace_prefix;
DROP TABLE IF EXISTS test_looprace_log;
CREATE TABLE test_looprace_prefix (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());
CREATE TABLE test_looprace_log    (id SERIAL, iteration INT, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _t2 AS
SELECT df.start(
    df.seq(
        'INSERT INTO test_looprace_prefix DEFAULT VALUES',
        df.loop(
            'INSERT INTO test_looprace_log (iteration) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_looprace_log))'
            ~> df.race(
                df.if(
                    'SELECT COUNT(*) >= 2 FROM test_looprace_log',
                    df.break('race-done'),
                    'SELECT 1'
                ),
                'SELECT pg_sleep(30)'
            )
        )
    ),
    'test-loop-contains-race'
) AS instance_id;

DO $$
DECLARE
    v_id     TEXT;
    v_status TEXT;
    v_prefix INT;
    v_iters  INT;
BEGIN
    SELECT instance_id INTO v_id FROM _t2;
    RAISE NOTICE 'Test 2 - RACE inside loop body: instance %', v_id;

    SELECT df.wait_for_completion(v_id, 90) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-race]: expected completed, got %', v_status;
    END IF;

    SELECT COUNT(*) INTO v_prefix FROM test_looprace_prefix;
    SELECT COUNT(*) INTO v_iters  FROM test_looprace_log;

    IF v_prefix != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-race]: prefix ran % time(s) (expected 1)', v_prefix;
    END IF;

    IF v_iters != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-race]: loop ran % iteration(s) (expected 2)', v_iters;
    END IF;

    RAISE NOTICE 'PASSED: RACE inside loop body — loop ran 2 iterations and exited on break';
END $$;

DROP TABLE _t2;
DROP TABLE test_looprace_prefix;
DROP TABLE test_looprace_log;

SELECT 'TEST PASSED' AS result;
