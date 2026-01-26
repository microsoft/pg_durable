-- Test: df.start() with local_vars parameter
-- Verifies that:
-- 1. Local vars can be passed directly to df.start()
-- 2. Local vars override global vars on conflict
-- 3. Both global and local vars are available for substitution

-- Setup test table
DROP TABLE IF EXISTS test_local_vars_log;
CREATE TABLE test_local_vars_log (id SERIAL, var_name TEXT, var_value TEXT);

-- Set global variables
SELECT df.setvar('global_var', 'global_value');
SELECT df.setvar('override_var', 'global_override');

-- Test 1: Local vars only
CREATE TEMP TABLE _test_state (instance_id TEXT, test_name TEXT);

INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_local_vars_log (var_name, var_value) VALUES (''local_only'', ''{local_only}'')',
    'test-local-vars-only',
    jsonb_build_object('local_only', 'local_value')
), 'local_only';

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'local_only';
    RAISE NOTICE 'Test 1 - Local vars only: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (local_only): status = %', status;
    END IF;
END $$;

-- Verify local var was substituted
DO $$
DECLARE
    val TEXT;
BEGIN
    SELECT var_value INTO val FROM test_local_vars_log WHERE var_name = 'local_only';
    IF val != 'local_value' THEN
        RAISE EXCEPTION 'TEST FAILED (local_only): expected ''local_value'', got %', val;
    END IF;
    RAISE NOTICE 'Test 1 passed: local var substituted correctly';
END $$;

-- Test 2: Global vars only
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_local_vars_log (var_name, var_value) VALUES (''global_only'', ''{global_var}'')',
    'test-global-vars-only',
    NULL  -- No local vars
), 'global_only';

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'global_only';
    RAISE NOTICE 'Test 2 - Global vars only: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (global_only): status = %', status;
    END IF;
END $$;

-- Verify global var was substituted
DO $$
DECLARE
    val TEXT;
BEGIN
    SELECT var_value INTO val FROM test_local_vars_log WHERE var_name = 'global_only';
    IF val != 'global_value' THEN
        RAISE EXCEPTION 'TEST FAILED (global_only): expected ''global_value'', got %', val;
    END IF;
    RAISE NOTICE 'Test 2 passed: global var substituted correctly';
END $$;

-- Test 3: Local vars override global vars
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_local_vars_log (var_name, var_value) VALUES (''override'', ''{override_var}'')',
    'test-override',
    jsonb_build_object('override_var', 'local_override')
), 'override';

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'override';
    RAISE NOTICE 'Test 3 - Local overrides global: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (override): status = %', status;
    END IF;
END $$;

-- Verify local var overrode global var
DO $$
DECLARE
    val TEXT;
BEGIN
    SELECT var_value INTO val FROM test_local_vars_log WHERE var_name = 'override';
    IF val != 'local_override' THEN
        RAISE EXCEPTION 'TEST FAILED (override): expected ''local_override'', got %', val;
    END IF;
    RAISE NOTICE 'Test 3 passed: local var correctly overrode global var';
END $$;

-- Test 4: Mix of global and local vars
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_local_vars_log (var_name, var_value) 
     VALUES (''global'', ''{global_var}''), (''local'', ''{local_var}'')',
    'test-mixed',
    jsonb_build_object('local_var', 'local_mixed')
), 'mixed';

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'mixed';
    RAISE NOTICE 'Test 4 - Mixed global and local: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (mixed): status = %', status;
    END IF;
END $$;

-- Verify both global and local vars were substituted
DO $$
DECLARE
    global_val TEXT;
    local_val TEXT;
BEGIN
    SELECT var_value INTO global_val FROM test_local_vars_log 
    WHERE var_name = 'global' AND var_value = 'global_value';
    
    SELECT var_value INTO local_val FROM test_local_vars_log 
    WHERE var_name = 'local' AND var_value = 'local_mixed';
    
    IF global_val IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED (mixed): global var not substituted';
    END IF;
    
    IF local_val IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED (mixed): local var not substituted';
    END IF;
    
    RAISE NOTICE 'Test 4 passed: both global and local vars substituted correctly';
END $$;

-- Test 5: Different data types in local_vars (string, number, boolean)
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_local_vars_log (var_name, var_value) 
     VALUES 
       (''string_val'', ''{str_var}''),
       (''number_val'', ''{num_var}''),
       (''bool_val'', ''{bool_var}'')',
    'test-types',
    jsonb_build_object(
        'str_var', 'hello',
        'num_var', 42,
        'bool_var', true
    )
), 'types';

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'types';
    RAISE NOTICE 'Test 5 - Data types: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (types): status = %', status;
    END IF;
END $$;

-- Verify different data types were handled correctly
DO $$
DECLARE
    str_val TEXT;
    num_val TEXT;
    bool_val TEXT;
BEGIN
    SELECT var_value INTO str_val FROM test_local_vars_log WHERE var_name = 'string_val';
    SELECT var_value INTO num_val FROM test_local_vars_log WHERE var_name = 'number_val';
    SELECT var_value INTO bool_val FROM test_local_vars_log WHERE var_name = 'bool_val';
    
    IF str_val != 'hello' THEN
        RAISE EXCEPTION 'TEST FAILED (types): string value incorrect: %', str_val;
    END IF;
    
    IF num_val != '42' THEN
        RAISE EXCEPTION 'TEST FAILED (types): number value incorrect: %', num_val;
    END IF;
    
    IF bool_val != 'true' THEN
        RAISE EXCEPTION 'TEST FAILED (types): boolean value incorrect: %', bool_val;
    END IF;
    
    RAISE NOTICE 'Test 5 passed: different data types handled correctly';
END $$;

-- Cleanup
DROP TABLE _test_state;
DROP TABLE test_local_vars_log;
SELECT df.unsetvar('global_var');
SELECT df.unsetvar('override_var');

SELECT 'TEST PASSED' AS result;
