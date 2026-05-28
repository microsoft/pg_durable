-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: named results from JOIN branches are propagated to the parent orchestration
-- Covers the bug where $left_val / $right_val were not accessible after a JOIN.
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test 1: named results from JOIN branches are accessible in subsequent steps ===

DROP TABLE IF EXISTS test_join_propagation;
CREATE TABLE test_join_propagation (id SERIAL, got_left INT, got_right INT);

CREATE TEMP TABLE _test_join_prop (instance_id TEXT);

INSERT INTO _test_join_prop SELECT df.start(
    (('SELECT 100 AS amount' |=> 'left_val') & ('SELECT 200 AS amount' |=> 'right_val'))
    ~> $$INSERT INTO test_join_propagation (got_left, got_right)
          VALUES ($left_val::int, $right_val::int)$$,
    'test-join-results-propagation'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    r_left  INT;
    r_right INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_join_prop;
    RAISE NOTICE 'Testing join results propagation: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;

    SELECT got_left, got_right INTO r_left, r_right
    FROM test_join_propagation ORDER BY id DESC LIMIT 1;

    IF r_left != 100 OR r_right != 200 THEN
        RAISE EXCEPTION 'TEST FAILED: expected (100, 200), got (%, %)', r_left, r_right;
    END IF;

    RAISE NOTICE 'PASSED: join results propagation (left=%, right=%)', r_left, r_right;
END $$;

DROP TABLE _test_join_prop;
DROP TABLE test_join_propagation;

-- === Test 2: named result on the JOIN node itself is also accessible ===

DROP TABLE IF EXISTS test_join_named;
CREATE TABLE test_join_named (id SERIAL, combined TEXT);

CREATE TEMP TABLE _test_join_named (instance_id TEXT);

INSERT INTO _test_join_named SELECT df.start(
    ('SELECT 1 AS x' & 'SELECT 2 AS x') |=> 'pair'
    ~> $$INSERT INTO test_join_named (combined) VALUES ($pair)$$,
    'test-join-named-result'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    r_combined TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_join_named;
    RAISE NOTICE 'Testing named JOIN result: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;

    SELECT combined INTO r_combined FROM test_join_named ORDER BY id DESC LIMIT 1;

    IF r_combined IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: combined result is NULL';
    END IF;

    RAISE NOTICE 'PASSED: named JOIN result stored (combined=%)', r_combined;
END $$;

DROP TABLE _test_join_named;
DROP TABLE test_join_named;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
