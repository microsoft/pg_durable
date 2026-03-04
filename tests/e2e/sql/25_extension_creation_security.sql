-- Test: Extension creation security
-- Tests that:
-- 1. Non-superuser cannot create the extension
-- 2. Extension creation fails if 'df' schema is pre-created
-- Expected: Both security conditions are enforced

-- Note: This test drops and recreates the extension to test installation security
-- Any running instances will be lost, but E2E tests are self-contained
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

-- Re-grant permissions that were lost when the extension was dropped.
-- These mirror the grants in 00_setup_playground.sql.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user') THEN
        EXECUTE 'GRANT USAGE ON SCHEMA df TO df_e2e_user';
        EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO df_e2e_user';
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON df.instances TO df_e2e_user';
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON df.nodes TO df_e2e_user';
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO df_e2e_user';
        RAISE NOTICE 'Re-granted df_e2e_user permissions after extension recreate';
    END IF;
END $$;

-- Wait for the background worker to fully reinitialize after the drop/recreate.
--
-- After CREATE EXTENSION, the new df._worker_epoch table is empty. The OLD
-- runtime (from before the drop) is still running and can process functions, but
-- its epoch sentinel check (every 5s) will eventually detect the sentinel is
-- gone, shut down, and reinitialize. If we don't wait for this cycle to
-- complete, the old runtime's late sentinel check will shut down mid-test and
-- break later tests (like 27_user_isolation).
--
-- We wait for df._worker_epoch to be non-empty, which proves the worker has:
-- 1. Detected old sentinel gone → 2. Shut down old runtime →
-- 3. Waited for extension → 4. Reinitialized → 5. Written new sentinel
DO $$
DECLARE
    attempts INT := 0;
    sentinel_exists BOOLEAN;
BEGIN
    LOOP
        SELECT EXISTS(SELECT 1 FROM df._worker_epoch) INTO sentinel_exists;
        EXIT WHEN sentinel_exists OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF NOT sentinel_exists THEN
        RAISE EXCEPTION 'TEST SETUP FAILED: worker did not reinitialize after extension recreate (no sentinel after 30s)';
    END IF;

    RAISE NOTICE 'Worker epoch sentinel detected — full restart cycle complete';
END $$;

-- Now verify the worker is actually processing functions by submitting a
-- trivial function and waiting for completion.
-- NOTE: df.start() must be outside the DO block so the transaction commits
-- and the background worker can see the instance.
CREATE TEMP TABLE _test_state_25 (instance_id TEXT);
INSERT INTO _test_state_25 SELECT df.start(df.sql('SELECT 1'), 'verify-worker-ready');

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_25;
    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST SETUP FAILED: worker did not recover after extension recreate (status=%)', final_status;
    END IF;

    RAISE NOTICE 'Background worker reinitialized successfully';
END $$;

DROP TABLE _test_state_25;

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

SELECT 'TEST PASSED' AS result;
