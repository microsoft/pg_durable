-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: delegated grant_usage / revoke_usage via with_grant parameter
--
-- Scenario: PaaS operator (superuser) grants an admin role the ability to
-- manage other roles' pg_durable access without superuser involvement.
--
-- Test matrix:
--   1. Superuser grants admin_role with with_grant => true
--   2. admin_role can use pg_durable (start + complete a workflow)
--   3. Non-superuser admin CAN set with_grant => true (delegated admin can create sub-admins)
--   4. Non-superuser admin CANNOT set include_http => true without HTTP grant permission
--   5. admin_role can call df.grant_usage() to grant app_role access
--   5b. granted app_role reaches ordinary df.* functions via schema USAGE
--       (no per-function EXECUTE grant) and is NOT granted df.http()
--   6. app_role can use pg_durable (start + complete a workflow)
--   7. app_role CANNOT call df.grant_usage() (no EXECUTE privilege)
--   8. admin_role can revoke app_role access
--   9. app_role can no longer use pg_durable
--   10. Self-revoke is harmless: PostgreSQL's REVOKE only removes grants the
--       current role made, so admin_role cannot revoke its own postgres-granted
--       access (no explicit guard needed)
--
-- Note: cross-admin revoke is intentionally not tested here. These helper
-- functions are SECURITY INVOKER, and PostgreSQL revoke semantics are scoped
-- to the privileges the current role granted. That limitation is documented.
--
-- Runs as postgres throughout (creates/drops roles, uses SET SESSION AUTHORIZATION)

-- === Setup ===
DO $setup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename IN ('dg_admin', 'dg_app', 'dg_delegate_target', 'dg_http_target')
        AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY dg_admin; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY dg_app;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY dg_delegate_target; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY dg_http_target; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE dg_admin;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE dg_app;       EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE dg_delegate_target; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE dg_http_target; EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

CREATE ROLE dg_admin LOGIN;
CREATE ROLE dg_app   LOGIN;
CREATE ROLE dg_delegate_target LOGIN;
CREATE ROLE dg_http_target LOGIN;

-- The admin needs to create temp tables for df.start state tracking
GRANT TEMPORARY ON DATABASE postgres TO dg_admin, dg_app, dg_delegate_target, dg_http_target;
-- The admin needs CREATE on public for temp state tables used in tests
GRANT USAGE, CREATE ON SCHEMA public TO dg_admin, dg_app, dg_delegate_target, dg_http_target;

-- === Test 1: Superuser grants admin with with_grant => true ===
SELECT df.grant_usage('dg_admin', include_http => false, with_grant => true);

-- Verify admin has EXECUTE on admin helpers
DO $$
DECLARE
    can_grant BOOLEAN;
    can_revoke BOOLEAN;
BEGIN
    SELECT has_function_privilege(
        'dg_admin',
        'df.grant_usage(text, boolean, boolean)',
        'EXECUTE'
    ) INTO can_grant;

    SELECT has_function_privilege(
        'dg_admin',
        'df.revoke_usage(text)',
        'EXECUTE'
    ) INTO can_revoke;

    IF NOT can_grant THEN
        RAISE EXCEPTION 'TEST 1 FAILED: dg_admin should have EXECUTE on df.grant_usage after with_grant => true';
    END IF;

    IF NOT can_revoke THEN
        RAISE EXCEPTION 'TEST 1 FAILED: dg_admin should have EXECUTE on df.revoke_usage after with_grant => true';
    END IF;

    RAISE NOTICE 'TEST 1 PASSED: admin role has EXECUTE on admin helpers after with_grant => true';
END $$;

-- === Test 2: admin_role can use pg_durable ===
SET SESSION AUTHORIZATION dg_admin;

CREATE TEMP TABLE _dg_admin_state (instance_id TEXT);
INSERT INTO _dg_admin_state
SELECT df.start(df.sql('SELECT 100 AS admin_result'), 'dg-admin-test');

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _dg_admin_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST 2 FAILED: admin workflow expected completed, got %', status;
    END IF;

    RAISE NOTICE 'TEST 2 PASSED: admin role can use pg_durable';
END $$;

DROP TABLE _dg_admin_state;

-- === Test 3: non-superuser admin CAN set with_grant => true ===
-- Since dg_admin was granted with_grant => true, it holds all privileges
-- WITH GRANT OPTION and can delegate to other roles (including with_grant).
SET SESSION AUTHORIZATION dg_admin;

DO $$
BEGIN
    PERFORM df.grant_usage('dg_delegate_target', with_grant => true);
    RAISE NOTICE 'TEST 3 PASSED: delegated admin can set with_grant => true';
