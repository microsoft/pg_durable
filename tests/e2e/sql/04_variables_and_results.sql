-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 03_variables, 20_vars, 39_named_results_dot, 41_row_set_expansion, 42_result_name_validation
-- Tests: variable substitution (|=> / df.as()), workflow variables (df.setvar/getvar),
--        named result dot-notation, null-safe accessor, row-set expansion, result name validation
-- Note: Test section from 20_vars includes an HTTP sub-test (requires --features http)
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 03_variables ===

DROP TABLE IF EXISTS test_vars_log;
CREATE TABLE test_vars_log (id SERIAL, val TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: Using |=> operator
INSERT INTO _test_state SELECT df.start(
    'SELECT 100 as num' |=> 'x'
    ~> 'INSERT INTO test_vars_log (val, variant) VALUES ($x::text, ''op'')',
    'test-variables-op'
), 'operator';

-- Variant B: Using df.as() function
INSERT INTO _test_state SELECT df.start(
    df.seq(
        df.as('SELECT 200 as num', 'y'),
        'INSERT INTO test_vars_log (val, variant) VALUES ($y::text, ''fn'')'
    ),
    'test-variables-fn'
), 'function';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    val_result TEXT;
    expected TEXT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;
        
        IF rec.variant = 'operator' THEN
            expected := '100';
            SELECT val INTO val_result FROM test_vars_log WHERE variant = 'op' ORDER BY id DESC LIMIT 1;
        ELSE
            expected := '200';
            SELECT val INTO val_result FROM test_vars_log WHERE variant = 'fn' ORDER BY id DESC LIMIT 1;
        END IF;
        
        IF val_result IS NULL OR val_result NOT LIKE '%' || expected || '%' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected value containing %, got %', rec.variant, expected, val_result;
        END IF;
        
        RAISE NOTICE 'PASSED: variables [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: variables (both variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_vars_log;

-- === Test: 20_vars ===

-- Test 1: Simple variable substitution
SELECT df.clearvars();
SELECT df.setvar('greeting', 'Hello');
SELECT df.setvar('target', 'World');

CREATE TEMP TABLE _test_vars_simple (instance_id TEXT);

INSERT INTO _test_vars_simple SELECT df.start(
    'SELECT ''{greeting}, {target}!'' as message' |=> 'msg'
    ~> 'INSERT INTO playground.logs (msg) VALUES ($msg)',
    'test-vars-simple'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    log_msg TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_vars_simple;
    RAISE NOTICE 'Testing simple vars: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: simple vars status = %', status;
    END IF;
    
    SELECT msg INTO log_msg FROM playground.logs ORDER BY id DESC LIMIT 1;
    IF log_msg NOT LIKE '%Hello%World%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected Hello World, got %', log_msg;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: vars_simple';
END $$;

DROP TABLE _test_vars_simple;

-- Test 2: System variables
SELECT df.clearvars();

CREATE TEMP TABLE _test_sys_vars (instance_id TEXT);

INSERT INTO _test_sys_vars SELECT df.start(
    'INSERT INTO playground.logs (msg) VALUES (''Instance: {sys_instance_id}, Label: {sys_label}'')
     RETURNING msg' |=> 'log_result',
    'test-sys-vars'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    log_msg TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_sys_vars;
    RAISE NOTICE 'Testing system vars: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: sys vars status = %', status;
    END IF;
    
    SELECT msg INTO log_msg FROM playground.logs WHERE msg LIKE 'Instance:%' ORDER BY id DESC LIMIT 1;
    IF log_msg NOT LIKE '%' || inst_id || '%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected instance_id in log, got %', log_msg;
    END IF;
    IF log_msg NOT LIKE '%test-sys-vars%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected label in log, got %', log_msg;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: sys_vars';
END $$;

DROP TABLE _test_sys_vars;

-- Test 3: Vars in HTTP requests (requires --features http)
SELECT df.clearvars();
SELECT df.setvar('api_base', 'https://httpbingo.org');

CREATE TEMP TABLE _test_vars_http (instance_id TEXT);

INSERT INTO _test_vars_http SELECT df.start(
    (df.http('{api_base}/get', 'GET') |=> 'response')
    ~> 'SELECT ($response::jsonb->>''ok'')::boolean as success',
    'test-vars-http'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_vars_http;
    RAISE NOTICE 'Testing vars in HTTP: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: vars HTTP status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: vars_http';
END $$;

DROP TABLE _test_vars_http;

-- Test 4: Multiple vars combined
SELECT df.clearvars();
SELECT df.setvar('table_name', 'users');
SELECT df.setvar('limit_val', '5');

CREATE TEMP TABLE _test_vars_multi (instance_id TEXT);

INSERT INTO _test_vars_multi SELECT df.start(
    'SELECT name FROM playground.{table_name} LIMIT {limit_val}::int' |=> 'names'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Fetched from {table_name}'')',
    'test-vars-multi'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_vars_multi;
    RAISE NOTICE 'Testing multiple vars: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: multi vars status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: vars_multi';
END $$;

DROP TABLE _test_vars_multi;

-- Test 5: setvar fails inside workflow
SELECT df.clearvars();

CREATE TEMP TABLE _test_setvar_blocked (instance_id TEXT);

INSERT INTO _test_setvar_blocked SELECT df.start(
    'SELECT df.setvar(''illegal_var'', ''should_fail'')',
    'test-setvar-blocked'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_error TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_setvar_blocked;
    RAISE NOTICE 'Testing setvar blocked in workflow: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected workflow to fail but status = %', status;
    END IF;
    
    SELECT n.result::text INTO node_error 
    FROM df.nodes n
    WHERE n.instance_id = inst_id AND n.status = 'failed'
    LIMIT 1;
    
    IF node_error NOT LIKE '%cannot be called inside a workflow%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "cannot be called inside a workflow" error, got: %', node_error;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: setvar_blocked_in_workflow';
END $$;

DROP TABLE _test_setvar_blocked;

SELECT df.clearvars();

-- === Test: 39_named_results_dot ===

-- Test 1: Dot-notation — access specific columns
DROP TABLE IF EXISTS test_dot_results;
CREATE TABLE test_dot_results (id SERIAL, got_id INT, got_content TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT 42 AS id, 'hello' AS content$$ |=> 'doc'
    ~> $$INSERT INTO test_dot_results (got_id, got_content) VALUES ($doc.id, $doc.content)$$,
    'test-dot-notation'
), 'dot';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    r_id INT;
    r_content TEXT;
BEGIN
    SELECT instance_id INTO rec FROM _test_state WHERE variant = 'dot';

    SELECT df.wait_for_completion(rec.instance_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [dot-notation]: status = %', status;
    END IF;

    SELECT got_id, got_content INTO r_id, r_content FROM test_dot_results ORDER BY id DESC LIMIT 1;

    IF r_id != 42 THEN
        RAISE EXCEPTION 'TEST FAILED [dot-notation]: expected id=42, got %', r_id;
    END IF;

    IF r_content != 'hello' THEN
        RAISE EXCEPTION 'TEST FAILED [dot-notation]: expected content=hello, got %', r_content;
    END IF;

    RAISE NOTICE 'PASSED: dot-notation';
END $$;

DROP TABLE _test_state;
DROP TABLE test_dot_results;

-- Test 2: Null-safe accessor — $name.col? substitutes NULL
DROP TABLE IF EXISTS test_nullsafe_results;
CREATE TABLE test_nullsafe_results (id SERIAL, val TEXT);

CREATE TEMP TABLE _test_state2 (instance_id TEXT);

INSERT INTO _test_state2 SELECT df.start(
    $$SELECT NULL::text AS val$$ |=> 'x'
    ~> $$INSERT INTO test_nullsafe_results (val) VALUES (COALESCE($x.val?, 'fallback'))$$,
    'test-null-safe'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    val_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state2;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [null-safe]: status = %', status;
    END IF;

    SELECT val INTO val_result FROM test_nullsafe_results ORDER BY id DESC LIMIT 1;

    IF val_result != 'fallback' THEN
        RAISE EXCEPTION 'TEST FAILED [null-safe]: expected fallback, got %', val_result;
    END IF;

    RAISE NOTICE 'PASSED: null-safe accessor';
END $$;

DROP TABLE _test_state2;
DROP TABLE test_nullsafe_results;

-- Test 3: Strict fail — $name on empty result fails the instance
CREATE TEMP TABLE _test_state3 (instance_id TEXT);

INSERT INTO _test_state3 SELECT df.start(
    $$SELECT 1 WHERE false$$ |=> 'empty'
    ~> $$SELECT $empty$$,
    'test-strict-fail'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state3;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [strict-fail]: expected failed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED: strict fail on no-rows';
END $$;

DROP TABLE _test_state3;

-- === Test: 41_row_set_expansion ===

-- Test 1: $batch.* in FROM clause — multi-row expansion
DROP TABLE IF EXISTS test_rowset_results;
CREATE TABLE test_rowset_results (id SERIAL, total_rows INT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT id, val FROM (VALUES (1, 'a'), (2, 'b'), (3, 'c')) AS t(id, val)$$ |=> 'batch'
    ~> $$INSERT INTO test_rowset_results (total_rows) SELECT count(*) FROM $batch.*$$,
    'test-rowset-from'
), 'from_clause';

-- Test 2: $batch.* in WHERE IN subquery
DROP TABLE IF EXISTS test_rowset_source;
CREATE TABLE test_rowset_source (id INT, name TEXT);
INSERT INTO test_rowset_source VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Carol'), (4, 'Dave');

DROP TABLE IF EXISTS test_rowset_filtered;
CREATE TABLE test_rowset_filtered (id SERIAL, cnt INT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT id FROM test_rowset_source WHERE id <= 2$$ |=> 'ids'
    ~> $$INSERT INTO test_rowset_filtered (cnt) SELECT count(*) FROM test_rowset_source WHERE id IN (SELECT id FROM $ids.*)$$,
    'test-rowset-where-in'
), 'where_in';

-- Test 3: Empty result set expansion — should not error
DROP TABLE IF EXISTS test_rowset_empty;
CREATE TABLE test_rowset_empty (id SERIAL, total_rows INT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT id FROM test_rowset_source WHERE false$$ |=> 'none'
    ~> $$INSERT INTO test_rowset_empty (total_rows) SELECT count(*) FROM $none.*$$,
    'test-rowset-empty'
), 'empty';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    int_val INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state ORDER BY variant LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;

        IF rec.variant = 'empty' THEN
            SELECT total_rows INTO int_val FROM test_rowset_empty ORDER BY id DESC LIMIT 1;
            IF int_val != 0 THEN
                RAISE EXCEPTION 'TEST FAILED [empty]: expected 0 rows, got %', int_val;
            END IF;

        ELSIF rec.variant = 'from_clause' THEN
            SELECT total_rows INTO int_val FROM test_rowset_results ORDER BY id ASC LIMIT 1;
            IF int_val != 3 THEN
                RAISE EXCEPTION 'TEST FAILED [from_clause]: expected 3 rows, got %', int_val;
            END IF;

        ELSIF rec.variant = 'where_in' THEN
            SELECT cnt INTO int_val FROM test_rowset_filtered ORDER BY id DESC LIMIT 1;
            IF int_val != 2 THEN
                RAISE EXCEPTION 'TEST FAILED [where_in]: expected 2 rows, got %', int_val;
            END IF;
        END IF;

        RAISE NOTICE 'PASSED: row-set expansion [%]', rec.variant;
    END LOOP;

    RAISE NOTICE 'TEST PASSED: row-set expansion (all variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_rowset_results;
DROP TABLE test_rowset_empty;
DROP TABLE test_rowset_filtered;
DROP TABLE test_rowset_source;

-- === Test: 42_result_name_validation ===

-- Test 1: Valid names should work
DROP TABLE IF EXISTS test_name_valid_results;
CREATE TABLE test_name_valid_results (id SERIAL, val INT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT 42 AS num$$ |=> 'my_result'
    ~> $$INSERT INTO test_name_valid_results (val) VALUES ($my_result)$$,
    'test-name-valid'
), 'valid_name';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE variant = 'valid_name';
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [valid_name]: status = %', status;
    END IF;

    RAISE NOTICE 'PASSED: valid result name accepted';
END $$;

-- Test 2: SQL injection attempt should be rejected at DSL time
DO $$
BEGIN
    PERFORM df.start(
        df.as(df.sql('SELECT 1'), 'x) UNION SELECT version()--')
        ~> df.sql('SELECT 1'),
        'test-injection'
    );
    RAISE EXCEPTION 'TEST FAILED: injection name was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%not a valid identifier%' THEN
            RAISE NOTICE 'PASSED: injection name correctly rejected: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected error: %', SQLERRM;
        END IF;
END $$;

-- Test 3: Name with spaces should be rejected
DO $$
BEGIN
    PERFORM df.sql('SELECT 1') |=> 'has space';
    RAISE EXCEPTION 'TEST FAILED: spaced name was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%not a valid identifier%' THEN
            RAISE NOTICE 'PASSED: spaced name correctly rejected: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected error: %', SQLERRM;
        END IF;
END $$;

-- Test 4: Name starting with digit should be rejected
DO $$
BEGIN
    PERFORM df.sql('SELECT 1') |=> '123abc';
    RAISE EXCEPTION 'TEST FAILED: digit-start name was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%not a valid identifier%' THEN
            RAISE NOTICE 'PASSED: digit-start name correctly rejected: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected error: %', SQLERRM;
        END IF;
END $$;

DROP TABLE _test_state;
DROP TABLE test_name_valid_results;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
