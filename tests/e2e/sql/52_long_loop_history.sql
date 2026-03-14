-- Test: Long loop execution history — 100 iterations (A4)
-- Demonstrates: df.loop() with a finite counter condition running 100 iterations
--               does not OOM, stack-overflow, or time out unreasonably.
-- Expected: Instance completes in completed state; loop table has exactly 100 rows.

DROP TABLE IF EXISTS test_long_loop_log;
CREATE TABLE test_long_loop_log (id SERIAL);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    row_count INT;
BEGIN
    -- Loop body: insert a row. Condition: stop after 100 rows.
    inst_id := df.start(
        df.loop(
            'INSERT INTO test_long_loop_log DEFAULT VALUES',
            'SELECT COUNT(*) < 100 FROM test_long_loop_log'
        ),
        'test-long-loop-100'
    );

    -- Allow up to 120 seconds; 100 iterations should complete well under that
    SELECT df.wait_for_completion(inst_id, 120) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A4]: long loop expected completed, got %', status;
    END IF;

    SELECT COUNT(*) INTO row_count FROM test_long_loop_log;

    IF row_count != 100 THEN
        RAISE EXCEPTION 'TEST FAILED [A4]: expected 100 rows, got %', row_count;
    END IF;

    RAISE NOTICE 'PASSED [A4]: loop ran 100 iterations and completed successfully';
END $$;

DROP TABLE test_long_loop_log;
SELECT 'TEST PASSED' AS result;
