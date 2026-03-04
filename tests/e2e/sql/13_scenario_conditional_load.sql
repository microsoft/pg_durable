-- Scenario Test: Conditional Logic
-- Based on USER_GUIDE.md Example 6: Conditional Logic
-- Tests task load checking with conditional logging

-- Clear logs from previous runs
DELETE FROM playground.logs WHERE msg LIKE '%task%' OR msg LIKE '%Task%';

-- Ensure we have pending tasks for the condition to be true
UPDATE playground.task_queue SET status = 'pending' WHERE id <= 4;

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Conditional: Check task queue load and log appropriate message
INSERT INTO _test_state SELECT df.start(
    df.if(
        'SELECT COUNT(*) > 3 FROM playground.task_queue 
         WHERE status = ''pending''',                                 -- condition: > 3 pending?
        'INSERT INTO playground.logs (msg, level) 
         VALUES (''High task load!'', ''warning'')',                  -- then: warn
        'INSERT INTO playground.logs (msg) 
         VALUES (''Task queue normal'')'                              -- else: normal
    ),
    'scenario-check-task-load'
);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    pending_count INT;
    log_entry TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing conditional task load: %', inst_id;
    
    -- Count pending tasks for reference
    SELECT COUNT(*) INTO pending_count 
    FROM playground.task_queue tq WHERE tq.status = 'pending';
    RAISE NOTICE 'Pending tasks: %', pending_count;

    SELECT df.wait_for_completion(inst_id) INTO inst_status;

    IF inst_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: conditional status = %', inst_status;
    END IF;
    
    -- Verify the correct branch was taken
    SELECT msg INTO log_entry 
    FROM playground.logs 
    WHERE msg LIKE '%task%' OR msg LIKE '%Task%'
    ORDER BY id DESC LIMIT 1;
    
    IF pending_count > 3 THEN
        IF log_entry NOT LIKE '%High task load%' THEN
            RAISE EXCEPTION 'TEST FAILED: expected high load warning, got %', log_entry;
        END IF;
    ELSE
        IF log_entry NOT LIKE '%normal%' THEN
            RAISE EXCEPTION 'TEST FAILED: expected normal message, got %', log_entry;
        END IF;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_conditional_load (pending=%, branch=%)', 
        pending_count, log_entry;
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
