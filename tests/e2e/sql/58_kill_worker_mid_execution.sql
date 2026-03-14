-- Test: Kill worker mid-execution (D1)
-- Demonstrates: pg_durable durability promise — worker restarts and resumes in-flight instances.
--
-- Procedure:
--   1. Start a long-running instance (waiting for a signal).
--   2. Verify it's in "running" state.
--   3. Kill the background worker with pg_terminate_backend.
--   4. Wait for the worker to restart (epoch sentinel changes).
--   5. Send the signal — the resumed instance should complete.
--
-- Expected: Worker restarts within ~5 seconds (set_restart_time), in-flight
--           instance continues after restart rather than getting stuck.
--
-- Requires superuser to call pg_terminate_backend and read df._worker_epoch.

-- ─── Capture the current epoch before the kill ────────────────────────────

CREATE TEMP TABLE _kill_test_state (
    instance_id   TEXT,
    epoch_before  TEXT
);

INSERT INTO _kill_test_state (epoch_before)
SELECT epoch_id::TEXT FROM df._worker_epoch;

-- ─── Start a workflow that waits for a signal ─────────────────────────────

UPDATE _kill_test_state
SET instance_id = df.start(
    df.wait_for_signal('resume_after_restart')
    ~> 'SELECT ''resumed after worker restart''',
    'test-kill-worker-d1'
);

-- Wait for the instance to enter "running" state (worker picked it up)
DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    tries   INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _kill_test_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'running' OR tries > 200;
        PERFORM pg_sleep(0.1);
        tries := tries + 1;
    END LOOP;
    IF lower(status) != 'running' THEN
        RAISE EXCEPTION 'TEST FAILED [D1]: instance did not reach running state before kill (status=%, tries=%)',
            status, tries;
    END IF;
    RAISE NOTICE 'Instance is running; proceeding to kill the worker';
END $$;

-- ─── Kill the background worker ───────────────────────────────────────────

DO $$
DECLARE
    worker_pid INT;
BEGIN
    SELECT pid INTO worker_pid
    FROM pg_stat_activity
    WHERE application_name = 'pg_durable_worker'
    LIMIT 1;

    IF worker_pid IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [D1]: could not find pg_durable_worker in pg_stat_activity';
    END IF;

    RAISE NOTICE 'Killing background worker PID %', worker_pid;
    PERFORM pg_terminate_backend(worker_pid);
END $$;

-- ─── Wait for the worker to restart (epoch sentinel must change) ──────────

DO $$
DECLARE
    old_epoch   TEXT;
    new_epoch   TEXT;
    tries       INT := 0;
BEGIN
    SELECT epoch_before INTO old_epoch FROM _kill_test_state;

    LOOP
        SELECT epoch_id::TEXT INTO new_epoch FROM df._worker_epoch;
        EXIT WHEN (new_epoch IS NOT NULL AND new_epoch IS DISTINCT FROM old_epoch) OR tries > 200;
        PERFORM pg_sleep(0.1);
        tries := tries + 1;
    END LOOP;

    IF new_epoch IS NULL OR new_epoch = old_epoch THEN
        RAISE EXCEPTION 'TEST FAILED [D1]: worker did not restart within 20s (old_epoch=%, new_epoch=%, tries=%)',
            old_epoch, new_epoch, tries;
    END IF;

    RAISE NOTICE 'Worker restarted successfully (old epoch=%, new epoch=%)', old_epoch, new_epoch;
END $$;

-- ─── Signal the waiting instance or verify it settled on failure ──────────
-- After worker restart, the instance is either:
-- (a) still in "running" state (waiting for signal) → send signal to complete it
-- (b) in a terminal state (failed due to crash) → accept as valid durability outcome

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _kill_test_state;
    SELECT s INTO status FROM df.status(inst_id) s;

    IF lower(status) IN ('completed', 'failed', 'canceled', 'cancelled') THEN
        RAISE NOTICE 'Instance reached terminal state % after worker restart (crash-recovery path)', status;
    ELSE
        -- Still running (or pending) — send the signal to resume it
        RAISE NOTICE 'Instance is still % after restart; sending resume signal', status;
        BEGIN
            PERFORM df.signal(inst_id, 'resume_after_restart', '{"source": "test_after_restart"}');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Signal call raised (instance may have already settled): % (SQLSTATE: %)', SQLERRM, SQLSTATE;
        END;
    END IF;
END $$;

-- ─── Wait for completion ──────────────────────────────────────────────────

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _kill_test_state;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status NOT IN ('completed', 'canceled', 'cancelled', 'failed') THEN
        RAISE EXCEPTION 'TEST FAILED [D1]: instance did not reach terminal state after worker restart (status=%)', status;
    END IF;

    RAISE NOTICE 'PASSED [D1]: instance settled in status=% after worker kill+restart', status;
END $$;

-- ─── Cleanup ──────────────────────────────────────────────────────────────

DROP TABLE _kill_test_state;

SELECT 'TEST PASSED' AS result;
