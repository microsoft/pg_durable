-- Test: Stuck instances — signals that never arrive (E2 / E3)
-- Demonstrates: Instances waiting for signals remain in "running" state indefinitely;
--               cancellation is the only escape valve (no default timeout).
--
-- Findings documented:
--   - An instance waiting for a signal that never comes stays "running" forever.
--   - There is no built-in idle timeout or watchdog for "running" instances.
--   - df.cancel() is the correct operator-driven remedy.
--
-- Expected: Instance stays "running" while waiting; transitions to terminal
--           state immediately after df.cancel() is called.

-- ─── Start a workflow that waits for a signal that will never be sent ──────

CREATE TEMP TABLE _stuck_state (instance_id TEXT);

INSERT INTO _stuck_state
SELECT df.start(
    df.wait_for_signal('signal_that_never_arrives'),
    'test-stuck-instance-e2-e3'
);

-- ─── Wait for the instance to enter "running" state ────────────────────────

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    tries   INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _stuck_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'running' OR tries > 200;
        PERFORM pg_sleep(0.1);
        tries := tries + 1;
    END LOOP;

    IF lower(status) != 'running' THEN
        RAISE EXCEPTION 'TEST FAILED [E2/E3]: instance did not reach running state (status=%, tries=%)',
            status, tries;
    END IF;

    RAISE NOTICE 'PASSED [E2/E3-a]: instance is running while waiting for signal (status=%)', status;
END $$;

-- ─── Verify it stays stuck after a short pause ─────────────────────────────

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _stuck_state;
    PERFORM pg_sleep(2);
    SELECT s INTO status FROM df.status(inst_id) s;

    IF lower(status) != 'running' THEN
        RAISE EXCEPTION 'TEST FAILED [E2/E3]: expected still running after 2s wait, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [E2/E3-b]: instance is still running after 2s (no timeout, no self-heal)';
END $$;

-- ─── Cancel the stuck instance and verify it terminates ────────────────────

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _stuck_state;

    PERFORM df.cancel(inst_id, 'test-cancel-stuck-instance');

    SELECT df.wait_for_completion(inst_id, 15) INTO status;

    IF status NOT IN ('canceled', 'cancelled', 'failed') THEN
        RAISE EXCEPTION 'TEST FAILED [E2/E3]: expected canceled/failed after cancel, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [E2/E3-c]: cancel terminated the stuck instance (status=%)', status;
END $$;

-- ─── Cleanup ───────────────────────────────────────────────────────────────

DROP TABLE _stuck_state;

SELECT 'TEST PASSED' AS result;
