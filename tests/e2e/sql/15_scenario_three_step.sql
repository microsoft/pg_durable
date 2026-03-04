-- Scenario Test: Sequential Steps (Three-step workflow)
-- Based on USER_GUIDE.md Example 2: Sequential Steps
-- Tests three sequential log inserts in order

-- Clear logs from previous runs
DELETE FROM playground.logs WHERE msg LIKE 'Step %';

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Three sequential steps
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO playground.logs (msg) VALUES (''Step 1: Starting'')'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Step 2: Processing'')'
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Step 3: Complete'')',
    'scenario-three-step'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    log_msgs TEXT[];
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing three-step workflow: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: three-step status = %', status;
    END IF;
    
    -- Verify all three steps logged in order
    SELECT array_agg(msg ORDER BY id) INTO log_msgs
    FROM playground.logs 
    WHERE msg LIKE 'Step %';
    
    IF array_length(log_msgs, 1) < 3 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 3 log entries, got %', log_msgs;
    END IF;
    
    IF log_msgs[1] NOT LIKE '%Starting%' OR 
       log_msgs[2] NOT LIKE '%Processing%' OR 
       log_msgs[3] NOT LIKE '%Complete%' THEN
        RAISE EXCEPTION 'TEST FAILED: steps not in order, got %', log_msgs;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_three_step';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;

