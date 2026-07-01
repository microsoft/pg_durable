-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- df.start(transaction_mode) selects which transaction the start itself runs
-- in. 'caller' (the default) joins the caller's transaction and rolls back with
-- it; 'new' persists and enqueues on a separate session, so it SURVIVES a
-- caller ROLLBACK. This tests the launch commit boundary, not synchronous
-- Oracle autonomous-routine semantics.
--
-- The fate of the engine record left behind by the rolled-back 'caller' start
-- is covered by 54_reconcile_orphans.sql; this test only asserts the df
-- control-plane contract.
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_txnmode_audit;
CREATE TABLE test_txnmode_audit (id SERIAL, message TEXT);

DROP TABLE IF EXISTS test_txnmode_main;
CREATE TABLE test_txnmode_main (id INT);

-- === Part 1: transaction_mode => 'new' SURVIVES a caller rollback ===

BEGIN;
    -- Main-transaction work that will be rolled back.
    INSERT INTO test_txnmode_main (id) VALUES (999);

    -- Started in its own transaction, on a separate session.
    SELECT df.start(
        'INSERT INTO test_txnmode_audit (message) VALUES (''logged from new transaction'')',
        'test-txnmode-survives',
        transaction_mode => 'new'
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
    SELECT count(*) INTO main_count FROM test_txnmode_main;
    IF main_count <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED [survives_rollback]: main insert should have rolled back, got % rows', main_count;
    END IF;

    -- The instance must have survived the rollback.
    SELECT id INTO inst_id
    FROM df.instances
    WHERE label = 'test-txnmode-survives'
    ORDER BY created_at DESC
    LIMIT 1;

    IF inst_id IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [survives_rollback]: instance did not survive caller rollback';
    END IF;

    SELECT df.await_instance(inst_id) INTO status;
    IF status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [survives_rollback]: instance status = %', status;
    END IF;

    -- The audit row must have persisted independently of the rollback.
    SELECT count(*) INTO audit_count
    FROM test_txnmode_audit
    WHERE message = 'logged from new transaction';

    IF audit_count <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED [survives_rollback]: audit row missing, count = %', audit_count;
    END IF;

    RAISE NOTICE 'PASSED [survives_rollback]: transaction_mode => new survived the caller rollback';
END $$;

-- === Part 2: the default ('caller') does NOT survive a caller rollback ===

BEGIN;
    SELECT df.start(
        'INSERT INTO test_txnmode_audit (message) VALUES (''should never persist'')',
        'test-txnmode-caller'
    );
    ROLLBACK;

DO $$
DECLARE
    inst_count INT;
BEGIN
    -- The instance row was written via SPI in the caller's transaction, so the
    -- rollback removes it. The engine record that df.start() enqueued
    -- out-of-band is inert (it can never load its rolled-back graph) and is
    -- reclaimed by reconciliation — see 54_reconcile_orphans.sql.
    SELECT count(*) INTO inst_count
    FROM df.instances
    WHERE label = 'test-txnmode-caller';

    IF inst_count <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED [caller]: instance should not survive rollback, found %', inst_count;
    END IF;

    RAISE NOTICE 'PASSED [caller]: default transaction_mode rolled back with the caller';
END $$;

-- === Part 3: outside a transaction, 'new' behaves like a normal start ===
-- Guards the ordinary path: the returned id must be a real, immediately
-- visible instance that runs to completion.

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT df.start('SELECT 1', 'test-txnmode-plain', NULL, 'new') INTO inst_id;

    IF inst_id IS NULL OR length(inst_id) <> 8 THEN
        RAISE EXCEPTION 'TEST FAILED [plain]: expected an 8-char instance id, got %', COALESCE(inst_id, '<null>');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM df.instances WHERE id = inst_id) THEN
        RAISE EXCEPTION 'TEST FAILED [plain]: instance % not visible to the caller', inst_id;
    END IF;

    SELECT df.await_instance(inst_id) INTO status;
    IF status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [plain]: instance status = %', status;
    END IF;

    RAISE NOTICE 'PASSED [plain]: transaction_mode => new outside a transaction behaves normally';
END $$;

-- === Part 4: an unrecognised transaction_mode is rejected ===
-- A typo must not be silently treated as 'caller': that would hand back an
-- instance id for a start the caller believes survives their rollback.

DO $$
DECLARE
    inst_id TEXT;
BEGIN
    SELECT df.start('SELECT 1', 'test-txnmode-bogus', NULL, 'detached') INTO inst_id;
    RAISE EXCEPTION 'TEST FAILED [invalid_mode]: expected an error, got instance %', inst_id;
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%invalid transaction_mode%' THEN
            RAISE EXCEPTION 'TEST FAILED [invalid_mode]: unexpected error: %', SQLERRM;
        END IF;
        RAISE NOTICE 'PASSED [invalid_mode]: unrecognised transaction_mode rejected';
END $$;

-- === Part 5: the legacy three-argument call still resolves ===
-- Pre-0.2.5 callers pass exactly three arguments. After the upgrade there is
-- only the four-argument df.start(), so this must resolve to it and default to
-- 'caller' rather than raising "function is not unique".
--
-- The start must be a top-level statement: in 'caller' mode the instance row is
-- written in the caller's transaction, so awaiting it from inside the same
-- uncommitted block would hang (the worker cannot see it yet).

CREATE TEMP TABLE _txnmode_3arg AS
SELECT df.start('SELECT 1', 'test-txnmode-3arg', NULL) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _txnmode_3arg;

    IF inst_id IS NULL OR length(inst_id) <> 8 THEN
        RAISE EXCEPTION 'TEST FAILED [three_arg]: expected an 8-char instance id, got %', COALESCE(inst_id, '<null>');
    END IF;

    SELECT df.await_instance(inst_id) INTO status;
    IF status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [three_arg]: instance status = %', status;
    END IF;

    RAISE NOTICE 'PASSED [three_arg]: three-argument df.start() still resolves';
END $$;

DROP TABLE _txnmode_3arg;

DROP TABLE test_txnmode_audit;
DROP TABLE test_txnmode_main;

RESET SESSION AUTHORIZATION;

SELECT 'TEST PASSED' AS result;
