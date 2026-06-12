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

-- Regression: rolled-back df.start() should not inflate failed_instances in df.metrics()
DO $$
DECLARE
    total_metrics BIGINT;
    running_metrics BIGINT;
    completed_metrics BIGINT;
    failed_metrics BIGINT;
    previous_failed_metrics BIGINT := -1;
    stable_checks INT := 0;
    attempts INT := 0;
    total_instances BIGINT;
    running_instances BIGINT;
    completed_instances BIGINT;
    failed_instances BIGINT;
BEGIN
    BEGIN
        PERFORM df.start('SELECT 1', 'rollback-metrics-probe');
        RAISE EXCEPTION 'force rollback';
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    -- Worker waits up to 5s for an instance row after dequeue. Poll until
    -- failed_instances stabilizes for 3 checks after at least ~6s.
    LOOP
        SELECT m.failed_instances INTO failed_metrics FROM df.metrics() m;

        IF failed_metrics = previous_failed_metrics THEN
            stable_checks := stable_checks + 1;
        ELSE
            stable_checks := 0;
            previous_failed_metrics := failed_metrics;
        END IF;

        EXIT WHEN (attempts >= 12 AND stable_checks >= 3) OR attempts >= 60;
        PERFORM pg_sleep(0.5);
        attempts := attempts + 1;
    END LOOP;

    SELECT m.total_instances, m.running_instances, m.completed_instances, m.failed_instances
      INTO total_metrics, running_metrics, completed_metrics, failed_metrics
      FROM df.metrics() m;

    SELECT
        COUNT(*)::BIGINT,
        COUNT(*) FILTER (WHERE lower(status) = 'running')::BIGINT,
        COUNT(*) FILTER (WHERE lower(status) = 'completed')::BIGINT,
        COUNT(*) FILTER (WHERE lower(status) = 'failed')::BIGINT
      INTO total_instances, running_instances, completed_instances, failed_instances
      FROM df.instances;

    IF total_metrics != total_instances THEN
        RAISE EXCEPTION 'TEST FAILED: metrics total_instances=% does not match df.instances=%',
            total_metrics, total_instances;
    END IF;

    IF running_metrics != running_instances THEN
        RAISE EXCEPTION 'TEST FAILED: metrics running_instances=% does not match df.instances=%',
            running_metrics, running_instances;
    END IF;

    IF completed_metrics != completed_instances THEN
        RAISE EXCEPTION 'TEST FAILED: metrics completed_instances=% does not match df.instances=%',
            completed_metrics, completed_instances;
    END IF;

    IF failed_metrics != failed_instances THEN
        RAISE EXCEPTION 'TEST FAILED: metrics failed_instances=% does not match df.instances=%',
            failed_metrics, failed_instances;
    END IF;

    RAISE NOTICE 'TEST PASSED: rollback metrics consistency';
END $$;

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
