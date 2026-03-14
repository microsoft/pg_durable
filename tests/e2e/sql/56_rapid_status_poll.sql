-- Test: Rapid df.status() polling stress test (C5)
-- Demonstrates: Many rapid status() calls do not exhaust resources or deadlock.
-- Each df.status() call creates a fresh tokio runtime and duroxide provider —
-- this test verifies the system remains stable under polling pressure.
-- Expected: No errors, no hangs; instance completes normally.

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    poll_count INT := 0;
BEGIN
    -- Start a slow instance so we can poll it many times before it finishes
    inst_id := df.start(df.sleep(3), 'test-rapid-poll');

    -- Tight-loop poll until completed, counting iterations
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        poll_count := poll_count + 1;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled');
        EXIT WHEN poll_count > 1000;  -- safety limit
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [C5]: expected completed, got % after % polls', status, poll_count;
    END IF;

    RAISE NOTICE 'PASSED [C5]: rapid polling ran % times without resource errors', poll_count;
END $$;

SELECT 'TEST PASSED' AS result;
