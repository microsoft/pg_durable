-- Test: Wide parallel graph — 9 concurrent branches via nested join3 (A3)
-- Demonstrates: duroxide runtime handles many simultaneous parallel sub-orchestrations
-- Expected: All branches complete; instance ends in completed state

-- Start instance at top level so it commits before polling
CREATE TEMP TABLE _test_state AS SELECT df.start(
    df.join3(
        df.join3(
            df.sql('SELECT 1 AS branch'),
            df.sql('SELECT 2 AS branch'),
            df.sql('SELECT 3 AS branch')
        ),
        df.join3(
            df.sql('SELECT 4 AS branch'),
            df.sql('SELECT 5 AS branch'),
            df.sql('SELECT 6 AS branch')
        ),
        df.join3(
            df.sql('SELECT 7 AS branch'),
            df.sql('SELECT 8 AS branch'),
            df.sql('SELECT 9 AS branch')
        )
    ),
    'test-wide-parallel-9'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 60) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A3]: 9-branch parallel graph expected completed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [A3]: 9-branch parallel graph completed successfully';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
