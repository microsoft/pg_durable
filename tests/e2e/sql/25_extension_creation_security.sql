-- Test: Extension creation security
-- Tests that:
-- 1. Non-superuser cannot create the extension
-- 2. Extension creation fails if 'df' schema is pre-created
-- Expected: Both security conditions are enforced

-- Note: This test drops and recreates the extension to test installation security
-- Save extension state to restore later if needed
CREATE TEMP TABLE _test_existing_instances AS 
SELECT * FROM df.instances WHERE 1=0; -- Just schema, no data needed

-- Clean up: Drop extension to test creation
DROP EXTENSION IF EXISTS pg_durable CASCADE;

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
-- Restore extension for remaining tests
-- ============================================================================

-- Recreate the extension properly for other tests to continue
CREATE EXTENSION pg_durable;

-- Wait a moment for background worker to initialize
SELECT pg_sleep(1);

-- Verify extension is properly installed
DO $$
DECLARE
    schema_exists BOOLEAN;
    extension_exists BOOLEAN;
BEGIN
    -- Check that df schema exists
    SELECT EXISTS(
        SELECT 1 FROM pg_namespace WHERE nspname = 'df'
    ) INTO schema_exists;
    
    -- Check that extension exists
    SELECT EXISTS(
        SELECT 1 FROM pg_extension WHERE extname = 'pg_durable'
    ) INTO extension_exists;
    
    IF NOT schema_exists THEN
        RAISE EXCEPTION 'TEST SETUP FAILED: df schema not created after extension installation';
    END IF;
    
    IF NOT extension_exists THEN
        RAISE EXCEPTION 'TEST SETUP FAILED: pg_durable extension not installed';
    END IF;
    
    RAISE NOTICE 'Extension restored successfully';
END $$;

-- Cleanup temp table
DROP TABLE _test_existing_instances;

SELECT 'TEST PASSED' AS result;
