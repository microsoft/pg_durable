-- Test: Deep graph nesting — 50-level sequential chain (A2)
-- Demonstrates: execute_function_node_with_vars handles deeply nested THEN nodes
--               without stack overflow.
-- Expected: Instance completes successfully.

-- Build a 50-step sequential chain using a DO block, start it (commits on block end)
CREATE TEMP TABLE _test_state (instance_id TEXT);

DO $$
DECLARE
    chain TEXT;
    i INT;
BEGIN
    -- Start with a single SQL node
    chain := df.sql('SELECT 1');

    -- Append 49 more steps: total depth = 50 nested THEN nodes
    FOR i IN 2..50 LOOP
        chain := df.seq(chain, format('SELECT %s', i));
    END LOOP;

    INSERT INTO _test_state VALUES (df.start(chain, 'test-deep-nesting-50'));
    RAISE NOTICE 'Deep nesting test started';
END $$;

-- Wait in a separate block so the instance is already committed
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 60) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A2]: 50-level deep chain expected Completed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [A2]: 50-level sequential chain completed successfully';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
