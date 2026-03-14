-- Test: Large SQL result set — query returning 10,000 rows (A5)
-- Demonstrates: execute_sql activity (which uses fetch_all()) can handle
--               a large result set without OOM or timeout.
-- Expected: Instance completes successfully.

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    -- Generate a 10,000-row result by cross-joining small sets
    inst_id := df.start(
        df.sql('SELECT g1.n AS a, g2.n AS b FROM generate_series(1, 100) g1(n) CROSS JOIN generate_series(1, 100) g2(n)'),
        'test-large-result-10k'
    );

    SELECT df.wait_for_completion(inst_id, 60) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A5]: large result set expected completed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [A5]: 10,000-row result set handled without error';
END $$;

SELECT 'TEST PASSED' AS result;
