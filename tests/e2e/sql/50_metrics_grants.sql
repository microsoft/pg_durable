-- Tests: df.metrics() access is controlled by PostgreSQL EXECUTE grants.
--
-- Verifies that:
--   1. An ordinary df.grant_usage() does NOT grant EXECUTE on df.metrics().
--   2. df.grant_usage(with_grant => true) grants EXECUTE WITH GRANT OPTION
--      (with_grant => true designates a pg_durable admin).
--   3. df.revoke_usage() removes the df.metrics() grant.
--   4. A non-superuser with an explicit GRANT can actually call df.metrics().
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

-- Helper: assert metrics_test_user's EXECUTE privilege on df.metrics() matches
-- the expected value, failing with a labelled message otherwise.
CREATE FUNCTION pg_temp.assert_metrics_exec(expected BOOLEAN, test_label TEXT)
RETURNS VOID LANGUAGE plpgsql AS $fn$
DECLARE
    has_execute BOOLEAN;
BEGIN
    SELECT has_function_privilege('metrics_test_user', 'df.metrics()', 'EXECUTE')
      INTO has_execute;

    IF has_execute IS DISTINCT FROM expected THEN
        RAISE EXCEPTION '% FAILED: expected EXECUTE on df.metrics() = %, got %',
            test_label, expected, has_execute;
    END IF;

    RAISE NOTICE '% PASSED', test_label;
END $fn$;

-- === Test 1: ordinary grant_usage() does NOT grant EXECUTE on df.metrics() ===
SELECT df.grant_usage('metrics_test_user');
SELECT pg_temp.assert_metrics_exec(false, 'TEST 1 (ordinary grant_usage omits df.metrics())');

-- === Test 2: grant_usage(with_grant => true) grants EXECUTE WITH GRANT OPTION ===
SELECT df.grant_usage('metrics_test_user', with_grant => true);
SELECT pg_temp.assert_metrics_exec(true, 'TEST 2 (with_grant admin gets df.metrics())');

DO $$
BEGIN
    IF NOT has_function_privilege(
        'metrics_test_user', 'df.metrics()', 'EXECUTE WITH GRANT OPTION'
    ) THEN
        RAISE EXCEPTION 'TEST 2 FAILED: with_grant => true should grant df.metrics() WITH GRANT OPTION';
    END IF;
    RAISE NOTICE 'TEST 2 PASSED (WITH GRANT OPTION)';
END $$;

-- === Test 3: revoke_usage() removes the df.metrics() grant ===
-- Reuses the with_grant grant from Test 2 — no separate setup needed.
SELECT df.revoke_usage('metrics_test_user');
SELECT pg_temp.assert_metrics_exec(false, 'TEST 3 (revoke_usage removes df.metrics())');

-- === Test 4: a non-superuser with an explicit GRANT can call df.metrics() ===
-- Re-grant ordinary usage (schema USAGE is the access gate) and add an explicit
-- df.metrics() grant on top.
SELECT df.grant_usage('metrics_test_user');
GRANT EXECUTE ON FUNCTION df.metrics() TO metrics_test_user;

SET SESSION AUTHORIZATION metrics_test_user;
DO $$
DECLARE
    total_instances BIGINT;
BEGIN
    SELECT m.total_instances INTO total_instances FROM df.metrics() m;
    RAISE NOTICE 'TEST 4 PASSED: explicit GRANT allows df.metrics() (total_instances = %)', total_instances;
END $$;
RESET SESSION AUTHORIZATION;

-- === Cleanup ===
DROP FUNCTION pg_temp.assert_metrics_exec(BOOLEAN, TEXT);

DO $cleanup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
     WHERE usename = 'metrics_test_user'
       AND pid <> pg_backend_pid();

    DROP OWNED BY metrics_test_user;
    DROP ROLE metrics_test_user;
END $cleanup$;

SELECT 'TEST PASSED: 50_metrics_grants' AS result;
