-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: vars and label propagation into JOIN and RACE subtrees
-- Repro for: Bug: vars and label lost in JOIN/RACE subtrees
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: vars in JOIN branches (both branches) ===

DROP TABLE IF EXISTS test_join_vars_result;
CREATE TABLE test_join_vars_result (branch TEXT, val TEXT);

SELECT df.clearvars();
SELECT df.setvar('magic', '42');

CREATE TEMP TABLE _test_join_vars (instance_id TEXT);

INSERT INTO _test_join_vars SELECT df.start(
    'INSERT INTO test_join_vars_result VALUES (''left'', ''{magic}'')'
    & 'INSERT INTO test_join_vars_result VALUES (''right'', ''{magic}'')',
    'test-vars-in-join'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    left_val TEXT;
    right_val TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_join_vars;
    RAISE NOTICE 'Testing vars in JOIN branches: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-join]: status = %', status;
    END IF;

    SELECT val INTO left_val FROM test_join_vars_result WHERE branch = 'left';
    SELECT val INTO right_val FROM test_join_vars_result WHERE branch = 'right';

    IF left_val IS DISTINCT FROM '42' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-join]: left branch expected val=42, got %', left_val;
    END IF;

    IF right_val IS DISTINCT FROM '42' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-join]: right branch expected val=42, got %', right_val;
    END IF;

    RAISE NOTICE 'TEST PASSED: vars_in_join';
END $$;

DROP TABLE _test_join_vars;
DROP TABLE test_join_vars_result;

-- === Test: sys_label in JOIN branches (both branches) ===

DROP TABLE IF EXISTS test_join_label_result;
CREATE TABLE test_join_label_result (branch TEXT, lbl TEXT);

SELECT df.clearvars();

CREATE TEMP TABLE _test_join_label (instance_id TEXT);

INSERT INTO _test_join_label SELECT df.start(
    'INSERT INTO test_join_label_result VALUES (''left'', ''{sys_label}'')'
    & 'INSERT INTO test_join_label_result VALUES (''right'', ''{sys_label}'')',
    'test-label-in-join'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    left_lbl TEXT;
    right_lbl TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_join_label;
    RAISE NOTICE 'Testing sys_label in JOIN branches: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [label-in-join]: status = %', status;
    END IF;

    SELECT lbl INTO left_lbl FROM test_join_label_result WHERE branch = 'left';
    SELECT lbl INTO right_lbl FROM test_join_label_result WHERE branch = 'right';

    IF left_lbl IS DISTINCT FROM 'test-label-in-join' THEN
        RAISE EXCEPTION 'TEST FAILED [label-in-join]: left branch expected label "test-label-in-join", got %', left_lbl;
    END IF;

    IF right_lbl IS DISTINCT FROM 'test-label-in-join' THEN
        RAISE EXCEPTION 'TEST FAILED [label-in-join]: right branch expected label "test-label-in-join", got %', right_lbl;
    END IF;

    RAISE NOTICE 'TEST PASSED: label_in_join';
END $$;

DROP TABLE _test_join_label;
DROP TABLE test_join_label_result;

-- === Test: vars in RACE branches (both branches use var) ===

DROP TABLE IF EXISTS test_race_vars_result;
CREATE TABLE test_race_vars_result (val TEXT);

SELECT df.clearvars();
SELECT df.setvar('race_val', 'hello');

CREATE TEMP TABLE _test_race_vars (instance_id TEXT);

INSERT INTO _test_race_vars SELECT df.start(
    'INSERT INTO test_race_vars_result VALUES (''{race_val}'')'
    | 'INSERT INTO test_race_vars_result VALUES (''{race_val}'')',
    'test-vars-in-race'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    got_val TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_race_vars;
    RAISE NOTICE 'Testing vars in RACE branches: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-race]: status = %', status;
    END IF;

    SELECT val INTO got_val FROM test_race_vars_result LIMIT 1;

    IF got_val IS DISTINCT FROM 'hello' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-race]: expected val=hello, got %', got_val;
    END IF;

    RAISE NOTICE 'TEST PASSED: vars_in_race';
END $$;

DROP TABLE _test_race_vars;
DROP TABLE test_race_vars_result;

SELECT df.clearvars();

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
