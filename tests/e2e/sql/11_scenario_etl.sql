-- Scenario Test: Multi-Step ETL Pipeline
-- Based on USER_GUIDE.md Example 3: Multi-Step ETL
-- Tests a realistic ETL workflow with cleanup, mark, and load steps

-- Clear any previous test data
DELETE FROM playground.target WHERE source_id >= 1001;
UPDATE playground.staging SET processed_at = NULL WHERE source_id >= 1001;

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- ETL Pipeline: cleanup old data, mark staging records, load to target
INSERT INTO _test_state SELECT df.start(
    'DELETE FROM playground.target 
     WHERE loaded_at < now() - interval ''1 day'''                    -- cleanup old
    ~> 'UPDATE playground.staging 
        SET processed_at = now() WHERE processed_at IS NULL'          -- mark for processing
    ~> 'INSERT INTO playground.target (data, source_id, processed_at) 
        SELECT data, source_id, processed_at FROM playground.staging 
        WHERE processed_at IS NOT NULL',                              -- load to target
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
    
    -- Verify staging records were marked
    SELECT COUNT(*) INTO staging_processed 
    FROM playground.staging WHERE processed_at IS NOT NULL;
    IF staging_processed < 3 THEN
        RAISE EXCEPTION 'TEST FAILED: expected at least 3 processed staging records, got %', staging_processed;
    END IF;
    
    -- Verify target was loaded
    SELECT COUNT(*) INTO target_count 
    FROM playground.target WHERE source_id IN (1001, 1002, 1003);
    IF target_count < 3 THEN
        RAISE EXCEPTION 'TEST FAILED: expected at least 3 target records, got %', target_count;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_etl (% staging marked, % target loaded)', staging_processed, target_count;
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;

