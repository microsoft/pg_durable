-- Test: Database validation during CREATE EXTENSION
--
-- Validates that CREATE EXTENSION fails when run in a database that doesn't
-- match the one the background worker connects to.
--
-- The background worker connects to ONE database (specified by the
-- pg_durable.database GUC, defaulting to 'postgres'). The extension
-- must be created in that exact database.
--
-- This test validates that:
-- 1) CREATE EXTENSION succeeds in the correct database
-- 2) Workflows execute in the correct database
-- 3) CREATE EXTENSION actually fails with a clear error in a wrong database
--
-- NOTE: Test 00_requires_shared_preload.sql already validates the
--       shared_preload_libraries requirement.

-- We use dblink to attempt CREATE EXTENSION in a different database
CREATE EXTENSION IF NOT EXISTS dblink;

-- First, verify we're running in the correct database
-- (This test assumes it's running in the database the BGW connects to)
DO $$
DECLARE
    current_db TEXT;
    target_db TEXT;
BEGIN
    SELECT current_database() INTO current_db;
    SELECT df.target_database() INTO target_db;
    
    IF current_db != target_db THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: This test must run in database "%" (currently in "%")', target_db, current_db;
    END IF;
    
    RAISE NOTICE 'Test running in correct database: %', current_db;
END $$;

-- ============================================================================
-- Test 1: CREATE EXTENSION should succeed in the correct database
-- ============================================================================
SELECT public._e2e_drop_extension_safe();
CREATE EXTENSION pg_durable;

-- Wait for the background worker to fully reinitialize
SELECT public._e2e_wait_for_worker_ready();

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_durable') THEN
        RAISE EXCEPTION 'TEST FAILED: Extension should exist in correct database';
    END IF;
    RAISE NOTICE 'PASSED: CREATE EXTENSION succeeded in correct database';
END $$;

-- ============================================================================
-- Test 2: Verify workflows can execute (BGW is connected to this database)
-- ============================================================================
CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state
SELECT df.start('SELECT 42 as answer', 'test-correct-db');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Workflow should complete in correct database, got status: %', status;
    END IF;
    
    RAISE NOTICE 'PASSED: Workflow executed successfully in correct database';
END $$;

DROP TABLE _test_state;

-- ============================================================================
-- Test 3: CREATE EXTENSION must fail in a wrong database
-- ============================================================================
-- Create a throwaway database, connect to it via dblink, and verify that
-- CREATE EXTENSION pg_durable is rejected with the expected error message.

DROP DATABASE IF EXISTS _test_wrong_db;
CREATE DATABASE _test_wrong_db;

DO $$
DECLARE
    connstr TEXT;
    err_msg TEXT;
BEGIN
    connstr := format(
        'host=localhost dbname=_test_wrong_db port=%s user=postgres',
        current_setting('port')
    );

    -- Attempt CREATE EXTENSION in the wrong database via dblink
    BEGIN
        PERFORM dblink_exec(connstr, 'CREATE EXTENSION pg_durable;');
        -- If we get here, the guard did not fire
        RAISE EXCEPTION 'TEST FAILED: CREATE EXTENSION should have been rejected in wrong database';
    EXCEPTION WHEN OTHERS THEN
        err_msg := SQLERRM;
    END;

    -- Verify the error message mentions the expected keywords
    IF err_msg NOT ILIKE '%must be created in database%' THEN
        RAISE EXCEPTION 'TEST FAILED: Expected "must be created in database" in error, got: %', err_msg;
    END IF;
    IF err_msg NOT ILIKE '%_test_wrong_db%' THEN
        RAISE EXCEPTION 'TEST FAILED: Expected wrong db name in error, got: %', err_msg;
    END IF;

    RAISE NOTICE 'PASSED: CREATE EXTENSION correctly rejected in wrong database';
    RAISE NOTICE 'Error was: %', err_msg;
END $$;

-- Cleanup
DROP DATABASE IF EXISTS _test_wrong_db;

SELECT 'TEST PASSED' AS result;

