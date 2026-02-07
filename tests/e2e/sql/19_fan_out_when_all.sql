-- Test: Fan-out/fan-in with df.when_all()
-- Tests dynamic parallel execution with array of workflows

DROP TABLE IF EXISTS test_fan_out_log;
CREATE TABLE test_fan_out_log (
    id SERIAL PRIMARY KEY,
    task_id INT,
    processed_at TIMESTAMPTZ DEFAULT now()
);

-- Test WHEN_ALL - execute multiple tasks in parallel
CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state
SELECT df.start(
    df.when_all('[
        "INSERT INTO test_fan_out_log (task_id) VALUES (1)",
        "INSERT INTO test_fan_out_log (task_id) VALUES (2)",
        "INSERT INTO test_fan_out_log (task_id) VALUES (3)",
        "INSERT INTO test_fan_out_log (task_id) VALUES (4)"
    ]'),
    'test-when-all'
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

-- Verify all tasks were executed
DO $$
DECLARE
    task_count INT;
    distinct_tasks INT;
BEGIN
    SELECT COUNT(*) INTO task_count FROM test_fan_out_log;
    SELECT COUNT(DISTINCT task_id) INTO distinct_tasks FROM test_fan_out_log;
    
    IF task_count != 4 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 4 tasks, got %', task_count;
    END IF;
    
    IF distinct_tasks != 4 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 4 distinct tasks, got %', distinct_tasks;
    END IF;
    
    RAISE NOTICE 'PASSED: when_all - all tasks executed in parallel';
END $$;

-- Cleanup
DROP TABLE _test_state;
DROP TABLE test_fan_out_log;
SELECT 'TEST PASSED' AS result;
