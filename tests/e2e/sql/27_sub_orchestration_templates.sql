-- Test: Sub-Orchestration using Templates
-- Tests df.call() to invoke templates as sub-orchestrations
-- Expected: Templates can be called from within durable functions

-- Cleanup
DO $$
DECLARE
    tpl RECORD;
BEGIN
    FOR tpl IN SELECT name FROM df.templates WHERE active = true AND name LIKE 'test_subo_%' LOOP
        PERFORM df.drop_template(tpl.name);
    END LOOP;
END $$;

DROP TABLE IF EXISTS test_suborchestration_log;
CREATE TABLE test_suborchestration_log (
    id SERIAL PRIMARY KEY,
    operation TEXT,
    value INT,
    ts TIMESTAMP DEFAULT now()
);

-- Test 1: Create templates to be used as sub-orchestrations
DO $$
DECLARE
    result TEXT;
BEGIN
    -- Child template 1: Simple SQL
    result := df.create_template(
        'test_subo_child1',
        'INSERT INTO test_suborchestration_log (operation, value) VALUES (''child1'', 10)',
        'Child template 1'
    );
    
    -- Child template 2: Another SQL
    result := df.create_template(
        'test_subo_child2',
        'INSERT INTO test_suborchestration_log (operation, value) VALUES (''child2'', 20)',
        'Child template 2'
    );
    
    -- Parent template: Calls both children in sequence
    result := df.create_template(
        'test_subo_parent',
        'df.call(''test_subo_child1'') ~> df.call(''test_subo_child2'')',
        'Parent template that calls children'
    );
    
    RAISE NOTICE 'Created sub-orchestration templates';
END $$;

-- Test 2: Execute parent template (which calls children)
CREATE TEMP TABLE _test_state (instance_id TEXT, test_name TEXT);

INSERT INTO _test_state SELECT df.start_template('test_subo_parent', 'test-subo-parent'), 'parent';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
    ops TEXT[];
    vals INT[];
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'parent';
    RAISE NOTICE 'Started parent template instance: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [sub-orchestration]: status = %', status;
    END IF;
    
    -- Verify both children executed
    SELECT array_agg(operation ORDER BY id), array_agg(value ORDER BY id) 
    INTO ops, vals
    FROM test_suborchestration_log;
    
    IF ops != ARRAY['child1', 'child2'] THEN
        RAISE EXCEPTION 'TEST FAILED [sub-orchestration]: expected [child1, child2], got %', ops;
    END IF;
    
    IF vals != ARRAY[10, 20] THEN
        RAISE EXCEPTION 'TEST FAILED [sub-orchestration]: expected [10, 20], got %', vals;
    END IF;
    
    RAISE NOTICE 'PASSED: sub-orchestration via templates';
END $$;

-- Test 3: Call inline graph (not a template)
TRUNCATE test_suborchestration_log;

INSERT INTO _test_state SELECT df.start(
    df.call('INSERT INTO test_suborchestration_log (operation, value) VALUES (''inline'', 30)'),
    'test-inline-call'
), 'inline';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
    cnt INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'inline';
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [inline call]: status = %', status;
    END IF;
    
    SELECT COUNT(*) INTO cnt FROM test_suborchestration_log WHERE operation = 'inline';
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [inline call]: expected 1 row, got %', cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: inline graph call';
END $$;

-- Cleanup
DO $$
DECLARE
    tpl RECORD;
BEGIN
    FOR tpl IN SELECT name FROM df.templates WHERE active = true AND name LIKE 'test_subo_%' LOOP
        PERFORM df.drop_template(tpl.name);
    END LOOP;
END $$;

DROP TABLE _test_state;
DROP TABLE test_suborchestration_log;
SELECT 'TEST PASSED' AS result;
