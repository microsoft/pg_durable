-- Tests: df.metrics() is restricted to superusers only.
--
-- Verifies that:
--   1. A non-superuser role granted via df.grant_usage() does NOT receive
--      EXECUTE on df.metrics().
--   2. A non-superuser calling df.metrics() gets a permission-denied error.
--   3. A superuser (postgres) can still call df.metrics() successfully.
--
-- Runs as postgres throughout (creates/drops roles, uses SET SESSION AUTHORIZATION).

-- === Setup ===
DO $setup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
     WHERE usename = 'metrics_test_user'
       AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY metrics_test_user; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE metrics_test_user;     EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

CREATE ROLE metrics_test_user LOGIN;
GRANT TEMPORARY ON DATABASE postgres TO metrics_test_user;
GRANT USAGE, CREATE ON SCHEMA public TO metrics_test_user;

SELECT df.grant_usage('metrics_test_user');

-- === Test 1: grant_usage() does NOT grant EXECUTE on df.metrics() ===
DO $$
DECLARE
    has_execute BOOLEAN;
BEGIN
    SELECT has_function_privilege(
        'metrics_test_user',
        'df.metrics()',
        'EXECUTE'
    ) INTO has_execute;

    IF has_execute THEN
        RAISE EXCEPTION 'TEST 1 FAILED: metrics_test_user should NOT have EXECUTE on df.metrics() after grant_usage()';
    END IF;

    RAISE NOTICE 'TEST 1 PASSED: grant_usage() does not grant EXECUTE on df.metrics() to non-superuser';
END $$;

-- === Test 2: non-superuser calling df.metrics() gets permission denied ===
SET SESSION AUTHORIZATION metrics_test_user;

DO $$
BEGIN
    BEGIN
        PERFORM df.metrics();
        RAISE EXCEPTION 'SECURITY FAILURE: non-superuser was able to call df.metrics()';
    EXCEPTION
        WHEN insufficient_privilege THEN
            -- User lacks EXECUTE privilege — PostgreSQL ACL check fires before
            -- the function body is reached.
            RAISE NOTICE 'TEST 2 PASSED: non-superuser blocked from df.metrics() (insufficient_privilege)';
        WHEN OTHERS THEN
            IF SQLERRM ILIKE '%permission denied%'
               OR SQLERRM ILIKE '%restricted to superusers%' THEN
                -- Defense-in-depth path: EXECUTE was manually granted but the
                -- in-function superuser check raised the error.
                RAISE NOTICE 'TEST 2 PASSED: non-superuser blocked from df.metrics() (%)', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST 2 UNEXPECTED ERROR: %', SQLERRM;
            END IF;
    END;
END $$;

RESET SESSION AUTHORIZATION;

-- === Test 3: superuser can call df.metrics() ===
DO $$
DECLARE
    total_instances BIGINT;
BEGIN
    SELECT m.total_instances
      INTO total_instances
      FROM df.metrics() m;

    -- Just verify it returns a row without error.
    RAISE NOTICE 'TEST 3 PASSED: superuser can call df.metrics() (total_instances = %)', total_instances;
END $$;

-- === Cleanup ===
DO $cleanup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
     WHERE usename = 'metrics_test_user'
       AND pid <> pg_backend_pid();

    DROP OWNED BY metrics_test_user;
    DROP ROLE metrics_test_user;
END $cleanup$;

SELECT 'TEST PASSED: 50_metrics_superuser' AS result;
