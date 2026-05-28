-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 28_bgw_lifecycle, 25_extension_creation_security
-- Tests: BGW lifecycle (pre-extension wait, post-CREATE, post-DROP, post-recreate),
--        extension creation security (non-superuser blocked, pre-existing df schema blocked,
--        ungranted role blocked, grant_usage/revoke_usage restricted)
-- Runs as postgres throughout (requires superuser for DROP/CREATE EXTENSION)
-- Note: 28 runs before 25 so the extension is in a known state when 25 starts

-- === Test: 28_bgw_lifecycle ===

-- Ensure a clean starting point
SELECT public._e2e_drop_extension_safe();

-- 1) Verify BGW does not create duroxide schema pre-extension
DO $$
DECLARE
    exists_before BOOLEAN;
    exists_after BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide') INTO exists_before;
    IF exists_before THEN
        RAISE EXCEPTION 'TEST FAILED: duroxide schema exists before CREATE EXTENSION';
    END IF;

    PERFORM pg_sleep(6);

    SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide') INTO exists_after;
    IF exists_after THEN
        RAISE EXCEPTION 'TEST FAILED: duroxide schema was created before CREATE EXTENSION';
    END IF;

    RAISE NOTICE 'PASSED: BGW did not create duroxide schema pre-extension';
END $$;

-- 2) Create extension and run a simple workflow
CREATE EXTENSION pg_durable;

-- Re-grant df privileges to the E2E user
SELECT df.grant_usage('df_e2e_user');

-- Wait for the background worker to initialize
SELECT public._e2e_wait_for_worker_ready();

CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state
SELECT df.start('SELECT 42 as answer', 'test-bgw-lifecycle-1');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed, got %', status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result NOT LIKE '%42%' THEN
        RAISE EXCEPTION 'TEST FAILED: result should contain 42, got %', result;
    END IF;

    RAISE NOTICE 'PASSED: workflow completed after CREATE EXTENSION';
END $$;

DROP TABLE _test_state;

-- 3) Drop extension and verify schema removed
SELECT public._e2e_drop_extension_safe();

DO $$
DECLARE
    schema_exists BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide') INTO schema_exists;
    IF schema_exists THEN
        RAISE EXCEPTION 'TEST FAILED: duroxide schema still exists after DROP EXTENSION';
    END IF;

    RAISE NOTICE 'PASSED: DROP EXTENSION removed duroxide schema';
END $$;

-- 4) Re-create extension and run another workflow
CREATE EXTENSION pg_durable;

SELECT df.grant_usage('df_e2e_user');

SELECT public._e2e_wait_for_worker_ready();

CREATE TEMP TABLE _test_state2 (instance_id TEXT);
INSERT INTO _test_state2
SELECT df.start('SELECT 43 as answer', 'test-bgw-lifecycle-2');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state2;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed after recreate, got %', status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result NOT LIKE '%43%' THEN
        RAISE EXCEPTION 'TEST FAILED: result should contain 43, got %', result;
    END IF;

    RAISE NOTICE 'PASSED: workflow completed after re-create';
END $$;

DROP TABLE _test_state2;

-- === Test: 25_extension_creation_security ===

-- Drop and recreate the extension to test installation security
SELECT public._e2e_drop_extension_safe();

-- Test 1: Non-superuser cannot create extension
DROP USER IF EXISTS test_nonsuperuser;
CREATE USER test_nonsuperuser;

SET ROLE test_nonsuperuser;
DO $$
BEGIN
    EXECUTE 'CREATE EXTENSION pg_durable';
    RAISE EXCEPTION 'SECURITY FAILURE: Non-superuser was able to create pg_durable extension!';
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'TEST 1 PASSED: Non-superuser correctly denied extension creation';
    WHEN OTHERS THEN
        IF SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%superuser%' THEN
            RAISE NOTICE 'TEST 1 PASSED: Non-superuser correctly denied extension creation (%)', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST 1 FAILED: Unexpected error: %', SQLERRM;
        END IF;
END $$;
RESET ROLE;

DROP USER test_nonsuperuser;

-- Test 2: Extension creation fails if 'df' schema pre-exists
CREATE SCHEMA IF NOT EXISTS df;

DO $$
DECLARE
    extension_created BOOLEAN := FALSE;
BEGIN
    BEGIN
        CREATE EXTENSION pg_durable;
        extension_created := TRUE;
    EXCEPTION
        WHEN duplicate_schema THEN
            RAISE NOTICE 'TEST 2 PASSED: Extension creation correctly prevented with pre-existing df schema';
        WHEN OTHERS THEN
            IF SQLERRM ILIKE '%schema%' OR SQLERRM ILIKE '%already exists%' OR SQLERRM ILIKE '%df%' THEN
                RAISE NOTICE 'TEST 2 PASSED: Extension creation correctly prevented with pre-existing df schema (%)', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST 2 FAILED: Unexpected error during extension creation: %', SQLERRM;
            END IF;
    END;
    
    IF extension_created THEN
        RAISE EXCEPTION 'SECURITY FAILURE: Extension created successfully even with pre-existing df schema!';
    END IF;
END $$;

DROP SCHEMA IF EXISTS df CASCADE;

-- Recreate the extension properly for remaining tests
CREATE EXTENSION pg_durable;

-- Test 3: Ungranted role cannot call df.sql() / df.start()
-- (At this point extension exists but df_e2e_user has no explicit grants yet)
SET ROLE df_e2e_user;

