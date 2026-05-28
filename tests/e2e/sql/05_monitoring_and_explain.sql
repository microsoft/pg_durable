-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 09_monitoring, 10_explain, 31_explain_plain_sql
-- Tests: list_instances, instance_info, status, result, df.explain() on live and dry-run,
--        df.explain() on plain SQL auto-wrap
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 09_monitoring ===

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

-- === Test: 10_explain ===

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

-- === Test: 31_explain_plain_sql ===

DO $body$
DECLARE
    explain_output TEXT;
BEGIN
    SELECT df.explain('SELECT 1') INTO explain_output;

    IF explain_output IS NULL OR explain_output = '' THEN
        RAISE EXCEPTION 'TEST FAILED: explain returned empty output';
    END IF;

    IF explain_output NOT LIKE '%SQL:%' OR explain_output NOT LIKE '%SELECT 1%' THEN
        RAISE EXCEPTION 'TEST FAILED: explain should show SQL: SELECT 1, got: %', explain_output;
    END IF;

    RAISE NOTICE 'TEST PASSED: explain plain SQL';
END $body$;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
