-- Test: User Isolation - SQL executed with submitter's privileges
--
-- This test must run as SUPERUSER because it creates/drops roles.
-- It validates that durable functions execute SQL as the submitting user,
-- not as the background worker's superuser.

-- ============================================================================
-- Setup: Create two test users with separate tables
-- ============================================================================
DO $setup$
BEGIN
    -- Clean up from any previous run
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename IN ('iso_alice', 'iso_bob')
        AND pid <> pg_backend_pid();

    -- Drop roles if they exist (CASCADE owned objects first)
    BEGIN DROP OWNED BY iso_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY iso_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

-- Create users
CREATE ROLE iso_alice LOGIN;
CREATE ROLE iso_bob   LOGIN;

-- Grant df permissions
GRANT USAGE ON SCHEMA df TO iso_alice, iso_bob;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO iso_alice, iso_bob;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.instances, df.nodes TO iso_alice, iso_bob;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO iso_alice, iso_bob;
-- Alice and Bob need CREATE TEMP TABLE for their test state tables
GRANT TEMPORARY ON DATABASE postgres TO iso_alice, iso_bob;

-- Create per-user tables
CREATE TABLE IF NOT EXISTS iso_alice_data (id SERIAL PRIMARY KEY, value TEXT);
ALTER TABLE iso_alice_data OWNER TO iso_alice;
INSERT INTO iso_alice_data (value) VALUES ('alice secret') ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS iso_bob_data (id SERIAL PRIMARY KEY, value TEXT);
ALTER TABLE iso_bob_data OWNER TO iso_bob;
INSERT INTO iso_bob_data (value) VALUES ('bob secret') ON CONFLICT DO NOTHING;

-- ============================================================================
-- Test 1: Alice can access her own table via durable function
-- ============================================================================
-- Create temp table INSIDE SET SESSION AUTHORIZATION so iso_alice owns it
SET SESSION AUTHORIZATION iso_alice;
CREATE TEMP TABLE _test_state_1 (instance_id TEXT);
INSERT INTO _test_state_1
SELECT df.start(df.sql('SELECT value FROM iso_alice_data LIMIT 1'), 'iso-alice-own');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_1;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 1 - alice own table): expected completed, got %', final_status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result IS NULL OR result NOT LIKE '%alice secret%' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 1): expected alice secret, got %', result;
    END IF;

    RAISE NOTICE 'Test 1 PASSED: Alice can access her own table';
END $$;

DROP TABLE _test_state_1;

-- ============================================================================
-- Test 2: Alice CANNOT access Bob's table via durable function
-- ============================================================================
SET SESSION AUTHORIZATION iso_alice;
CREATE TEMP TABLE _test_state_2 (instance_id TEXT);
INSERT INTO _test_state_2
SELECT df.start(df.sql('SELECT value FROM iso_bob_data LIMIT 1'), 'iso-alice-bob');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_2;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 2 - alice access bob table): expected failed, got %', final_status;
    END IF;

    RAISE NOTICE 'Test 2 PASSED: Alice cannot access Bob''s table';
END $$;

DROP TABLE _test_state_2;

-- ============================================================================
-- Test 3: Bob can access his own table via durable function
-- ============================================================================
SET SESSION AUTHORIZATION iso_bob;
CREATE TEMP TABLE _test_state_3 (instance_id TEXT);
INSERT INTO _test_state_3
SELECT df.start(df.sql('SELECT value FROM iso_bob_data LIMIT 1'), 'iso-bob-own');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_3;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 3 - bob own table): expected completed, got %', final_status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result IS NULL OR result NOT LIKE '%bob secret%' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 3): expected bob secret, got %', result;
    END IF;

    RAISE NOTICE 'Test 3 PASSED: Bob can access his own table';
END $$;

DROP TABLE _test_state_3;

-- ============================================================================
-- Test 4: Bob CANNOT access Alice's table via durable function
-- ============================================================================
SET SESSION AUTHORIZATION iso_bob;
CREATE TEMP TABLE _test_state_4 (instance_id TEXT);
INSERT INTO _test_state_4
SELECT df.start(df.sql('SELECT value FROM iso_alice_data LIMIT 1'), 'iso-bob-alice');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_4;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 4 - bob access alice table): expected failed, got %', final_status;
    END IF;

    RAISE NOTICE 'Test 4 PASSED: Bob cannot access Alice''s table';
END $$;

DROP TABLE _test_state_4;

-- ============================================================================
-- Test 5: SET ROLE with a group role (no LOGIN)
-- ============================================================================
DO $group_setup$
BEGIN
    BEGIN DROP OWNED BY iso_analysts; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_analysts;     EXCEPTION WHEN undefined_object THEN NULL; END;
END $group_setup$;

CREATE ROLE iso_analysts NOLOGIN;
CREATE TABLE IF NOT EXISTS iso_analyst_data (id SERIAL PRIMARY KEY, value TEXT);
ALTER TABLE iso_analyst_data OWNER TO iso_analysts;
INSERT INTO iso_analyst_data (value) VALUES ('analyst report') ON CONFLICT DO NOTHING;

-- Grant iso_analysts to alice and grant df permissions to the group role
GRANT iso_analysts TO iso_alice;
GRANT USAGE ON SCHEMA df TO iso_analysts;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO iso_analysts;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.instances, df.nodes TO iso_analysts;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO iso_analysts;
GRANT TEMPORARY ON DATABASE postgres TO iso_analysts;

