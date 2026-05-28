-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 11_scenario_etl, 12_scenario_parallel_counts, 13_scenario_conditional_load,
--              14_scenario_order_processing, 15_scenario_three_step
-- Tests: multi-step ETL pipeline, parallel counting, conditional branching on task load,
--        order processing with variable substitution, sequential three-step workflow
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 11_scenario_etl ===

-- Clear any previous test data
DELETE FROM playground.target WHERE source_id >= 1001;
UPDATE playground.staging SET processed_at = NULL WHERE source_id >= 1001;

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    'DELETE FROM playground.target 
     WHERE loaded_at < now() - interval ''1 day'''
    ~> 'UPDATE playground.staging 
        SET processed_at = now() WHERE processed_at IS NULL'
    ~> 'INSERT INTO playground.target (data, source_id, processed_at) 
        SELECT data, source_id, processed_at FROM playground.staging 
        WHERE processed_at IS NOT NULL',
    'scenario-etl-pipeline'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    target_count INT;
    staging_processed INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing ETL pipeline: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: ETL status = %', status;
    END IF;
    
    SELECT COUNT(*) INTO staging_processed 
    FROM playground.staging WHERE processed_at IS NOT NULL;
    IF staging_processed < 3 THEN
        RAISE EXCEPTION 'TEST FAILED: expected at least 3 processed staging records, got %', staging_processed;
    END IF;
    
    SELECT COUNT(*) INTO target_count 
    FROM playground.target WHERE source_id IN (1001, 1002, 1003);
    IF target_count < 3 THEN
        RAISE EXCEPTION 'TEST FAILED: expected at least 3 target records, got %', target_count;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_etl (% staging marked, % target loaded)', staging_processed, target_count;
END $$;

DROP TABLE _test_state;

-- === Test: 12_scenario_parallel_counts ===

DELETE FROM playground.logs WHERE msg LIKE '%Parallel counts%';

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.join(
        'SELECT COUNT(*) as user_count FROM playground.users',
        'SELECT COUNT(*) as order_count FROM playground.orders'
    )
    ~> 'INSERT INTO playground.logs (msg) VALUES (''Parallel counts complete'')',
    'scenario-parallel-counts'
);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    log_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing parallel counts: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO inst_status;

    IF inst_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: parallel counts status = %', inst_status;
    END IF;
    
    SELECT COUNT(*) INTO log_count 
    FROM playground.logs WHERE msg LIKE '%Parallel counts complete%';
    IF log_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: expected completion log entry, got %', log_count;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_parallel_counts';
END $$;

DROP TABLE _test_state;

-- === Test: 13_scenario_conditional_load ===

DELETE FROM playground.logs WHERE msg LIKE '%task%' OR msg LIKE '%Task%';
UPDATE playground.task_queue SET status = 'pending' WHERE id <= 4;

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.if(
        'SELECT COUNT(*) > 3 FROM playground.task_queue 
         WHERE status = ''pending''',
        'INSERT INTO playground.logs (msg, level) 
         VALUES (''High task load!'', ''warning'')',
        'INSERT INTO playground.logs (msg) 
         VALUES (''Task queue normal'')'
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
    
    SELECT COUNT(*) INTO pending_count 
    FROM playground.task_queue tq WHERE tq.status = 'pending';
    RAISE NOTICE 'Pending tasks: %', pending_count;

    SELECT df.wait_for_completion(inst_id) INTO inst_status;

    IF inst_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: conditional status = %', inst_status;
    END IF;
    
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

-- === Test: 14_scenario_order_processing ===

UPDATE playground.orders SET status = 'pending', processed_at = NULL WHERE id = 1;

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    'SELECT id FROM playground.orders 
     WHERE status = ''pending'' LIMIT 1' |=> 'order_id'
    ~> 'UPDATE playground.orders 
        SET status = ''processing'' WHERE id = $order_id'
    ~> df.sleep(1)
    ~> 'UPDATE playground.orders 
        SET status = ''completed'', processed_at = now() 
        WHERE id = $order_id',
    'scenario-process-order'
);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    processed_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing order processing: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 50) INTO inst_status;

    IF inst_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: order processing status = %', inst_status;
    END IF;
    
    SELECT COUNT(*) INTO processed_count 
    FROM playground.orders o
    WHERE o.status = 'completed' AND o.processed_at IS NOT NULL;
    
    IF processed_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: expected at least 1 completed order, got %', processed_count;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_order_processing (% orders completed)', processed_count;
END $$;

DROP TABLE _test_state;

-- === Test: 15_scenario_three_step ===

DELETE FROM playground.logs WHERE msg LIKE 'Step %';

CREATE TEMP TABLE _test_state (instance_id TEXT);

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

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
