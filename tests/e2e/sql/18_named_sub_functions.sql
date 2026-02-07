-- Test: Named sub-functions with df.define() and df.call()
-- Tests defining reusable workflow templates and calling them by name

DROP TABLE IF EXISTS test_named_func_log;
CREATE TABLE test_named_func_log (
    id SERIAL PRIMARY KEY,
    step TEXT,
    source TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Define a reusable sub-workflow
SELECT df.define(
    'log_step',
    'INSERT INTO test_named_func_log (step, source) VALUES (''from_named_func'', ''child'')',
    'Logs a step from a named function'
);

-- Verify the function was defined
DO $$
DECLARE
    func_exists BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM df.function_definitions WHERE name = 'log_step') INTO func_exists;
    IF NOT func_exists THEN
        RAISE EXCEPTION 'TEST FAILED: Named function was not defined';
    END IF;
END $$;

-- Verify df.list_functions() includes our function
DO $$
DECLARE
    func_list TEXT[];
BEGIN
    SELECT array_agg(name) INTO func_list FROM unnest(df.list_functions()) AS name;
    IF NOT 'log_step' = ANY(func_list) THEN
        RAISE EXCEPTION 'TEST FAILED: df.list_functions() did not include log_step';
    END IF;
END $$;

-- Start a parent workflow that calls the named function
CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state
SELECT df.start(
    df.seq(
        'INSERT INTO test_named_func_log (step, source) VALUES (''parent_start'', ''parent'')',
        df.seq(
            df.call('log_step'),
            'INSERT INTO test_named_func_log (step, source) VALUES (''parent_end'', ''parent'')'
        )
    ),
    'test-named-func-call'
);

-- Poll until complete (30s timeout)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %, instance = %', status, inst_id;
    END IF;
END $$;

-- Verify the execution
DO $$
DECLARE
    parent_count INT;
    child_count INT;
    total_count INT;
BEGIN
    SELECT COUNT(*) INTO parent_count FROM test_named_func_log WHERE source = 'parent';
    SELECT COUNT(*) INTO child_count FROM test_named_func_log WHERE source = 'child';
    SELECT COUNT(*) INTO total_count FROM test_named_func_log;
    
    IF parent_count != 2 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 2 parent steps, got %', parent_count;
    END IF;
    
    IF child_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 child step, got %', child_count;
    END IF;
    
    IF total_count != 3 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 3 total records, got %', total_count;
    END IF;
    
    RAISE NOTICE 'PASSED: named_sub_function - defined and called successfully';
END $$;

-- Test df.undefine()
SELECT df.undefine('log_step');

-- Verify the function was removed
DO $$
DECLARE
    func_exists BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM df.function_definitions WHERE name = 'log_step') INTO func_exists;
    IF func_exists THEN
        RAISE EXCEPTION 'TEST FAILED: Named function was not removed by df.undefine()';
    END IF;
END $$;

-- Cleanup
DROP TABLE _test_state;
DROP TABLE test_named_func_log;
SELECT 'TEST PASSED' AS result;
