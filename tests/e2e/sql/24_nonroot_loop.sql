-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Regression tests for: df.loop continue_as_new restarts from root when loop is not root
-- (https://github.com/microsoft/pg_durable/issues/227)
--
-- When a loop is not the root node of a function graph (i.e., there are prefix or suffix
-- nodes), continue_as_new must NOT re-execute the prefix or skip the suffix.  Loops are
-- now executed as a scoped sub-orchestration so continue_as_new is scoped to the loop
-- child, leaving the parent graph orchestration parked.

SET SESSION AUTHORIZATION df_e2e_user;

-- === Test 1: Non-root loop — prefix runs once, body runs N times ===
--
-- Graph: INSERT into prefix_table ~> df.loop(INSERT into body_table ~> break after 3)
-- Expected: prefix_table has exactly 1 row after completion, body_table has exactly 3 rows.

DROP TABLE IF EXISTS test_nonroot_prefix;
DROP TABLE IF EXISTS test_nonroot_body;
CREATE TABLE test_nonroot_prefix (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());
CREATE TABLE test_nonroot_body   (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _t1 AS
SELECT df.start(
    df.seq(
        'INSERT INTO test_nonroot_prefix DEFAULT VALUES',
        df.loop(
            'INSERT INTO test_nonroot_body DEFAULT VALUES'
            ~> (
                'SELECT COUNT(*) >= 3 FROM test_nonroot_body'
                    ?> df.break()
                    !> df.sleep(1)
            )
        )
    ),
    'test-nonroot-loop-prefix'
) AS instance_id;

DO $$
DECLARE
    v_id     TEXT;
    v_status TEXT;
    v_prefix INT;
    v_body   INT;
BEGIN
    SELECT instance_id INTO v_id FROM _t1;
    RAISE NOTICE 'Test 1 - non-root loop prefix: instance %', v_id;

    SELECT df.wait_for_completion(v_id, 90) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-prefix]: expected completed, got %', v_status;
    END IF;

    SELECT COUNT(*) INTO v_prefix FROM test_nonroot_prefix;
    SELECT COUNT(*) INTO v_body   FROM test_nonroot_body;

    IF v_prefix != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-prefix]: prefix ran % time(s) (expected 1); '
                        'prefix nodes must not be re-executed on each loop iteration', v_prefix;
    END IF;

    IF v_body != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-prefix]: body ran % time(s) (expected 3)', v_body;
    END IF;

    RAISE NOTICE 'PASSED: non-root loop prefix — prefix ran once, body ran 3 times';
END $$;

DROP TABLE _t1;
DROP TABLE test_nonroot_prefix;
DROP TABLE test_nonroot_body;

-- === Test 2: Non-root loop — prefix once, body N times, suffix once ===
--
-- Graph: INSERT prefix ~> df.loop(body, break after 2) ~> INSERT suffix
-- Expected: prefix_table = 1 row, body_table = 2 rows, suffix_table = 1 row.

DROP TABLE IF EXISTS test_nonroot2_prefix;
DROP TABLE IF EXISTS test_nonroot2_body;
DROP TABLE IF EXISTS test_nonroot2_suffix;
CREATE TABLE test_nonroot2_prefix (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());
CREATE TABLE test_nonroot2_body   (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());
CREATE TABLE test_nonroot2_suffix (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _t2 AS
SELECT df.start(
    df.seq(
        'INSERT INTO test_nonroot2_prefix DEFAULT VALUES',
        df.seq(
            df.loop(
                'INSERT INTO test_nonroot2_body DEFAULT VALUES'
                ~> (
                    'SELECT COUNT(*) >= 2 FROM test_nonroot2_body'
                        ?> df.break()
                        !> df.sleep(1)
                )
            ),
            'INSERT INTO test_nonroot2_suffix DEFAULT VALUES'
        )
    ),
    'test-nonroot-loop-prefix-suffix'
) AS instance_id;

DO $$
DECLARE
    v_id     TEXT;
    v_status TEXT;
    v_prefix INT;
    v_body   INT;
    v_suffix INT;
BEGIN
    SELECT instance_id INTO v_id FROM _t2;
    RAISE NOTICE 'Test 2 - non-root loop prefix+suffix: instance %', v_id;

    SELECT df.wait_for_completion(v_id, 90) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-suffix]: expected completed, got %', v_status;
    END IF;

    SELECT COUNT(*) INTO v_prefix FROM test_nonroot2_prefix;
    SELECT COUNT(*) INTO v_body   FROM test_nonroot2_body;
    SELECT COUNT(*) INTO v_suffix FROM test_nonroot2_suffix;

    IF v_prefix != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-suffix]: prefix ran % time(s) (expected 1)', v_prefix;
    END IF;

    IF v_body != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-suffix]: body ran % time(s) (expected 2)', v_body;
    END IF;

    IF v_suffix != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-suffix]: suffix ran % time(s) (expected 1)', v_suffix;
    END IF;

    RAISE NOTICE 'PASSED: non-root loop prefix+suffix — prefix once, body twice, suffix once';
END $$;

DROP TABLE _t2;
DROP TABLE test_nonroot2_prefix;
DROP TABLE test_nonroot2_body;
DROP TABLE test_nonroot2_suffix;

-- === Test 3: Non-root loop — named result from prefix available inside loop body ===
--
-- Verify that named results accumulated before the loop are still accessible
-- inside the loop body after continue_as_new (they are preserved in the loop
-- sub-orchestration's input).

DROP TABLE IF EXISTS test_nonroot3_log;
CREATE TABLE test_nonroot3_log (id SERIAL, val TEXT, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _t3 AS
SELECT df.start(
    df.seq(
        ('SELECT ''hello'' AS greeting' |=> 'prefix_result'),
        df.loop(
            ($$INSERT INTO test_nonroot3_log (val)
               VALUES ($prefix_result)
               RETURNING val$$
            |=> 'last_val')
            ~> (
                'SELECT COUNT(*) >= 2 FROM test_nonroot3_log'
                    ?> df.break()
                    !> df.sleep(1)
            )
        )
    ),
    'test-nonroot-loop-named-result'
) AS instance_id;

DO $$
DECLARE
    v_id     TEXT;
    v_status TEXT;
    v_cnt    INT;
    v_val    TEXT;
BEGIN
    SELECT instance_id INTO v_id FROM _t3;
    RAISE NOTICE 'Test 3 - non-root loop uses prefix named result: instance %', v_id;

    SELECT df.wait_for_completion(v_id, 90) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-named]: expected completed, got %', v_status;
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM test_nonroot3_log;
    IF v_cnt != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-named]: expected 2 rows, got %', v_cnt;
    END IF;

    SELECT val INTO v_val FROM test_nonroot3_log ORDER BY id LIMIT 1;
    IF v_val != 'hello' THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-named]: expected ''hello'', got ''%''', v_val;
    END IF;

    RAISE NOTICE 'PASSED: non-root loop uses prefix named result across iterations';
END $$;

DROP TABLE _t3;
DROP TABLE test_nonroot3_log;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
