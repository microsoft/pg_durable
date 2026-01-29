-- Test: Extension creation security and DROP CASCADE behavior
-- Tests that:
-- 1. Extension exists before drop
-- 2. DROP EXTENSION CASCADE removes all schemas (df, duroxide) and objects
-- 3. Non-superuser cannot create the extension
-- 4. Extension creation fails if 'df' schema is pre-created
-- 5. Extension creation fails if 'duroxide' schema is pre-created
-- 6. Extension can be recreated after DROP CASCADE
-- 7. Background worker initializes duroxide-pg after recreation
-- 8. Worker is operational after recreation (verified by running a durable function)
-- 9. duroxide schema is owned by the extension
-- Expected: All security conditions and lifecycle operations work correctly

-- Note: This test drops and recreates the extension to test installation security
-- Any running instances will be lost, but E2E tests are self-contained

-- ============================================================================
-- Verify extension exists before drop
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_durable') THEN
        RAISE EXCEPTION 'TEST FAILED: Extension should exist at test start';
    END IF;
    RAISE NOTICE 'PASS: Extension exists before drop';
END $$;

-- ============================================================================
-- Drop extension and verify cleanup
-- ============================================================================

DROP EXTENSION IF EXISTS pg_durable CASCADE;

-- Wait for background worker to detect schema removal and shut down gracefully
-- This prevents race conditions in CI where the worker might be mid-operation
SELECT pg_sleep(2);

-- Verify extension and schemas (df, duroxide) are gone
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_durable') THEN
        RAISE EXCEPTION 'TEST FAILED: Extension still exists after DROP';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'df') THEN
        RAISE EXCEPTION 'TEST FAILED: df schema still exists after DROP CASCADE';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide') THEN
        RAISE EXCEPTION 'TEST FAILED: duroxide schema still exists after DROP CASCADE';
    END IF;
    RAISE NOTICE 'PASS: Extension and df+duroxide schemas removed';
END $$;

-- ============================================================================
-- Test 1: Non-superuser cannot create extension
-- ============================================================================

-- Create a non-superuser role for testing
DROP USER IF EXISTS test_nonsuperuser;
CREATE USER test_nonsuperuser;

-- Attempt to create extension as non-superuser (should fail)
SET ROLE test_nonsuperuser;
DO $$
BEGIN
    -- This should fail with permission denied
    EXECUTE 'CREATE EXTENSION pg_durable';
    RAISE EXCEPTION 'SECURITY FAILURE: Non-superuser was able to create pg_durable extension!';
EXCEPTION
    WHEN insufficient_privilege THEN
        -- Expected: permission denied
        RAISE NOTICE 'TEST 1 PASSED: Non-superuser correctly denied extension creation';
    WHEN OTHERS THEN
        IF SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%superuser%' THEN
            RAISE NOTICE 'TEST 1 PASSED: Non-superuser correctly denied extension creation (%)' , SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 1 FAILED: Unexpected error: %', SQLERRM;
        END IF;
END $$;
RESET ROLE;

-- Cleanup test user
DROP USER test_nonsuperuser;

-- ============================================================================
-- Test 2: Extension creation fails if 'df' schema pre-exists
-- ============================================================================

-- Create the 'df' schema before attempting extension creation
-- This simulates an attacker trying to pre-create the schema
CREATE SCHEMA IF NOT EXISTS df;

-- Attempt to create extension with pre-existing df schema (should fail)
DO $$
DECLARE
    extension_created BOOLEAN := FALSE;
BEGIN
    -- This should fail because the schema already exists
    BEGIN
        CREATE EXTENSION pg_durable;
        extension_created := TRUE;
    EXCEPTION
        WHEN duplicate_schema THEN
            RAISE NOTICE 'TEST 2 PASSED: Extension creation correctly prevented with pre-existing df schema';
        WHEN OTHERS THEN
            -- The extension might also fail with other errors related to schema conflicts
            IF SQLERRM ILIKE '%schema%' OR SQLERRM ILIKE '%already exists%' OR SQLERRM ILIKE '%df%' THEN
                RAISE NOTICE 'TEST 2 PASSED: Extension creation correctly prevented with pre-existing df schema (%)' , SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST 2 FAILED: Unexpected error during extension creation: %', SQLERRM;
            END IF;
    END;
    
    -- If we get here and extension was created, that's a security failure
    IF extension_created THEN
        RAISE EXCEPTION 'SECURITY FAILURE: Extension created successfully even with pre-existing df schema!';
    END IF;
END $$;

