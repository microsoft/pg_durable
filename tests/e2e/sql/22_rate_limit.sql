-- 22_rate_limit.sql
-- Tests: df.max_concurrent_per_user and df.max_instances_per_user GUC enforcement
--
-- Cases covered:
--   1. Concurrency cap: 3rd df.start() is rejected when limit = 2.
--   2. After one instance is cancelled, a new df.start() succeeds.
--   3. Instance quota: df.start() is rejected when total count reaches limit.
--   4. Superuser bypasses both limits.
--
-- Runs as postgres throughout; identity switching is explicit.

-- ============================================================
-- Setup
-- ============================================================
DO $setup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename = 'rl_test_user' AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY rl_test_user; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE rl_test_user; EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

CREATE ROLE rl_test_user LOGIN;
SELECT df.grant_usage('rl_test_user');
GRANT TEMPORARY ON DATABASE postgres TO rl_test_user;

-- Persistent table so superuser can cancel the long-running instances.
DROP TABLE IF EXISTS _rl_long_instances;
CREATE TABLE _rl_long_instances (instance_id TEXT);
GRANT INSERT ON _rl_long_instances TO rl_test_user;

-- ============================================================
-- Test 1: Concurrency cap enforcement
-- ============================================================

SET df.max_concurrent_per_user = 2;

-- Start 2 long-running instances as rl_test_user so they stay active.
SET SESSION AUTHORIZATION rl_test_user;
INSERT INTO _rl_long_instances SELECT df.start(df.sleep(60), 'rl-concurrent-1');
INSERT INTO _rl_long_instances SELECT df.start(df.sleep(60), 'rl-concurrent-2');
RESET SESSION AUTHORIZATION;

-- Third start must be rejected.
DO $$
DECLARE
    caught BOOLEAN := false;
    msg TEXT;
BEGIN
    BEGIN
        SET SESSION AUTHORIZATION rl_test_user;
        PERFORM df.start(df.sleep(60), 'rl-concurrent-3-should-fail');
        RESET SESSION AUTHORIZATION;
    EXCEPTION WHEN OTHERS THEN
        caught := true;
        msg := SQLERRM;
        RESET SESSION AUTHORIZATION;
    END;

    IF NOT caught THEN
        RAISE EXCEPTION 'TEST 1 FAILED: expected df.start() to be rejected at concurrency limit';
    END IF;

    IF msg NOT LIKE '%max_concurrent_per_user%' THEN
        RAISE EXCEPTION 'TEST 1 FAILED: error message does not mention max_concurrent_per_user, got: %', msg;
    END IF;

    RAISE NOTICE 'TEST 1 PASSED: concurrency cap enforced (error: %)', msg;
END $$;

-- ============================================================
-- Test 2: After one instance is cancelled, a new df.start() succeeds
-- ============================================================

-- Cancel one of the running instances (superuser can cancel any instance).
DO $$
DECLARE
    inst_id TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _rl_long_instances LIMIT 1;
    PERFORM df.cancel(inst_id, 'Test 2: freeing slot');
END $$;

-- Now rl_test_user has 1 active instance — below the limit of 2.
-- Create temp table as the user so they can INSERT into it.
SET SESSION AUTHORIZATION rl_test_user;
CREATE TEMP TABLE _rl_t2 (instance_id TEXT);
INSERT INTO _rl_t2 SELECT df.start('SELECT 1', 'rl-after-cancel');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _rl_t2;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST 2 FAILED: expected completed after slot freed, got %', status;
    END IF;
    RAISE NOTICE 'TEST 2 PASSED: new df.start() succeeded after a slot was freed';
END $$;

DROP TABLE _rl_t2;

-- Cancel the remaining long-running instance before Test 3.
DO $$
DECLARE
    inst_id TEXT;
BEGIN
    FOR inst_id IN SELECT instance_id FROM _rl_long_instances LOOP
        BEGIN
            PERFORM df.cancel(inst_id, 'Test cleanup');
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
END $$;

-- ============================================================
-- Test 3: Instance total quota enforcement
-- ============================================================

-- Lift concurrency limit so it doesn't interfere.
SET df.max_concurrent_per_user = 1000;

-- Set total quota to current count + 1 so one more succeeds, then blocks.
DO $$
DECLARE
    current_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO current_count
      FROM df.instances
     WHERE submitted_by = 'rl_test_user'::regrole;

    EXECUTE format('SET df.max_instances_per_user = %s', current_count + 1);
END $$;

-- This start should succeed (fills the quota exactly).
SET SESSION AUTHORIZATION rl_test_user;
CREATE TEMP TABLE _rl_t3a (instance_id TEXT);
INSERT INTO _rl_t3a SELECT df.start('SELECT 1', 'rl-quota-fill');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _rl_t3a;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST 3a FAILED: expected completed, got %', status;
    END IF;
    RAISE NOTICE 'TEST 3a PASSED: last allowed instance completed';
END $$;

DROP TABLE _rl_t3a;

-- This start must be rejected (quota exceeded).
DO $$
DECLARE
    caught BOOLEAN := false;
    msg TEXT;
BEGIN
    BEGIN
        SET SESSION AUTHORIZATION rl_test_user;
        PERFORM df.start('SELECT 1', 'rl-quota-exceed');
        RESET SESSION AUTHORIZATION;
    EXCEPTION WHEN OTHERS THEN
        caught := true;
        msg := SQLERRM;
        RESET SESSION AUTHORIZATION;
    END;

    IF NOT caught THEN
        RAISE EXCEPTION 'TEST 3b FAILED: expected df.start() to be rejected at quota limit';
    END IF;

    IF msg NOT LIKE '%max_instances_per_user%' THEN
        RAISE EXCEPTION 'TEST 3b FAILED: error message does not mention max_instances_per_user, got: %', msg;
    END IF;

    RAISE NOTICE 'TEST 3b PASSED: instance quota enforced (error: %)', msg;
END $$;

-- ============================================================
-- Test 4: Superuser bypasses both limits
-- ============================================================

-- Keep limits very tight.
SET df.max_concurrent_per_user = 1;
SET df.max_instances_per_user = 1;

-- Superuser (postgres) should not be blocked.
CREATE TEMP TABLE _rl_t4 (instance_id TEXT);
INSERT INTO _rl_t4 SELECT df.start('SELECT 1', 'rl-superuser-bypass');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _rl_t4;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST 4 FAILED: superuser df.start() was blocked, got status %', status;
    END IF;
    RAISE NOTICE 'TEST 4 PASSED: superuser bypasses rate limits';
END $$;

DROP TABLE _rl_t4;

-- ============================================================
-- Cleanup
-- ============================================================

-- Restore defaults.
SET df.max_concurrent_per_user = 100;
SET df.max_instances_per_user = 10000;

DROP TABLE IF EXISTS _rl_long_instances;

DO $teardown$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename = 'rl_test_user' AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY rl_test_user; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE rl_test_user; EXCEPTION WHEN undefined_object THEN NULL; END;
END $teardown$;

SELECT 'TEST PASSED' AS result;