END $$;

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    can_grant BOOLEAN;
BEGIN
    SELECT has_function_privilege(
        'dg_delegate_target',
        'df.grant_usage(text, boolean, boolean)',
        'EXECUTE'
    ) INTO can_grant;

    IF NOT can_grant THEN
        RAISE EXCEPTION 'TEST 3 FAILED: dg_delegate_target should have EXECUTE on df.grant_usage after with_grant delegation';
    END IF;

    RAISE NOTICE 'TEST 3 verification PASSED: delegated with_grant propagated admin helper access';
END $$;

-- Clean up the delegation so it doesn't affect later tests
SELECT df.revoke_usage('dg_delegate_target');

-- === Test 4: non-superuser admin CANNOT set include_http => true without HTTP grant permission ===
SET SESSION AUTHORIZATION dg_admin;

DO $$
BEGIN
    BEGIN
        PERFORM df.grant_usage('dg_http_target', include_http => true);
        RAISE EXCEPTION 'SECURITY FAILURE: non-superuser admin was able to set include_http => true without HTTP grant permission';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'TEST 4 PASSED: non-superuser admin blocked from setting include_http => true without HTTP grant permission';
        WHEN OTHERS THEN
            IF SQLERRM ILIKE '%permission denied%' THEN
                RAISE NOTICE 'TEST 4 PASSED: non-superuser admin blocked from setting include_http => true (%)', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST 4 UNEXPECTED ERROR: %', SQLERRM;
            END IF;
    END;
END $$;

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    can_http BOOLEAN;
BEGIN
    SELECT has_function_privilege(
        'dg_http_target',
        'df.http(text, text, text, jsonb, integer)',
        'EXECUTE'
    ) INTO can_http;

    IF can_http THEN
        RAISE EXCEPTION 'TEST 4 FAILED: dg_http_target should NOT have EXECUTE on df.http after failed include_http attempt';
    END IF;

    RAISE NOTICE 'TEST 4 verification PASSED: failed include_http attempt did not grant HTTP access';
END $$;

-- === Test 5: admin_role can grant access to app_role (without with_grant) ===
SET SESSION AUTHORIZATION dg_admin;

DO $$
BEGIN
    PERFORM df.grant_usage('dg_app');
    RAISE NOTICE 'TEST 5 PASSED: admin role successfully called df.grant_usage for app role';
END $$;

RESET SESSION AUTHORIZATION;

-- Verify app_role does NOT have EXECUTE on admin helpers
DO $$
DECLARE
    can_grant BOOLEAN;
    can_revoke BOOLEAN;
BEGIN
    SELECT has_function_privilege(
        'dg_app',
        'df.grant_usage(text, boolean, boolean)',
        'EXECUTE'
    ) INTO can_grant;

    SELECT has_function_privilege(
        'dg_app',
        'df.revoke_usage(text)',
        'EXECUTE'
    ) INTO can_revoke;

    IF can_grant THEN
        RAISE EXCEPTION 'TEST 5 FAILED: dg_app should NOT have EXECUTE on df.grant_usage';
    END IF;

    IF can_revoke THEN
        RAISE EXCEPTION 'TEST 5 FAILED: dg_app should NOT have EXECUTE on df.revoke_usage';
    END IF;

    RAISE NOTICE 'TEST 5 verification PASSED: app role does not have admin helper access';
END $$;

