-- Scenario Test: Three-way Parallel Join
-- Tests df.join3() for parallel execution of three branches

DROP TABLE IF EXISTS test_join3_log;
CREATE TABLE test_join3_log (id SERIAL, branch TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Three branches in parallel
INSERT INTO _test_state SELECT df.start(
    df.join3(
        'INSERT INTO test_join3_log (branch) VALUES (''A'')',
        'INSERT INTO test_join3_log (branch) VALUES (''B'')',
        'INSERT INTO test_join3_log (branch) VALUES (''C'')'
    ),
    'scenario-join3'
);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    branch_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing join3: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO inst_status;

    IF inst_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: join3 status = %', inst_status;
    END IF;
    
    -- Verify all three branches executed
    SELECT COUNT(DISTINCT branch) INTO branch_count FROM test_join3_log;
    IF branch_count != 3 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 3 branches, got %', branch_count;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_join3';
END $$;

DROP TABLE _test_state;
DROP TABLE test_join3_log;
SELECT 'TEST PASSED' AS result;
