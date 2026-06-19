-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.start / df.cancel / df.signal enqueue on the CALLER'S transaction.
--
-- Regression test for df/_duroxide divergence. Originally the duroxide enqueue
-- happened out-of-band on a separate connection that committed independently, so
-- rolling back the caller's transaction left the runtime store ahead of the
-- control plane:
--   * a rolled-back df.start()  left an orphaned orchestration in _duroxide;
--   * a rolled-back df.cancel() still cancelled the (committed) instance;
--   * a rolled-back df.signal() still delivered the signal.
--
-- With the in-transaction enqueue, a ROLLBACK undoes the runtime work too. Each
-- scenario below FAILS without that change.
--
-- _duroxide is owned by the worker role, so its tables are read as the superuser
-- (postgres); the durable functions themselves run as the non-superuser
-- df_e2e_user.

-- Helper (superuser): assert no _duroxide residue remains for an instance id.
-- Resolves the runtime schema dynamically (df.duroxide_schema()).
CREATE OR REPLACE FUNCTION pg_temp.assert_no_duroxide_residue(p_id text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    sch text := df.duroxide_schema();
    n   int;
BEGIN
    EXECUTE format(
        'SELECT (SELECT count(*) FROM %I.orchestrator_queue WHERE instance_id = $1) '
        '     + (SELECT count(*) FROM %I.instances        WHERE instance_id = $1)',
        sch, sch)
    INTO n USING p_id;

    IF n > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: rolled-back df.start left % _duroxide row(s) for instance % (non-atomic enqueue leaked)', n, p_id;
    END IF;
    RAISE NOTICE 'PASSED [start_rollback]: no _duroxide residue for %', p_id;
END $$;

-- ===========================================================================
-- Scenario 1: a rolled-back df.start() leaves no _duroxide orphan
-- ===========================================================================

SET SESSION AUTHORIZATION df_e2e_user;
BEGIN;
SELECT df.start('SELECT 42', 'atomic-rb-start') AS rb_id \gset
ROLLBACK;
RESET SESSION AUTHORIZATION;

-- Give any (buggy) out-of-band enqueue a moment to surface before asserting.
SELECT pg_sleep(1);
SELECT pg_temp.assert_no_duroxide_residue(:'rb_id');

-- ===========================================================================
-- Scenario 2: a rolled-back df.cancel() does NOT cancel the instance
-- ===========================================================================

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _t_cancel (instance_id TEXT);
INSERT INTO _t_cancel
SELECT df.start(df.loop(df.seq('SELECT 1', df.sleep(1))), 'atomic-rb-cancel');

-- Wait until the instance is genuinely running.
DO $$
DECLARE inst_id TEXT; status TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_cancel;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'running' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF lower(status) <> 'running' THEN
        RAISE EXCEPTION 'Scenario 2 setup: cancel victim never reached running (status=%)', status;
    END IF;
END $$;

-- Issue a cancel, then roll it back.
BEGIN;
SELECT df.cancel((SELECT instance_id FROM _t_cancel), 'rolled-back-cancel');
ROLLBACK;

-- The instance must NOT become cancelled: the cancel enqueue was rolled back.
-- (Without the change the out-of-band CancelInstance committed, so the worker
-- cancels the instance within ~1s.)
DO $$
DECLARE inst_id TEXT; status TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_cancel;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        IF lower(status) = 'cancelled' THEN
            RAISE EXCEPTION 'TEST FAILED: rolled-back df.cancel still cancelled instance % (non-atomic enqueue leaked)', inst_id;
        END IF;
        EXIT WHEN attempts > 50;   -- watch for ~5s
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    RAISE NOTICE 'PASSED [cancel_rollback]: instance % still % after a rolled-back cancel', inst_id, status;
END $$;

-- Cleanup: cancel the (infinite) loop for real.
SELECT df.cancel((SELECT instance_id FROM _t_cancel), 'cleanup');
DROP TABLE _t_cancel;

RESET SESSION AUTHORIZATION;

-- ===========================================================================
-- Scenario 3: a rolled-back df.signal() does NOT deliver the signal
-- ===========================================================================

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _t_signal (instance_id TEXT);
INSERT INTO _t_signal
SELECT df.start('SELECT 1' ~> (df.wait_for_signal('go') |=> 'sig') ~> 'SELECT 1',
                'atomic-rb-signal');

-- Wait until the instance is running (blocked on the signal).
DO $$
DECLARE inst_id TEXT; status TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_signal;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'running' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF lower(status) <> 'running' THEN
        RAISE EXCEPTION 'Scenario 3 setup: signal victim never reached running (status=%)', status;
    END IF;
END $$;

-- Send a signal, then roll it back.
BEGIN;
SELECT df.signal((SELECT instance_id FROM _t_signal), 'go', '{}');
ROLLBACK;

-- The instance must NOT complete: the signal enqueue was rolled back.
-- (Without the change the out-of-band ExternalRaised committed, so the instance
-- receives the signal and completes within ~1s.)
DO $$
DECLARE inst_id TEXT; status TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_signal;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        IF lower(status) = 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: rolled-back df.signal still delivered to instance % (non-atomic enqueue leaked)', inst_id;
        END IF;
        EXIT WHEN attempts > 50;   -- watch for ~5s
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    RAISE NOTICE 'PASSED [signal_rollback]: instance % still % after a rolled-back signal', inst_id, status;
END $$;

-- Cleanup: deliver the signal for real and let it finish.
SELECT df.signal((SELECT instance_id FROM _t_signal), 'go', '{}');
DO $$
DECLARE inst_id TEXT; status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_signal;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;
END $$;
DROP TABLE _t_signal;

RESET SESSION AUTHORIZATION;

SELECT 'TEST PASSED: atomic rollback (start/cancel/signal)' AS result;