-- === Test 5b: granted app_role reaches ordinary functions via schema USAGE,
-- and a plain grant (no include_http) does NOT expose df.http() ===
-- This pins the access model after dropping the explicit func_sigs allowlist
-- from df.grant_usage(): schema USAGE is the gate for ordinary df.* functions
-- (which retain PostgreSQL's default PUBLIC EXECUTE), while df.http() stays
-- opt-in because its PUBLIC EXECUTE is revoked at install time.
DO $$
DECLARE
    has_usage BOOLEAN;
    can_start BOOLEAN;
    can_http BOOLEAN;
BEGIN
    SELECT has_schema_privilege('dg_app', 'df', 'USAGE') INTO has_usage;
    SELECT has_function_privilege('dg_app', 'df.start(text, text, text)', 'EXECUTE') INTO can_start;
    SELECT has_function_privilege('dg_app', 'df.http(text, text, text, jsonb, integer)', 'EXECUTE') INTO can_http;

    IF NOT has_usage THEN
        RAISE EXCEPTION 'TEST 5b FAILED: dg_app should have USAGE on schema df after grant_usage';
    END IF;

    IF NOT can_start THEN
        RAISE EXCEPTION 'TEST 5b FAILED: dg_app should reach df.start via schema USAGE + default PUBLIC EXECUTE';
    END IF;

    IF can_http THEN
        RAISE EXCEPTION 'SECURITY FAILURE: dg_app granted without include_http should NOT have EXECUTE on df.http';
    END IF;

    RAISE NOTICE 'TEST 5b PASSED: USAGE gates ordinary functions; df.http remains opt-in for a plain grant';
END $$;

-- === Test 6: app_role can use pg_durable ===
SET SESSION AUTHORIZATION dg_app;

CREATE TEMP TABLE _dg_app_state (instance_id TEXT);
INSERT INTO _dg_app_state
SELECT df.start(df.sql('SELECT 200 AS app_result'), 'dg-app-test');

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _dg_app_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST 6 FAILED: app workflow expected completed, got %', status;
    END IF;

    RAISE NOTICE 'TEST 6 PASSED: app role can use pg_durable via delegated grant';
END $$;

DROP TABLE _dg_app_state;

-- === Test 7: app_role CANNOT call df.grant_usage() ===
SET SESSION AUTHORIZATION dg_app;

DO $$
BEGIN
    BEGIN
        PERFORM df.grant_usage('dg_admin');
        RAISE EXCEPTION 'SECURITY FAILURE: app role was able to call df.grant_usage()';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'TEST 7 PASSED: app role blocked from calling df.grant_usage (insufficient privilege)';
    END;
END $$;

RESET SESSION AUTHORIZATION;

-- === Test 8: admin_role can revoke app_role access ===
SET SESSION AUTHORIZATION dg_admin;

DO $$
DECLARE
    still_has_usage BOOLEAN;
BEGIN
    PERFORM df.revoke_usage('dg_app');
    RAISE NOTICE 'TEST 8 PASSED: admin role successfully called df.revoke_usage for app role';

    -- Schema USAGE is the access gate; revoke_usage() must remove it.
    SELECT has_schema_privilege('dg_app', 'df', 'USAGE') INTO still_has_usage;
    IF still_has_usage THEN
        RAISE EXCEPTION 'TEST 8 FAILED: dg_app still has USAGE on schema df after revoke_usage';
    END IF;
    RAISE NOTICE 'TEST 8 PASSED: dg_app lost USAGE on schema df (access gate closed)';
END $$;

RESET SESSION AUTHORIZATION;

-- === Test 9: app_role can no longer use pg_durable ===
SET SESSION AUTHORIZATION dg_app;

DO $$
BEGIN
    BEGIN
        PERFORM df.start(df.sql('SELECT 1 AS should_not_run_after_revoke'), 'dg-app-after-revoke');
        RAISE EXCEPTION 'SECURITY FAILURE: revoked app role was able to call df.start()';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'TEST 9 PASSED: revoked app role blocked from df.start()';
        WHEN OTHERS THEN
            IF SQLERRM ILIKE '%permission denied%' THEN
                RAISE NOTICE 'TEST 9 PASSED: revoked app role blocked from df.start() (%)', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST 9 UNEXPECTED ERROR: %', SQLERRM;
            END IF;
    END;
END $$;

RESET SESSION AUTHORIZATION;

-- === Test 10: Self-revoke is harmless (PostgreSQL built-in protection) ===
-- We don't have an explicit self-revoke guard. None is needed: PostgreSQL's
-- REVOKE only removes grants made by the current role, and dg_admin's
-- privileges were granted by postgres (not by dg_admin itself). So a
-- self-revoke attempt is a no-op and dg_admin retains its access.
SET SESSION AUTHORIZATION dg_admin;

DO $$
DECLARE
    still_has_usage BOOLEAN;
BEGIN
    -- Attempt to revoke own access; PostgreSQL leaves it intact.
    PERFORM df.revoke_usage('dg_admin');

    SELECT has_schema_privilege('dg_admin', 'df', 'USAGE') INTO still_has_usage;
    IF NOT still_has_usage THEN
        RAISE EXCEPTION 'TEST 10 FAILED: dg_admin lost USAGE after self-revoke (expected PostgreSQL to keep it)';
    END IF;
    RAISE NOTICE 'TEST 10 PASSED: self-revoke is a no-op; dg_admin retains access (built into PostgreSQL)';
END $$;

RESET SESSION AUTHORIZATION;

-- === Cleanup ===
-- Revoke admin privileges (as superuser)
SELECT df.revoke_usage('dg_admin');

DO $cleanup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename IN ('dg_admin', 'dg_app', 'dg_delegate_target', 'dg_http_target')
        AND pid <> pg_backend_pid();

    DROP OWNED BY dg_admin;
    DROP OWNED BY dg_app;
    DROP OWNED BY dg_delegate_target;
    DROP OWNED BY dg_http_target;
    DROP ROLE dg_admin;
    DROP ROLE dg_app;
    DROP ROLE dg_delegate_target;
    DROP ROLE dg_http_target;
END $cleanup$;

SELECT 'TEST PASSED: 18_delegated_grants' AS result;
