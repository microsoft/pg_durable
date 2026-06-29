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

    SELECT df.await_instance(inst_id) INTO status;
    
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

-- Test dry-run explain renders RACE branches for both operator and function forms
DO $body$
DECLARE
    explain_output TEXT;
BEGIN
    SELECT df.explain($$ 'SELECT ''winner''' | df.sleep(30) $$) INTO explain_output;

    IF explain_output NOT LIKE '%RACE%'
        OR explain_output NOT LIKE '%branch 1:%'
        OR explain_output NOT LIKE '%branch 2:%'
        OR explain_output NOT LIKE '%SELECT ''winner''%'
        OR explain_output NOT LIKE '%SLEEP 30s%' THEN
        RAISE EXCEPTION 'TEST FAILED: operator RACE explain should show both branches, got: %', explain_output;
    END IF;

    SELECT df.explain($$ df.race('SELECT ''winner''', df.sleep(30)) $$) INTO explain_output;

    IF explain_output NOT LIKE '%RACE%'
        OR explain_output NOT LIKE '%branch 1:%'
        OR explain_output NOT LIKE '%branch 2:%'
        OR explain_output NOT LIKE '%SELECT ''winner''%'
        OR explain_output NOT LIKE '%SLEEP 30s%' THEN
        RAISE EXCEPTION 'TEST FAILED: df.race() explain should show both branches, got: %', explain_output;
    END IF;

    RAISE NOTICE 'Dry-run RACE explain passed';
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

    SELECT df.await_instance(inst_id) INTO status;
    
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

-- Test live RACE explain shows the skipped losing branch
CREATE TEMP TABLE _test_race_explain_state (instance_id TEXT);

INSERT INTO _test_race_explain_state
SELECT df.start(df.race('SELECT ''winner''', df.sleep(10)), 'test-race-explain');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    explain_output TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_race_explain_state;

    SELECT df.await_instance(inst_id, 20) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed RACE instance, got %', status;
    END IF;

    SELECT df.explain(inst_id) INTO explain_output;

    IF explain_output NOT LIKE '%RACE%'
        OR explain_output NOT LIKE '%branch 1:%'
        OR explain_output NOT LIKE '%branch 2:%'
        OR explain_output NOT LIKE '%SELECT ''winner''%'
        OR explain_output NOT LIKE '%SLEEP 10s%' THEN
        RAISE EXCEPTION 'TEST FAILED: live RACE explain should show both branches, got: %', explain_output;
    END IF;

    IF explain_output NOT LIKE '%⊘%' THEN
        RAISE EXCEPTION 'TEST FAILED: live RACE explain should show skipped marker for losing branch, got: %', explain_output;
    END IF;

    RAISE NOTICE 'TEST PASSED: live race explain';
END $$;

DROP TABLE _test_race_explain_state;

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

-- === Test: multi-instance list ordering + list/instance_info equivalence ===
-- Exercises the batched instance-info reassembly in df.list_instances(): start
-- several same-user instances with distinct outputs, then assert (a) they appear
-- newest-first (created_at DESC) in list_instances(), and (b) function_name,
-- execution_count, and output for each agree with df.instance_info() (the
-- per-instance path), proving the batch lookup reassembles the right metadata
-- against the right id.

CREATE TEMP TABLE _multi_state (n INT, instance_id TEXT);

-- Start three instances in separate statements (separate transactions) with a
-- short gap so created_at (DEFAULT now(), the transaction timestamp) is strictly
-- increasing and the created_at DESC order is deterministic.
INSERT INTO _multi_state SELECT 1, df.start('SELECT 1001', 'sf3-a');
SELECT pg_sleep(0.05);
INSERT INTO _multi_state SELECT 2, df.start('SELECT 1002', 'sf3-b');
SELECT pg_sleep(0.05);
INSERT INTO _multi_state SELECT 3, df.start('SELECT 1003', 'sf3-c');

DO $multi$
DECLARE
    ids TEXT[];
    expected_order TEXT[];
    listed_order TEXT[];
    rec RECORD;
    li RECORD;
    ii RECORD;
    settled INT;
    attempts INT := 0;
BEGIN
    -- Await all three to completion.
    FOR rec IN SELECT instance_id FROM _multi_state LOOP
        PERFORM df.await_instance(rec.instance_id);
    END LOOP;

    SELECT array_agg(instance_id ORDER BY n) INTO ids FROM _multi_state;
    -- created_at DESC => most recently started first => reverse of start order.
    SELECT array_agg(instance_id ORDER BY n DESC) INTO expected_order FROM _multi_state;

    -- await_instance() returns when df.instances.status is terminal, but
    -- duroxide's execution output can become visible a moment later. Both
    -- monitoring paths (list_instances and instance_info) observe the same
    -- eventual state, so wait until output has materialized for all three before
    -- comparing snapshots, otherwise we would race the completion boundary.
    LOOP
        SELECT count(*) INTO settled
        FROM df.list_instances()
        WHERE list_instances.instance_id = ANY(ids) AND output IS NOT NULL;
        EXIT WHEN settled = 3 OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF settled <> 3 THEN
        RAISE EXCEPTION 'TEST FAILED: only % of 3 instances have materialized output in list_instances()', settled;
    END IF;

    -- (a) Order of our three ids within list_instances() output. WITH ORDINALITY
    -- numbers rows in the exact order the function emits them (the just-created
    -- instances are newest, so they sort first under created_at DESC).
    SELECT array_agg(instance_id ORDER BY ord) INTO listed_order
    FROM df.list_instances()
        WITH ORDINALITY AS t(instance_id, label, function_name, status, execution_count, output, ord)
    WHERE t.instance_id = ANY(ids);

    IF listed_order IS DISTINCT FROM expected_order THEN
        RAISE EXCEPTION 'TEST FAILED: list_instances order % != expected created_at DESC order %',
            listed_order, expected_order;
    END IF;

    -- (b) Per-instance equivalence between list_instances() and instance_info().
    -- list_instances.execution_count maps to instance_info.current_execution_id.
    -- Distinct outputs (1001/1002/1003) prove the batch reassembly maps each
    -- instance's metadata back to the right id rather than scrambling rows.
    FOR li IN
        SELECT instance_id, function_name, execution_count, output
        FROM df.list_instances()
        WHERE list_instances.instance_id = ANY(ids)
    LOOP
        SELECT function_name, current_execution_id, output
        INTO ii
        FROM df.instance_info(li.instance_id);

        IF ii.function_name IS DISTINCT FROM li.function_name THEN
            RAISE EXCEPTION 'TEST FAILED: function_name mismatch for %: list=% info=%',
                li.instance_id, li.function_name, ii.function_name;
        END IF;
        IF ii.current_execution_id IS DISTINCT FROM li.execution_count THEN
            RAISE EXCEPTION 'TEST FAILED: execution_count mismatch for %: list=% info=%',
                li.instance_id, li.execution_count, ii.current_execution_id;
        END IF;
        IF ii.output IS DISTINCT FROM li.output THEN
            RAISE EXCEPTION 'TEST FAILED: output mismatch for %: list=% info=%',
                li.instance_id, li.output, ii.output;
        END IF;
    END LOOP;

    RAISE NOTICE 'TEST PASSED: multi-instance ordering + list/instance_info equivalence';
END $multi$;

DROP TABLE _multi_state;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
