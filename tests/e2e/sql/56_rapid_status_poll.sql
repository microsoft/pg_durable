-- Test: Rapid df.status() polling stress test (C5)
-- Demonstrates: Many rapid status() calls do not cause issues.
-- df.status() is a simple SPI query (SELECT status FROM df.instances),
-- so each call is cheap. This test verifies that tight-loop polling
-- does not interfere with the background worker or cause hangs.
-- Expected: No errors, no hangs; instance completes normally.

-- Start instance at top level so it commits before polling
CREATE TEMP TABLE _test_state AS SELECT df.start(df.sleep(3), 'test-rapid-poll') AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    poll_count INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;

    -- Tight-loop poll until completed, counting iterations.
    -- Each df.status() call is a simple SPI query (~0.02ms), so we need a high
    -- limit to cover the 3-second sleep duration without adding pg_sleep delays.
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        poll_count := poll_count + 1;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled');
        EXIT WHEN poll_count > 500000;  -- safety limit (~10s of wall time)
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [C5]: expected completed, got % after % polls', status, poll_count;
    END IF;

    RAISE NOTICE 'PASSED [C5]: rapid polling ran % times without resource errors', poll_count;
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
