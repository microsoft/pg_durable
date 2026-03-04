-- Test: Explain functionality
-- Expected: explain() returns visual representation

-- Test dry-run explain (use $body$ to avoid conflict with inner $$)
DO $body$
DECLARE
    explain_output TEXT;
BEGIN
    SELECT df.explain($$ 'SELECT 1' ~> 'SELECT 2' $$) INTO explain_output;
    
    IF explain_output IS NULL OR explain_output = '' THEN
        RAISE EXCEPTION 'TEST FAILED: explain returned empty output';
    END IF;
    
    IF explain_output NOT LIKE '%SQL%' THEN
        RAISE EXCEPTION 'TEST FAILED: explain should contain SQL nodes, got: %', explain_output;
    END IF;
    
    RAISE NOTICE 'Dry-run explain passed';
END $body$;

-- Test live instance explain
CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start('SELECT 1' ~> 'SELECT 2', 'test-explain');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    explain_output TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;
    
    SELECT df.explain(inst_id) INTO explain_output;
    
    IF explain_output IS NULL OR explain_output = '' THEN
        RAISE EXCEPTION 'TEST FAILED: explain returned empty output for live instance';
    END IF;
    
    IF explain_output NOT LIKE '%ompleted%' AND explain_output NOT LIKE '%✓%' THEN
        RAISE EXCEPTION 'TEST FAILED: explain should show completion status, got: %', explain_output;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: explain';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
