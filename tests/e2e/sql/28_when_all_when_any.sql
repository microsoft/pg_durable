-- Test: Parallel Execution with when_all and when_any
-- Tests df.when_all() and df.when_any() for parallel workflow execution
-- Expected: Multiple workflows execute in parallel

DROP TABLE IF EXISTS test_parallel_log;
CREATE TABLE test_parallel_log (
    id SERIAL PRIMARY KEY,
    workflow_id INT,
    value TEXT,
    ts TIMESTAMP DEFAULT now()
);

CREATE TEMP TABLE _test_state (instance_id TEXT, test_name TEXT);

-- Test 1: when_all with inline workflows
INSERT INTO _test_state SELECT df.start(
    df.when_all('["INSERT INTO test_parallel_log (workflow_id, value) VALUES (1, ''w1'')", "INSERT INTO test_parallel_log (workflow_id, value) VALUES (2, ''w2'')", "INSERT INTO test_parallel_log (workflow_id, value) VALUES (3, ''w3'')"]'),
    'test-when-all'
), 'when_all';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
    cnt INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'when_all';
    RAISE NOTICE 'Started when_all instance: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [when_all]: status = %', status;
    END IF;
    
    -- Verify all 3 workflows executed
    SELECT COUNT(*) INTO cnt FROM test_parallel_log WHERE workflow_id IN (1, 2, 3);
    IF cnt != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [when_all]: expected 3 rows, got %', cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: when_all with inline workflows';
END $$;

-- Test 2: when_all with templates
TRUNCATE test_parallel_log;

-- Create templates for parallel execution
DO $$
DECLARE
    result TEXT;
    tpl RECORD;
BEGIN
    -- Clean up any existing test templates
    FOR tpl IN SELECT name FROM df.templates WHERE active = true AND name LIKE 'test_parallel_%' LOOP
        PERFORM df.drop_template(tpl.name);
    END LOOP;
    
    result := df.create_template(
        'test_parallel_task1',
        'INSERT INTO test_parallel_log (workflow_id, value) VALUES (10, ''task1'')',
        'Parallel task 1'
    );
    
    result := df.create_template(
        'test_parallel_task2',
        'INSERT INTO test_parallel_log (workflow_id, value) VALUES (20, ''task2'')',
        'Parallel task 2'
    );
    
    result := df.create_template(
        'test_parallel_task3',
        'INSERT INTO test_parallel_log (workflow_id, value) VALUES (30, ''task3'')',
        'Parallel task 3'
    );
    
    RAISE NOTICE 'Created parallel task templates';
END $$;

INSERT INTO _test_state SELECT df.start(
    df.when_all('["test_parallel_task1", "test_parallel_task2", "test_parallel_task3"]'),
    'test-when-all-templates'
), 'when_all_templates';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
    cnt INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'when_all_templates';
    RAISE NOTICE 'Started when_all with templates: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [when_all templates]: status = %', status;
    END IF;
    
    -- Verify all 3 template executions completed
    SELECT COUNT(*) INTO cnt FROM test_parallel_log WHERE workflow_id IN (10, 20, 30);
    IF cnt != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [when_all templates]: expected 3 rows, got %', cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: when_all with templates';
END $$;

-- Test 3: when_any (race condition)
TRUNCATE test_parallel_log;

INSERT INTO _test_state SELECT df.start(
    df.when_any('["INSERT INTO test_parallel_log (workflow_id, value) VALUES (100, ''first'')", "INSERT INTO test_parallel_log (workflow_id, value) VALUES (101, ''second'')"]'),
    'test-when-any'
), 'when_any';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
    cnt INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'when_any';
    RAISE NOTICE 'Started when_any instance: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [when_any]: status = %', status;
    END IF;
    
    -- At least one should have executed (could be 1 or 2 depending on timing)
    SELECT COUNT(*) INTO cnt FROM test_parallel_log WHERE workflow_id IN (100, 101);
    IF cnt < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [when_any]: expected at least 1 row, got %', cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: when_any (race)';
END $$;

-- Test 4: when_all with concurrency limit
TRUNCATE test_parallel_log;

INSERT INTO _test_state SELECT df.start(
    df.when_all('["INSERT INTO test_parallel_log (workflow_id, value) VALUES (200, ''c1'')", "INSERT INTO test_parallel_log (workflow_id, value) VALUES (201, ''c2'')", "INSERT INTO test_parallel_log (workflow_id, value) VALUES (202, ''c3'')", "INSERT INTO test_parallel_log (workflow_id, value) VALUES (203, ''c4'')"]', 2),
    'test-when-all-limit'
), 'when_all_limit';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
    cnt INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'when_all_limit';
    RAISE NOTICE 'Started when_all with concurrency limit: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [when_all with limit]: status = %', status;
    END IF;
    
    -- All 4 should complete despite concurrency limit
    SELECT COUNT(*) INTO cnt FROM test_parallel_log WHERE workflow_id IN (200, 201, 202, 203);
    IF cnt != 4 THEN
        RAISE EXCEPTION 'TEST FAILED [when_all with limit]: expected 4 rows, got %', cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: when_all with concurrency limit';
END $$;

-- Cleanup
DO $$
DECLARE
    tpl RECORD;
BEGIN
    FOR tpl IN SELECT name FROM df.templates WHERE active = true AND name LIKE 'test_parallel_%' LOOP
        PERFORM df.drop_template(tpl.name);
    END LOOP;
END $$;

DROP TABLE _test_state;
DROP TABLE test_parallel_log;
SELECT 'TEST PASSED' AS result;
