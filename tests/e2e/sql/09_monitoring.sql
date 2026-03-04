-- Test: Monitoring functions
-- Expected: list_instances, instance_info, status, result all work

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start('SELECT 123', 'test-monitoring-label');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    found BOOLEAN;
    info_status TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;
    
    -- Test list_instances
    SELECT EXISTS (
        SELECT 1 FROM df.list_instances() 
        WHERE list_instances.instance_id = inst_id
    ) INTO found;
    
    IF NOT found THEN
        RAISE EXCEPTION 'TEST FAILED: instance not found in list_instances()';
    END IF;
    
    -- Test instance_info
    SELECT i.status INTO info_status FROM df.instance_info(inst_id) i;
    IF info_status IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: instance_info returned NULL status';
    END IF;
    
    -- Test status
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed, got %', status;
    END IF;
    
    -- Test result
    SELECT r INTO result FROM df.result(inst_id) r;
    IF result NOT LIKE '%123%' THEN
        RAISE EXCEPTION 'TEST FAILED: result should contain 123, got %', result;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: monitoring';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
