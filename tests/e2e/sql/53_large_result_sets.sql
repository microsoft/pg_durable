-- Test: Large SQL result set — query returning 10,000 rows (A5)
-- Demonstrates: execute_sql activity (which uses fetch_all()) can handle
--               a large result set without OOM or timeout.
-- Expected: Instance completes successfully.

-- Start instance at top level so it commits before polling
CREATE TEMP TABLE _test_state AS SELECT df.start(
    df.sql('SELECT g1.n AS a, g2.n AS b FROM generate_series(1, 100) g1(n) CROSS JOIN generate_series(1, 100) g2(n)'),
    'test-large-result-10k'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 60) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A5]: large result set expected completed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [A5]: 10,000-row result set handled without error';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
