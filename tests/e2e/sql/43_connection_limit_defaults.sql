-- Test: Connection limit defaults
-- Verify that default GUC values allow concurrent workflows to succeed.
-- This test runs in the standard test-e2e-local.sh suite (no custom GUCs).

-- Start 5 concurrent workflows, each executing a short SQL statement.
-- With max_user_connections=10 (default), all should complete without
-- hitting backpressure limits.

DROP TABLE IF EXISTS test_connlimit_log;
CREATE TABLE test_connlimit_log (id SERIAL, wf TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, label TEXT);

INSERT INTO _test_state
SELECT df.start(
    'INSERT INTO test_connlimit_log (wf) VALUES (''wf1'')',
    'test-connlimit-defaults-1'
), 'wf1';

INSERT INTO _test_state
SELECT df.start(
    'INSERT INTO test_connlimit_log (wf) VALUES (''wf2'')',
    'test-connlimit-defaults-2'
), 'wf2';

INSERT INTO _test_state
SELECT df.start(
    'INSERT INTO test_connlimit_log (wf) VALUES (''wf3'')',
    'test-connlimit-defaults-3'
), 'wf3';

INSERT INTO _test_state
SELECT df.start(
    'INSERT INTO test_connlimit_log (wf) VALUES (''wf4'')',
    'test-connlimit-defaults-4'
), 'wf4';

INSERT INTO _test_state
SELECT df.start(
    'INSERT INTO test_connlimit_log (wf) VALUES (''wf5'')',
    'test-connlimit-defaults-5'
), 'wf5';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
BEGIN
    FOR rec IN SELECT instance_id, label FROM _test_state LOOP
        SELECT df.wait_for_completion(rec.instance_id, 30) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.label, status;
        END IF;
    END LOOP;

    SELECT COUNT(*) INTO cnt FROM test_connlimit_log;
    IF cnt != 5 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 5 rows, got %', cnt;
    END IF;

    RAISE NOTICE 'PASSED: all 5 workflows completed under default connection limits';
END $$;

DROP TABLE _test_state;
DROP TABLE test_connlimit_log;
SELECT 'TEST PASSED' AS result;
