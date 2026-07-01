-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Oracle-style autonomous transaction support via df.start_autonomous().
--
-- Demonstrates that df.start_autonomous(...) commits the durable function
-- independently of the caller's transaction: it SURVIVES a caller ROLLBACK
-- (like Oracle PRAGMA AUTONOMOUS_TRANSACTION), whereas the default df.start()
-- is rolled back with the caller.
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_autonomous_audit;
CREATE TABLE test_autonomous_audit (id SERIAL, message TEXT);

DROP TABLE IF EXISTS test_autonomous_main;
CREATE TABLE test_autonomous_main (id INT);

-- === Part 1: autonomous => true SURVIVES a caller rollback ===

BEGIN;
    -- Main-transaction work that will be rolled back.
    INSERT INTO test_autonomous_main (id) VALUES (999);

    -- Autonomous durable function: commits on a separate session.
    SELECT df.start_autonomous(
        'INSERT INTO test_autonomous_audit (message) VALUES (''logged from autonomous txn'')',
        'test-autonomous-survives'
    );

    -- Simulate a failure in the surrounding transaction.
    ROLLBACK;

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    main_count  INT;
    audit_count INT;
BEGIN
    -- The main-transaction insert must have been rolled back.
    SELECT count(*) INTO main_count FROM test_autonomous_main;
    IF main_count <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: main insert should have rolled back, got % rows', main_count;
    END IF;

    -- The autonomous instance must have survived the rollback.
    SELECT id INTO inst_id
    FROM df.instances
    WHERE label = 'test-autonomous-survives'
    ORDER BY created_at DESC
    LIMIT 1;

    IF inst_id IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: autonomous instance did not survive caller rollback';
    END IF;

    SELECT df.await_instance(inst_id) INTO status;
    IF status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: autonomous instance status = %', status;
    END IF;

    -- The audit row must have persisted independently of the rollback.
    SELECT count(*) INTO audit_count
    FROM test_autonomous_audit
    WHERE message = 'logged from autonomous txn';

    IF audit_count <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: audit row missing, count = % (autonomous txn did not persist)', audit_count;
    END IF;

    RAISE NOTICE 'PASSED: autonomous => true survived caller rollback';
END $$;

-- === Part 2: default df.start() does NOT survive rollback ===

BEGIN;
    SELECT df.start(
        'INSERT INTO test_autonomous_audit (message) VALUES (''should never persist'')',
        'test-autonomous-transactional'
    );
    ROLLBACK;

DO $$
DECLARE
    inst_count  INT;
    audit_count INT;
BEGIN
    -- The instance row was written via SPI in the caller's transaction, so the
    -- rollback removes it. (A dangling duroxide orchestration may briefly exist
    -- and then fail to load the graph — it never runs the SQL.)
    SELECT count(*) INTO inst_count
    FROM df.instances
    WHERE label = 'test-autonomous-transactional';

    IF inst_count <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: transactional instance should not survive rollback, found %', inst_count;
    END IF;

    -- Give any dangling orchestration a moment; the SQL must never run.
    PERFORM pg_sleep(1);

    SELECT count(*) INTO audit_count
    FROM test_autonomous_audit
    WHERE message = 'should never persist';

    IF audit_count <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: transactional df.start persisted work across rollback, count = %', audit_count;
    END IF;

    RAISE NOTICE 'PASSED: default df.start() rolled back with the caller';
END $$;

DROP TABLE test_autonomous_audit;
DROP TABLE test_autonomous_main;

SELECT 'TEST PASSED' AS result;
