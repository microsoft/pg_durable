-- Test: Deep graph nesting — 50-level sequential chain (A2)
-- Demonstrates: execute_function_node_with_vars handles deeply nested THEN nodes
--               without stack overflow.
-- Expected: Instance completes successfully.

-- Build a 50-step sequential chain using a DO block, then start it
DO $$
DECLARE
    chain TEXT;
    i INT;
    inst_id TEXT;
    status TEXT;
BEGIN
    -- Start with a single SQL node
    chain := df.sql('SELECT 1');

    -- Append 49 more steps: total depth = 50 nested THEN nodes
    FOR i IN 2..50 LOOP
        chain := df.seq(chain, format('SELECT %s', i));
    END LOOP;

    inst_id := df.start(chain, 'test-deep-nesting-50');
    RAISE NOTICE 'Deep nesting test started: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 60) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A2]: 50-level deep chain expected Completed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [A2]: 50-level sequential chain completed successfully';
END $$;

SELECT 'TEST PASSED' AS result;
