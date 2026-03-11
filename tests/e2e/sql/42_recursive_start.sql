-- Test: Calling df.start() from inside a workflow SQL node (B11)
-- Demonstrates: df.start() is not guarded by is_in_workflow_context().
--               A SQL node can spawn child instances, which the background
--               worker picks up independently.
-- Expected: Outer instance completes; child instance is created and completes.

DROP TABLE IF EXISTS test_recursive_log;
CREATE TABLE test_recursive_log (id SERIAL, spawned_id TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _b11_outer AS
SELECT df.start(
    -- This SQL node calls df.start() to spawn a child instance and records the ID.
    'INSERT INTO test_recursive_log (spawned_id)
     SELECT df.start(df.sql(''SELECT 1''), ''child-from-workflow'')',
    'test-recursive-start-outer'
) AS instance_id;

DO $$
DECLARE
    outer_id TEXT;
    child_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO outer_id FROM _b11_outer;
    RAISE NOTICE 'Outer instance: %', outer_id;

    -- Wait for the outer instance to complete
    SELECT df.wait_for_completion(outer_id, 30) INTO status;
    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [B11]: outer instance expected Completed, got %', status;
    END IF;

    -- Verify that a child instance was spawned
    SELECT spawned_id INTO child_id FROM test_recursive_log LIMIT 1;
    IF child_id IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [B11]: expected a child instance to be spawned';
    END IF;
    RAISE NOTICE 'Child instance spawned: %', child_id;

    -- Wait for the child instance to complete
    SELECT df.wait_for_completion(child_id, 30) INTO status;
    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [B11]: child instance expected Completed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [B11]: df.start() inside a workflow spawns a running child instance';
    RAISE NOTICE 'NOTE: No recursion guard exists — unbounded spawning is possible if used carelessly';
END $$;

DROP TABLE _b11_outer;
DROP TABLE test_recursive_log;
SELECT 'TEST PASSED' AS result;
