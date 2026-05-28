-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 05_conditional_true, 06_conditional_false, 33_malformed_condition_node, 40_if_rows
-- Tests: conditional true branch, conditional false branch, malformed condition_node rejection,
--        df.if_rows() branching on result row presence
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 05_conditional_true ===

DROP TABLE IF EXISTS test_cond_log;
CREATE TABLE test_cond_log (id SERIAL, branch TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: df.if() function
INSERT INTO _test_state SELECT df.start(
    df.if(
        'SELECT true',
        'INSERT INTO test_cond_log (branch, variant) VALUES (''then'', ''func'')',
        'INSERT INTO test_cond_log (branch, variant) VALUES (''else'', ''func'')'
    ),
    'test-cond-true-func'
), 'func';

-- Variant B: ?> !> operators
INSERT INTO _test_state SELECT df.start(
    'SELECT true' 
        ?> 'INSERT INTO test_cond_log (branch, variant) VALUES (''then'', ''op'')'
        !> 'INSERT INTO test_cond_log (branch, variant) VALUES (''else'', ''op'')',
    'test-cond-true-op'
), 'op';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    branch_val TEXT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;
        
        SELECT branch INTO branch_val 
        FROM test_cond_log WHERE variant = rec.variant ORDER BY id DESC LIMIT 1;
        
        IF branch_val != 'then' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected then branch, got %', rec.variant, branch_val;
        END IF;
        
        RAISE NOTICE 'PASSED: conditional_true [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: conditional_true (func + ?> !> operators)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_cond_log;

-- === Test: 06_conditional_false ===

DROP TABLE IF EXISTS test_cond_false_log;
CREATE TABLE test_cond_false_log (id SERIAL, branch TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: df.if() function
INSERT INTO _test_state SELECT df.start(
    df.if(
        'SELECT false',
        'INSERT INTO test_cond_false_log (branch, variant) VALUES (''then'', ''func'')',
        'INSERT INTO test_cond_false_log (branch, variant) VALUES (''else'', ''func'')'
    ),
    'test-cond-false-func'
), 'func';

-- Variant B: ?> !> operators
INSERT INTO _test_state SELECT df.start(
    'SELECT false'
        ?> 'INSERT INTO test_cond_false_log (branch, variant) VALUES (''then'', ''op'')'
        !> 'INSERT INTO test_cond_false_log (branch, variant) VALUES (''else'', ''op'')',
    'test-cond-false-op'
), 'op';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    branch_val TEXT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;
        
        SELECT branch INTO branch_val 
        FROM test_cond_false_log WHERE variant = rec.variant ORDER BY id DESC LIMIT 1;
        
        IF branch_val != 'else' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected else branch, got %', rec.variant, branch_val;
        END IF;
        
        RAISE NOTICE 'PASSED: conditional_false [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: conditional_false (func + ?> !> operators)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_cond_false_log;

-- === Test: 33_malformed_condition_node ===

-- Test 1: condition_node as a non-Durofut object should be rejected by df.start()
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{
            "node_type": "IF",
            "left_node": {"node_type": "SQL", "query": "SELECT 1"},
            "right_node": {"node_type": "SQL", "query": "SELECT 2"},
            "query": "{\"condition_node\": {\"foo\": \"bar\"}}"
        }');
        RAISE EXCEPTION 'TEST FAILED: df.start should have rejected malformed condition_node';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%condition_node%' THEN
            RAISE NOTICE 'Test 1 PASSED: Caught malformed condition_node object: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: Wrong error for malformed condition_node: %', SQLERRM;
        END IF;
    END;
END $body$;

-- Test 2: condition_node as a string ID (old format) should be rejected
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{
            "node_type": "LOOP",
            "left_node": {"node_type": "SQL", "query": "SELECT 1"},
            "query": "{\"condition_node\": \"a1b2c3d4\"}"
        }');
        RAISE EXCEPTION 'TEST FAILED: df.start should have rejected string condition_node';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%condition_node%' THEN
            RAISE NOTICE 'Test 2 PASSED: Caught string condition_node: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: Wrong error for string condition_node: %', SQLERRM;
        END IF;
    END;
END $body$;

-- Test 3: condition_node as a number should be rejected
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{
            "node_type": "IF",
            "left_node": {"node_type": "SQL", "query": "SELECT 1"},
            "right_node": {"node_type": "SQL", "query": "SELECT 2"},
            "query": "{\"condition_node\": 42}"
        }');
        RAISE EXCEPTION 'TEST FAILED: df.start should have rejected numeric condition_node';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%condition_node%' THEN
            RAISE NOTICE 'Test 3 PASSED: Caught numeric condition_node: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: Wrong error for numeric condition_node: %', SQLERRM;
        END IF;
    END;
END $body$;

-- Test 4: Valid condition_node (produced by DSL) should work fine
DO $body$
DECLARE
    graph TEXT;
BEGIN
    SELECT df.if('SELECT true', 'SELECT 1', 'SELECT 2') INTO graph;
    IF graph IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: df.if should return non-null graph';
    END IF;
    RAISE NOTICE 'Test 4 PASSED: Valid IF graph produced: %', left(graph, 80);
END $body$;

-- === Test: 40_if_rows ===

-- Test 1: if_rows with rows present → then branch executes
DROP TABLE IF EXISTS test_if_rows_log;
CREATE TABLE test_if_rows_log (id SERIAL, branch TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT 1 AS val$$ |=> 'data'
    ~> df.if_rows(
        'data',
        $$INSERT INTO test_if_rows_log (branch, variant) VALUES ('then', 'has_rows')$$,
        $$INSERT INTO test_if_rows_log (branch, variant) VALUES ('else', 'has_rows')$$
    ),
    'test-if-rows-has-rows'
), 'has_rows';

-- Test 2: if_rows with zero rows → else branch executes
INSERT INTO _test_state SELECT df.start(
    $$SELECT 1 WHERE false$$ |=> 'empty'
    ~> df.if_rows(
        'empty',
        $$INSERT INTO test_if_rows_log (branch, variant) VALUES ('then', 'no_rows')$$,
        $$INSERT INTO test_if_rows_log (branch, variant) VALUES ('else', 'no_rows')$$
    ),
    'test-if-rows-no-rows'
), 'no_rows';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    branch_val TEXT;
    expected_branch TEXT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;

        IF rec.variant = 'has_rows' THEN
            expected_branch := 'then';
        ELSE
            expected_branch := 'else';
        END IF;

        SELECT branch INTO branch_val
        FROM test_if_rows_log
        WHERE variant = rec.variant
        ORDER BY id DESC LIMIT 1;

        IF branch_val != expected_branch THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected % branch, got %', rec.variant, expected_branch, branch_val;
        END IF;

        RAISE NOTICE 'PASSED: if_rows [%]', rec.variant;
    END LOOP;

    RAISE NOTICE 'TEST PASSED: if_rows (both variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_if_rows_log;

-- Test 3: if_rows combined with dot-notation in then branch
DROP TABLE IF EXISTS test_if_rows_dot;
CREATE TABLE test_if_rows_dot (id SERIAL, val INT);

CREATE TEMP TABLE _test_state2 (instance_id TEXT);

INSERT INTO _test_state2 SELECT df.start(
    $$SELECT 99 AS num$$ |=> 'result'
    ~> df.if_rows(
        'result',
        $$INSERT INTO test_if_rows_dot (val) VALUES ($result.num)$$,
        $$INSERT INTO test_if_rows_dot (val) VALUES (-1)$$
    ),
    'test-if-rows-dot'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    val_result INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state2;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [if_rows+dot]: status = %', status;
    END IF;

    SELECT val INTO val_result FROM test_if_rows_dot ORDER BY id DESC LIMIT 1;

    IF val_result != 99 THEN
        RAISE EXCEPTION 'TEST FAILED [if_rows+dot]: expected 99, got %', val_result;
    END IF;

    RAISE NOTICE 'PASSED: if_rows combined with dot-notation';
END $$;

DROP TABLE _test_state2;
DROP TABLE test_if_rows_dot;

-- Test 4: named result on the IF node itself is accessible downstream
DROP TABLE IF EXISTS test_if_named;
CREATE TABLE test_if_named (id SERIAL, chosen INT);

CREATE TEMP TABLE _test_if_named (instance_id TEXT);

INSERT INTO _test_if_named SELECT df.start(
    df.if(
        'SELECT true',
        'SELECT 41 AS chosen',
        'SELECT 99 AS chosen'
    ) |=> 'decision'
    ~> $$INSERT INTO test_if_named (chosen) VALUES ($decision.chosen)$$,
    'test-if-named-result'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    chosen_val INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_if_named;
    SELECT df.wait_for_completion(inst_id, 10) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [if-named]: status = %', status;
    END IF;

    SELECT chosen INTO chosen_val FROM test_if_named ORDER BY id DESC LIMIT 1;

    IF chosen_val != 41 THEN
        RAISE EXCEPTION 'TEST FAILED [if-named]: expected 41, got %', chosen_val;
    END IF;

    RAISE NOTICE 'PASSED: named IF result stored';
END $$;

DROP TABLE _test_if_named;
DROP TABLE test_if_named;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
