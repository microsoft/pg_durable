-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: Connection limit timeout
-- Requires: pg_durable.max_user_connections = 1, pg_durable.execution_acquire_timeout = 2
-- Verifies that when the semaphore is held and a second SQL node can't acquire
-- within the timeout, it fails with a descriptive error message.

-- Start a long-running workflow to hold the only semaphore slot.
CREATE TEMP TABLE _test_state (instance_id TEXT, label TEXT);

INSERT INTO _test_state
SELECT df.start(
    'SELECT pg_sleep(15)',
    'test-timeout-blocker'
), 'blocker';

-- Wait until the blocker is actually running before starting the victim.
DO $$
DECLARE
    blocker_id TEXT;
    blocker_status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO blocker_id FROM _test_state WHERE label = 'blocker';

    LOOP
        SELECT s INTO blocker_status FROM df.status(blocker_id) s;
        EXIT WHEN lower(blocker_status) = 'running' OR attempts >= 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(blocker_status) != 'running' THEN
        RAISE EXCEPTION 'TEST FAILED: blocker did not reach running state, got status = %', blocker_status;
    END IF;
END $$;

-- Now start a second workflow. With max_user_connections=1, its SQL node
-- cannot acquire the semaphore and should time out after ~2s.
INSERT INTO _test_state
SELECT df.start(
    'SELECT 1',
    'test-timeout-victim'
), 'victim';

DO $$
DECLARE
    blocker_id TEXT;
    victim_id TEXT;
    blocker_status TEXT;
    victim_status TEXT;
    victim_output TEXT;
    node_result TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO blocker_id FROM _test_state WHERE label = 'blocker';
    SELECT instance_id INTO victim_id FROM _test_state WHERE label = 'victim';

    -- Wait for the victim to fail (should fail within ~5s: 3s head start + 2s timeout)
    SELECT df.await_instance(victim_id, 30) INTO victim_status;

    IF victim_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: victim status = %, expected failed', victim_status;
    END IF;

    -- Status becomes visible via df.instances before the failure payload is always
    -- available through df.instance_info(), so poll briefly and fall back to the
    -- SQL node result if needed.
    LOOP
        SELECT output INTO victim_output
        FROM df.instance_info(victim_id);

        SELECT result::text INTO node_result
        FROM df.nodes
        WHERE instance_id = victim_id AND node_type = 'SQL';

        EXIT WHEN victim_output IS NOT NULL OR node_result IS NOT NULL OR attempts >= 50;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    victim_output := COALESCE(victim_output, node_result);

    IF victim_output IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: victim output is NULL (status = %)', victim_status;
    END IF;

    IF victim_output NOT LIKE '%connection limit reached%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "connection limit reached" in output, got: %', victim_output;
    END IF;

    IF victim_output NOT LIKE '%max_user_connections=%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "max_user_connections=" in output, got: %', victim_output;
    END IF;

    RAISE NOTICE 'PASSED: timeout error message correct: %', victim_output;

    -- Wait for the blocker to finish too (it will complete after 15s)
    SELECT df.await_instance(blocker_id, 30) INTO blocker_status;

    IF blocker_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: blocker status = %, expected completed', blocker_status;
    END IF;

    RAISE NOTICE 'PASSED: connection limit timeout test';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
