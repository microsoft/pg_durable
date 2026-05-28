-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: Connection limit backpressure
-- Requires: pg_durable.max_user_connections = 2
-- Verifies that when more concurrent SQL nodes than the limit are running,
-- the extras queue (backpressure) rather than failing, and all complete.

DROP TABLE IF EXISTS test_bp_log;
CREATE TABLE test_bp_log (id SERIAL, wf TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, label TEXT);

-- Start 4 workflows each doing a pg_sleep(3) + insert.
-- With max_user_connections=2, at most 2 run concurrently; the rest queue.
INSERT INTO _test_state
SELECT df.start(
    'SELECT pg_sleep(3)' ~> 'INSERT INTO test_bp_log (wf) VALUES (''wf1'')',
    'test-bp-1'
), 'wf1';

INSERT INTO _test_state
SELECT df.start(
    'SELECT pg_sleep(3)' ~> 'INSERT INTO test_bp_log (wf) VALUES (''wf2'')',
    'test-bp-2'
), 'wf2';

INSERT INTO _test_state
SELECT df.start(
    'SELECT pg_sleep(3)' ~> 'INSERT INTO test_bp_log (wf) VALUES (''wf3'')',
    'test-bp-3'
), 'wf3';

INSERT INTO _test_state
SELECT df.start(
    'SELECT pg_sleep(3)' ~> 'INSERT INTO test_bp_log (wf) VALUES (''wf4'')',
    'test-bp-4'
), 'wf4';

-- All 4 should complete — the backpressure semaphore queues the extras.
-- With 2 slots and 3s sleeps, expect ~6s total (2 batches of 2).
-- Give generous timeout (60s) to account for scheduling variance.
DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
BEGIN
    FOR rec IN SELECT instance_id, label FROM _test_state LOOP
        SELECT df.wait_for_completion(rec.instance_id, 60) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %, expected completed', rec.label, status;
        END IF;
    END LOOP;

    SELECT COUNT(*) INTO cnt FROM test_bp_log;
    IF cnt != 4 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 4 rows, got %', cnt;
    END IF;

    RAISE NOTICE 'PASSED: all 4 workflows completed with backpressure (max_user_connections=2)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_bp_log;
SELECT 'TEST PASSED' AS result;
