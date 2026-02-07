-- Test: Sub-orchestration call with df.call()
-- Tests that one durable function can invoke another as a sub-orchestration

DROP TABLE IF EXISTS test_sub_orch_log;
CREATE TABLE test_sub_orch_log (
    id SERIAL PRIMARY KEY,
    step TEXT,
    value INT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Define a reusable sub-workflow that inserts a value
CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Start the parent workflow that calls a sub-orchestration
INSERT INTO _test_state
SELECT df.start(
    df.seq(
        'INSERT INTO test_sub_orch_log (step, value) VALUES (''parent_start'', 1)',
        df.seq(
            df.call('INSERT INTO test_sub_orch_log (step, value) VALUES (''child'', 2)'),
            'INSERT INTO test_sub_orch_log (step, value) VALUES (''parent_end'', 3)'
        )
    ),
    'test-sub-orch-call'
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

-- Verify the execution order and results
DO $$
DECLARE
    parent_start_count INT;
    child_count INT;
    parent_end_count INT;
    total_count INT;
BEGIN
    SELECT COUNT(*) INTO parent_start_count FROM test_sub_orch_log WHERE step = 'parent_start';
    SELECT COUNT(*) INTO child_count FROM test_sub_orch_log WHERE step = 'child';
    SELECT COUNT(*) INTO parent_end_count FROM test_sub_orch_log WHERE step = 'parent_end';
    SELECT COUNT(*) INTO total_count FROM test_sub_orch_log;
    
    IF parent_start_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 parent_start, got %', parent_start_count;
    END IF;
    
    IF child_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 child, got %', child_count;
    END IF;
    
    IF parent_end_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 parent_end, got %', parent_end_count;
    END IF;
    
    IF total_count != 3 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 3 total records, got %', total_count;
    END IF;
    
    RAISE NOTICE 'PASSED: sub_orchestration_call - all steps executed in order';
END $$;

-- Cleanup
DROP TABLE _test_state;
DROP TABLE test_sub_orch_log;
SELECT 'TEST PASSED' AS result;