SET SESSION AUTHORIZATION iso_alice;
SET ROLE iso_analysts;
-- session_user = iso_alice, current_user (outer) = iso_analysts
CREATE TEMP TABLE _test_state_5 (instance_id TEXT);
INSERT INTO _test_state_5
SELECT df.start(df.sql('SELECT value FROM iso_analyst_data LIMIT 1'), 'iso-set-role');
RESET ROLE;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    result TEXT;
    inst_login TEXT;
    inst_submitted TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_5;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 5 - SET ROLE): expected completed, got %', final_status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result IS NULL OR result NOT LIKE '%analyst report%' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 5): expected analyst report, got %', result;
    END IF;

    -- Verify identity columns on the instance
    SELECT submitted_by::text, login_role::text INTO inst_submitted, inst_login
      FROM df.instances WHERE id = inst_id;

    IF inst_login != 'iso_alice' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 5): expected login_role=iso_alice, got %', inst_login;
    END IF;
    IF inst_submitted != 'iso_analysts' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 5): expected submitted_by=iso_analysts, got %', inst_submitted;
    END IF;

    RAISE NOTICE 'Test 5 PASSED: SET ROLE group role works (login=iso_alice, effective=iso_analysts)';
END $$;

DROP TABLE _test_state_5;

-- ============================================================================
-- Test 6: SECURITY DEFINER function - captures caller, not definer
-- ============================================================================
-- This verifies that GetOuterUserId() correctly identifies the caller's
-- identity, not the function owner's identity, when df.start() is called
-- inside a SECURITY DEFINER function.

-- Create a superuser-only table (alice has no access)
CREATE TABLE IF NOT EXISTS iso_superuser_secrets (id SERIAL PRIMARY KEY, value TEXT);
INSERT INTO iso_superuser_secrets (value) VALUES ('classified') ON CONFLICT DO NOTHING;
-- Do NOT grant alice any access to this table

-- Create a SECURITY DEFINER wrapper function owned by superuser
CREATE OR REPLACE FUNCTION iso_submit_as_definer(q TEXT) RETURNS TEXT
LANGUAGE SQL SECURITY DEFINER
AS $$
    SELECT df.start(df.sql(q), 'secdef-test');
$$;

-- Grant alice permission to execute the wrapper
GRANT EXECUTE ON FUNCTION iso_submit_as_definer TO iso_alice;

-- Test 6a: Alice calls SECURITY DEFINER function to query her own table
-- Expected: succeeds because the function runs as alice (caller), not superuser (definer)
SET SESSION AUTHORIZATION iso_alice;
CREATE TEMP TABLE _test_state_6a (instance_id TEXT);
INSERT INTO _test_state_6a
SELECT iso_submit_as_definer('SELECT value FROM iso_alice_data LIMIT 1');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    result TEXT;
    inst_submitted TEXT;
    inst_login TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_6a;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6a - SECURITY DEFINER caller access): expected completed, got %', final_status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result IS NULL OR result NOT LIKE '%alice secret%' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6a): expected alice secret, got %', result;
    END IF;

    -- Verify identity columns show alice (caller), not superuser (definer)
    SELECT submitted_by::text, login_role::text INTO inst_submitted, inst_login
      FROM df.instances WHERE id = inst_id;

    IF inst_submitted != 'iso_alice' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6a): expected submitted_by=iso_alice (caller), got % (would be superuser if definer was captured)', inst_submitted;
    END IF;
    IF inst_login != 'iso_alice' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6a): expected login_role=iso_alice, got %', inst_login;
    END IF;

    RAISE NOTICE 'Test 6a PASSED: SECURITY DEFINER captures caller (alice), not definer (superuser)';
END $$;

DROP TABLE _test_state_6a;

-- Test 6b: Alice calls SECURITY DEFINER function to query superuser table
-- Expected: FAILS because the function runs as alice (caller), not superuser (definer)
-- This proves GetOuterUserId() captured the caller's identity correctly
SET SESSION AUTHORIZATION iso_alice;
CREATE TEMP TABLE _test_state_6b (instance_id TEXT);
INSERT INTO _test_state_6b
SELECT iso_submit_as_definer('SELECT value FROM iso_superuser_secrets LIMIT 1');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_6b;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6b - SECURITY DEFINER unauthorized): expected failed, got % (if completed, function incorrectly ran as definer instead of caller)', final_status;
    END IF;

    RAISE NOTICE 'Test 6b PASSED: SECURITY DEFINER function runs as caller, cannot access superuser table';
END $$;

DROP TABLE _test_state_6b;

-- Cleanup Test 6 resources
DROP FUNCTION IF EXISTS iso_submit_as_definer(TEXT);
DROP TABLE IF EXISTS iso_superuser_secrets CASCADE;

-- ============================================================================
-- Cleanup
-- ============================================================================
DROP TABLE IF EXISTS iso_alice_data CASCADE;
DROP TABLE IF EXISTS iso_bob_data CASCADE;
DROP TABLE IF EXISTS iso_analyst_data CASCADE;

REVOKE iso_analysts FROM iso_alice;

DO $cleanup$
BEGIN
    BEGIN DROP OWNED BY iso_analysts; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY iso_alice;    EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY iso_bob;      EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_analysts;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_alice;        EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_bob;          EXCEPTION WHEN undefined_object THEN NULL; END;
END $cleanup$;

SELECT 'TEST PASSED' AS result;