DO $$
BEGIN
    BEGIN
        PERFORM df.sql('SELECT 1');
        RAISE EXCEPTION 'SECURITY FAILURE: ungranted role was able to call df.sql()';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'TEST 3a PASSED: df.sql() blocked for ungranted role (insufficient privilege)';
    END;

    BEGIN
        PERFORM df.start(df.sql('SELECT 1'), 'ungranted-role-test');
        RAISE EXCEPTION 'SECURITY FAILURE: ungranted role was able to call df.start()';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'TEST 3b PASSED: df.start() blocked for ungranted role (insufficient privilege)';
    END;
END $$;

RESET ROLE;

-- Test 3c: Admin helpers are not executable by non-superusers by default
DO $$
DECLARE
    can_grant_usage BOOLEAN;
    can_revoke_usage BOOLEAN;
BEGIN
    SELECT has_function_privilege(
        'df_e2e_user',
        'df.grant_usage(text, boolean, boolean)',
        'EXECUTE'
    ) INTO can_grant_usage;

    SELECT has_function_privilege(
        'df_e2e_user',
        'df.revoke_usage(text)',
        'EXECUTE'
    ) INTO can_revoke_usage;

    IF can_grant_usage THEN
        RAISE EXCEPTION 'SECURITY FAILURE: df.grant_usage() is executable by df_e2e_user before any explicit helper grant';
    END IF;

    IF can_revoke_usage THEN
        RAISE EXCEPTION 'SECURITY FAILURE: df.revoke_usage() is executable by df_e2e_user before any explicit helper grant';
    END IF;

    RAISE NOTICE 'TEST 3c PASSED: admin helpers are not executable by non-superusers by default';
END $$;

-- Re-grant df privileges to the E2E user
SELECT df.grant_usage('df_e2e_user');

-- Test 4: df.grant_usage() does not grant EXECUTE on admin helpers to the target role
DO $$
DECLARE
    can_grant_usage BOOLEAN;
    can_revoke_usage BOOLEAN;
BEGIN
    SELECT has_function_privilege(
        'df_e2e_user',
        'df.grant_usage(text, boolean, boolean)',
        'EXECUTE'
    ) INTO can_grant_usage;

    SELECT has_function_privilege(
        'df_e2e_user',
        'df.revoke_usage(text)',
        'EXECUTE'
    ) INTO can_revoke_usage;

    IF can_grant_usage THEN
        RAISE EXCEPTION 'SECURITY FAILURE: df.grant_usage() granted EXECUTE on itself to df_e2e_user';
    END IF;

    IF can_revoke_usage THEN
        RAISE EXCEPTION 'SECURITY FAILURE: df.grant_usage() granted EXECUTE on df.revoke_usage() to df_e2e_user';
    END IF;

    RAISE NOTICE 'TEST 4 PASSED: df.grant_usage() does not grant EXECUTE on admin helpers';
END $$;

-- Test 5: If EXECUTE is granted manually but without WITH GRANT OPTION on
-- underlying objects, the inner GRANT/REVOKE statements fail (PostgreSQL's
-- native privilege checks prevent escalation).
DROP ROLE IF EXISTS test_helper_grantee;
CREATE ROLE test_helper_grantee LOGIN;

GRANT USAGE ON SCHEMA df TO test_helper_grantee;
GRANT EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) TO test_helper_grantee;
GRANT EXECUTE ON FUNCTION df.revoke_usage(text) TO test_helper_grantee;

SET ROLE test_helper_grantee;

DO $$
BEGIN
    BEGIN
        PERFORM df.grant_usage('df_e2e_user');
        RAISE EXCEPTION 'SECURITY FAILURE: manually granted non-superuser was able to call df.grant_usage()';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'TEST 5a PASSED: df.grant_usage() blocked by PostgreSQL privilege check';
        WHEN OTHERS THEN
            IF SQLERRM ILIKE '%permission denied%' THEN
                RAISE NOTICE 'TEST 5a PASSED: df.grant_usage() blocked by PostgreSQL privilege check (%)', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST 5a UNEXPECTED ERROR: %', SQLERRM;
            END IF;
    END;

    BEGIN
        PERFORM df.revoke_usage('df_e2e_user');
        RAISE EXCEPTION 'SECURITY FAILURE: manually granted non-superuser was able to call df.revoke_usage()';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'TEST 5b PASSED: df.revoke_usage() blocked by PostgreSQL privilege check';
        WHEN OTHERS THEN
            IF SQLERRM ILIKE '%permission denied%' OR SQLERRM ILIKE '%cannot revoke df privileges%' THEN
                RAISE NOTICE 'TEST 5b PASSED: df.revoke_usage() blocked (%)', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST 5b UNEXPECTED ERROR: %', SQLERRM;
            END IF;
    END;
END $$;

RESET ROLE;

REVOKE EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) FROM test_helper_grantee;
REVOKE EXECUTE ON FUNCTION df.revoke_usage(text) FROM test_helper_grantee;
REVOKE USAGE ON SCHEMA df FROM test_helper_grantee;
DROP ROLE test_helper_grantee;

-- Wait for the background worker to fully reinitialize after the drop/recreate.
SELECT public._e2e_wait_for_worker_ready();

-- Verify the worker is actually processing functions
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
    SELECT EXISTS(
        SELECT 1 FROM pg_namespace WHERE nspname = 'df'
    ) INTO schema_exists;
    
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
