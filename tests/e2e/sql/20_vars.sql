-- E2E Test: Workflow Variables
-- Tests df.setvar(), df.getvar(), and {var} substitution

-- ============================================================================
-- Test 1: Simple variable substitution
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_vars_simple;
    RAISE NOTICE 'Testing simple vars: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: simple vars status = %', status;
    END IF;
    
    SELECT msg INTO log_msg FROM playground.logs ORDER BY id DESC LIMIT 1;
    IF log_msg NOT LIKE '%Hello%World%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected Hello World, got %', log_msg;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: vars_simple';
END $$;

DROP TABLE _test_vars_simple;

-- ============================================================================
-- Test 2: System variables
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_sys_vars;
    RAISE NOTICE 'Testing system vars: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
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

-- ============================================================================
-- Test 3: Vars in HTTP requests
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_vars_http;
    RAISE NOTICE 'Testing vars in HTTP: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: vars HTTP status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: vars_http';
END $$;

DROP TABLE _test_vars_http;

-- ============================================================================
-- Test 4: Multiple vars combined
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_vars_multi;
    RAISE NOTICE 'Testing multiple vars: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: multi vars status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: vars_multi';
END $$;

DROP TABLE _test_vars_multi;

-- ============================================================================
-- Test 5: setvar fails inside workflow
-- ============================================================================

SELECT df.clearvars();

CREATE TEMP TABLE _test_setvar_blocked (instance_id TEXT);

-- Try to call df.setvar() from within a workflow - should fail
INSERT INTO _test_setvar_blocked SELECT df.start(
    'SELECT df.setvar(''illegal_var'', ''should_fail'')',
    'test-setvar-blocked'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_error TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_setvar_blocked;
    RAISE NOTICE 'Testing setvar blocked in workflow: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    -- The workflow should FAIL because setvar is not allowed inside workflows
    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected workflow to fail but status = %', status;
    END IF;
    
    -- Check that the error mentions the restriction
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

-- ============================================================================
-- Cleanup
-- ============================================================================

SELECT df.clearvars();

SELECT 'TEST PASSED' AS result;