-- Clean up the pre-created schema
DROP SCHEMA IF EXISTS df CASCADE;

-- ============================================================================
-- Test 3: Extension creation fails if 'duroxide' schema pre-exists
-- ============================================================================

-- Create the 'duroxide' schema before attempting extension creation
CREATE SCHEMA IF NOT EXISTS duroxide;

-- Attempt to create extension with pre-existing duroxide schema (should fail)
DO $$
DECLARE
    extension_created BOOLEAN := FALSE;
BEGIN
    -- This should fail because the duroxide schema already exists
    BEGIN
        CREATE EXTENSION pg_durable;
        extension_created := TRUE;
    EXCEPTION
        WHEN duplicate_schema THEN
            RAISE NOTICE 'TEST 3 PASSED: Extension creation correctly prevented with pre-existing duroxide schema';
        WHEN OTHERS THEN
            IF SQLERRM ILIKE '%schema%' OR SQLERRM ILIKE '%already exists%' OR SQLERRM ILIKE '%duroxide%' THEN
                RAISE NOTICE 'TEST 3 PASSED: Extension creation correctly prevented with pre-existing duroxide schema (%)' , SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST 3 FAILED: Unexpected error during extension creation: %', SQLERRM;
            END IF;
    END;
    
    -- If we get here and extension was created, that's a security failure
    IF extension_created THEN
        RAISE EXCEPTION 'SECURITY FAILURE: Extension created successfully even with pre-existing duroxide schema!';
    END IF;
END $$;

-- Clean up the pre-created duroxide schema
DROP SCHEMA IF EXISTS duroxide CASCADE;

-- ============================================================================
-- Restore extension for remaining tests
-- ============================================================================

-- Recreate the extension properly for other tests to continue
CREATE EXTENSION pg_durable;

-- Wait for background worker to initialize duroxide-pg tables
DO $$
DECLARE
    table_count INT;
    attempts INT := 0;
BEGIN
    LOOP
        SELECT COUNT(*) INTO table_count
        FROM pg_tables 
        WHERE schemaname = 'duroxide' 
        AND tablename IN ('executions', 'instances', 'history', 'orchestrator_queue', 'worker_queue');
        
        EXIT WHEN table_count = 5 OR attempts > 150;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF table_count != 5 THEN
        RAISE EXCEPTION 'TEST SETUP FAILED: Worker did not initialize duroxide-pg, found % of 5 expected tables', table_count;
    END IF;
    
    RAISE NOTICE 'PASS: Worker initialized duroxide-pg after recreation';
END $$;

-- Verify extension schemas and ownership
DO $$
DECLARE
    df_exists BOOLEAN;
    duroxide_exists BOOLEAN;
    duroxide_owned BOOLEAN;
BEGIN
    -- Check that df schema exists
    SELECT EXISTS(
        SELECT 1 FROM pg_namespace WHERE nspname = 'df'
    ) INTO df_exists;
    
    -- Check that duroxide schema exists
    SELECT EXISTS(
        SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide'
    ) INTO duroxide_exists;
    
    -- Check that duroxide schema is owned by pg_durable extension
    SELECT EXISTS(
        SELECT 1 FROM pg_namespace n
        JOIN pg_depend d ON d.objid = n.oid
        JOIN pg_extension e ON d.refobjid = e.oid
        WHERE n.nspname = 'duroxide'
          AND e.extname = 'pg_durable'
          AND d.deptype = 'e'
    ) INTO duroxide_owned;
    
    IF NOT df_exists THEN
        RAISE EXCEPTION 'TEST SETUP FAILED: df schema not created after extension installation';
    END IF;
    
    IF NOT duroxide_exists THEN
        RAISE EXCEPTION 'TEST SETUP FAILED: duroxide schema not created after extension installation';
    END IF;
    
    IF NOT duroxide_owned THEN
        RAISE EXCEPTION 'TEST SETUP FAILED: duroxide schema not owned by pg_durable extension';
    END IF;
    
    RAISE NOTICE 'PASS: Extension restored with proper schema ownership';
END $$;

-- Verify worker is operational by running a simple durable function
CREATE TEMP TABLE _restore_test_state (instance_id TEXT);
INSERT INTO _restore_test_state 
SELECT df.start('SELECT 1 as restore_test', 'test-extension-restoration');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _restore_test_state;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Worker not operational after restoration, status = %', status;
    END IF;
    
    RAISE NOTICE 'PASS: Worker operational after extension recreation';
END $$;

DROP TABLE _restore_test_state;

SELECT 'TEST PASSED' AS result;
