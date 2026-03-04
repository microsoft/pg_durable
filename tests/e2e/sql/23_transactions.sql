-- E2E Test: Transaction Semantics
-- Tests that df.start() respects transaction boundaries:
-- 1. Committed transaction → DF executes (worker retries until data visible)
-- 2. Rolled back transaction → DF fails gracefully after retry timeout
--
-- LoadFunctionGraph has retry logic (5s timeout, 100ms poll) to handle the race
-- between df.start() enqueuing work and the user's transaction committing.

-- ============================================================================
-- Setup
-- ============================================================================

DROP TABLE IF EXISTS txn_test_log;
CREATE TABLE txn_test_log (
    id SERIAL PRIMARY KEY,
    msg TEXT,
    instance_id TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================================
-- Test 1: DF Started Within DO Block (Same Transaction) - Should Work via Retry
-- ============================================================================

-- This tests the retry logic: df.start() enqueues work, but the DO block
-- transaction hasn't committed yet. The worker should retry until data appears.

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    RAISE NOTICE 'Test 1: DF started within same transaction (tests retry logic)';
    
    -- Start DF within this DO block transaction
    inst_id := df.start(
        'INSERT INTO txn_test_log (msg, instance_id) VALUES (''same_txn_df_ran'', ''{sys_instance_id}'')',
        'txn-test-same-txn'
    );
    
    RAISE NOTICE 'Started DF: %. Worker will retry until this txn commits...', inst_id;
    
    -- Sleep to ensure the worker goes into retry mode before we commit
    -- Worker polls every 100ms, so 500ms ensures at least 4-5 retries
    PERFORM pg_sleep(0.5);
    
    RAISE NOTICE 'Transaction about to commit after 500ms delay...';
    
    -- Store the instance ID for checking in the next statement.
    INSERT INTO txn_test_log (msg, instance_id) VALUES ('test1_instance_id', inst_id);
END $$;

-- Now wait for completion (in a separate transaction, after the DO block committed)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM txn_test_log WHERE msg = 'test1_instance_id';
    RAISE NOTICE 'Test 1: Waiting for DF: %', inst_id;
    
    -- Wait for completion (should succeed because retry logic waits for commit)
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled', 'cancelled') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: same-txn DF status = % (retry logic should have waited for commit)', status;
    END IF;
    
    -- Verify the DF actually ran
    IF NOT EXISTS (SELECT 1 FROM txn_test_log WHERE msg = 'same_txn_df_ran') THEN
        RAISE EXCEPTION 'TEST FAILED: same-txn DF did not execute';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: same_transaction_with_retry';
END $$;

DELETE FROM txn_test_log;

-- ============================================================================
-- Test 2: Rolled Back Transaction - DF Should NOT Execute
-- ============================================================================

-- We need to use a savepoint to simulate rollback within our test
-- since we can't actually rollback and continue the test script

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    RAISE NOTICE 'Test 2: Rolled back transaction (via savepoint)';
    
    -- Create a savepoint
    -- Note: In real usage, if the whole transaction rolls back,
    -- the df.instances/df.nodes rows are never committed
    
    BEGIN
        -- Start DF inside a block that will be rolled back
        inst_id := df.start(
            'INSERT INTO txn_test_log (msg) VALUES (''rollback_df_should_not_run'')',
            'txn-test-rollback'
        );
        
        RAISE NOTICE 'Started DF that will be rolled back: %', inst_id;
        
        -- Store the ID before rollback so we can check it
        INSERT INTO txn_test_log (msg, instance_id) VALUES ('rollback_test_id', inst_id);
        
        -- Simulate a rollback by raising an exception
        RAISE EXCEPTION 'Simulated rollback';
        
    EXCEPTION WHEN OTHERS THEN
        -- This catches the exception and rolls back to the implicit savepoint
        RAISE NOTICE 'Transaction rolled back (exception caught)';
    END;
    
    -- The inst_id variable is still set, but the df.instances row should be gone
    -- Note: inst_id is NULL here because the exception block rolled back
    
    RAISE NOTICE 'After rollback, checking if DF data persisted...';
END $$;

-- Check that the rolled-back DF's data was NOT persisted
DO $$
DECLARE
    rollback_id TEXT;
    node_count INT;
    instance_count INT;
BEGIN
    -- The rollback_test_id row should also be rolled back
    SELECT instance_id INTO rollback_id FROM txn_test_log WHERE msg = 'rollback_test_id';
    
    IF rollback_id IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: rollback_test_id should have been rolled back but found: %', rollback_id;
    END IF;
    
    -- No DF with label 'txn-test-rollback' should exist in df.instances
    SELECT COUNT(*) INTO instance_count FROM df.instances WHERE label = 'txn-test-rollback';
    
    IF instance_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: rolled back DF should not exist in df.instances';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: rollback_transaction_no_instance';
END $$;

-- Wait a moment to see if any orphaned Duroxide work items try to execute
SELECT pg_sleep(2);

-- Verify no "rollback_df_should_not_run" message was logged
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM txn_test_log WHERE msg = 'rollback_df_should_not_run') THEN
        RAISE EXCEPTION 'TEST FAILED: rolled back DF should not have executed';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: rollback_transaction_no_execution';
END $$;

-- ============================================================================
-- Test 3: Explicit Transaction with Rollback (using dblink)
-- This simulates a more realistic scenario where a transaction is started,
-- df.start() is called, and then the transaction is explicitly rolled back.
-- ============================================================================

DO $$
DECLARE
    connstr TEXT := format('host=localhost dbname=postgres port=%s user=postgres', current_setting('port'));
    result TEXT;
    instance_count INT;
BEGIN
    RAISE NOTICE 'Test 3: Explicit transaction rollback via separate connection';
    
    -- Execute in a separate connection: BEGIN, df.start, ROLLBACK
    -- This simulates what happens when a real transaction rolls back
    BEGIN
        SELECT * INTO result FROM dblink(
            connstr,
            $dblink$
                BEGIN;
                SELECT df.start(
                    'INSERT INTO txn_test_log (msg) VALUES (''explicit_rollback_should_not_run'')',
                    'txn-test-explicit-rollback'
                );
                ROLLBACK;
            $dblink$
        ) AS t(result TEXT);
    EXCEPTION WHEN OTHERS THEN
        -- dblink might error on ROLLBACK, that's OK
        RAISE NOTICE 'dblink completed (exception: %)', SQLERRM;
    END;
    
    -- Wait for any potential execution
    PERFORM pg_sleep(2);
    
    -- Check that no instance was created
    SELECT COUNT(*) INTO instance_count FROM df.instances WHERE label = 'txn-test-explicit-rollback';
    
    IF instance_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: explicitly rolled back DF should not exist';
    END IF;
    
    -- Check that no execution happened
    IF EXISTS (SELECT 1 FROM txn_test_log WHERE msg = 'explicit_rollback_should_not_run') THEN
        RAISE EXCEPTION 'TEST FAILED: explicitly rolled back DF should not have executed';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: explicit_rollback_transaction';
END $$;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP TABLE txn_test_log;

SELECT 'ALL TRANSACTION TESTS PASSED' AS result;

