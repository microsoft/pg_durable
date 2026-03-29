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

-- df schema, functions, and table DML are auto-granted to PUBLIC by CREATE EXTENSION.
-- Only grant non-auto privileges needed by these tests.
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
-- Test 5: SET ROLE with a NOLOGIN group role → df.start() rejects
-- ============================================================================
-- In the simplified model, current_user must have LOGIN. After SET ROLE to
-- a NOLOGIN group role, current_user = that group role, which lacks LOGIN.
-- df.start() should raise an immediate error.
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
-- df schema, functions, and table DML are auto-granted to PUBLIC by CREATE EXTENSION.
GRANT TEMPORARY ON DATABASE postgres TO iso_analysts;

-- Test 5a: SET ROLE to NOLOGIN role → df.start() should error
SET SESSION AUTHORIZATION iso_alice;
SET ROLE iso_analysts;
DO $$
BEGIN
    PERFORM df.start(df.sql('SELECT value FROM iso_analyst_data LIMIT 1'), 'iso-set-role-nologin');
    RAISE EXCEPTION 'TEST FAILED (Test 5a): df.start() should have rejected NOLOGIN role';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%LOGIN%' THEN
            RAISE NOTICE 'Test 5a PASSED: df.start() rejects NOLOGIN group role with LOGIN error';
        ELSE
            RAISE EXCEPTION 'TEST FAILED (Test 5a): unexpected error: %', SQLERRM;
        END IF;
END $$;
RESET ROLE;
RESET SESSION AUTHORIZATION;

-- Test 5b: Grant LOGIN to group role → df.start() should succeed
ALTER ROLE iso_analysts LOGIN;

SET SESSION AUTHORIZATION iso_alice;
SET ROLE iso_analysts;
CREATE TEMP TABLE _test_state_5b (instance_id TEXT);
INSERT INTO _test_state_5b
SELECT df.start(df.sql('SELECT value FROM iso_analyst_data LIMIT 1'), 'iso-set-role-login');
RESET ROLE;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    result TEXT;
    inst_submitted TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_5b;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 5b - SET ROLE with LOGIN): expected completed, got %', final_status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result IS NULL OR result NOT LIKE '%analyst report%' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 5b): expected analyst report, got %', result;
    END IF;

    -- Verify identity column on the instance
    SELECT submitted_by::text INTO inst_submitted
      FROM df.instances WHERE id = inst_id;

    IF inst_submitted != 'iso_analysts' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 5b): expected submitted_by=iso_analysts, got %', inst_submitted;
    END IF;

    RAISE NOTICE 'Test 5b PASSED: SET ROLE with LOGIN group role works (submitted_by=iso_analysts)';
END $$;

DROP TABLE _test_state_5b;

-- Revert LOGIN for cleanup
ALTER ROLE iso_analysts NOLOGIN;

-- ============================================================================
-- Test 6: SECURITY DEFINER function - captures definer identity
-- ============================================================================
-- In the simplified model, GetUserId() captures current_user, which inside
-- a SECURITY DEFINER function is the function *owner* (definer), not the
-- caller. SQL therefore runs with definer privileges.

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

-- Test 6a: Alice calls SECURITY DEFINER to query her own table
-- Expected: succeeds because function runs as superuser (definer), who can access all tables
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
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_6a;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6a - SECURITY DEFINER access alice table): expected completed, got %', final_status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result IS NULL OR result NOT LIKE '%alice secret%' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6a): expected alice secret, got %', result;
    END IF;

    RAISE NOTICE 'Test 6a PASSED: SECURITY DEFINER runs as definer, can access alice table';
END $$;

DROP TABLE _test_state_6a;

-- Test 6b: Alice calls SECURITY DEFINER to query superuser-only table
-- Expected: SUCCEEDS because function runs as superuser (definer)
-- This is the correct behavior in the simplified model.
SET SESSION AUTHORIZATION iso_alice;
CREATE TEMP TABLE _test_state_6b (instance_id TEXT);
INSERT INTO _test_state_6b
SELECT iso_submit_as_definer('SELECT value FROM iso_superuser_secrets LIMIT 1');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_6b;

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6b - SECURITY DEFINER access superuser table): expected completed (runs as definer), got %', final_status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result IS NULL OR result NOT LIKE '%classified%' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 6b): expected classified, got %', result;
    END IF;

    RAISE NOTICE 'Test 6b PASSED: SECURITY DEFINER runs as definer, CAN access superuser table (expected in simplified model)';
END $$;

DROP TABLE _test_state_6b;

-- Cleanup Test 6 resources
DROP FUNCTION IF EXISTS iso_submit_as_definer(TEXT);
DROP TABLE IF EXISTS iso_superuser_secrets CASCADE;

-- ============================================================================
-- Test 7: Dropped role during execution
-- ============================================================================
-- This verifies that clear error messages are produced when the submitting
-- role is dropped between node executions in a multi-step function.

-- Create ephemeral user and table
DO $test7_setup$
BEGIN
    BEGIN DROP OWNED BY iso_ephemeral; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_ephemeral;     EXCEPTION WHEN undefined_object THEN NULL; END;
END $test7_setup$;

CREATE ROLE iso_ephemeral LOGIN;
-- df schema, functions, and table DML are auto-granted to PUBLIC by CREATE EXTENSION.
GRANT TEMPORARY ON DATABASE postgres TO iso_ephemeral;

-- Submit a sequence: df.sleep(3) followed by df.sql('SELECT 1')
-- We'll drop the role after the sleep starts but before the SQL executes.
-- This tests the realistic scenario: role dropped between nodes in a multi-node graph.

-- Use a regular table (not temp) so we can access it after session switch
DROP TABLE IF EXISTS _test_state_7_persistent;
CREATE TABLE _test_state_7_persistent (instance_id TEXT);
GRANT INSERT ON _test_state_7_persistent TO iso_ephemeral;

SET SESSION AUTHORIZATION iso_ephemeral;
INSERT INTO _test_state_7_persistent SELECT df.start(df.sleep(3) ~> df.sql('SELECT 1'), 'ephemeral-test');
RESET SESSION AUTHORIZATION;

-- Wait for the sleep node to start, then drop the role
DO $$
DECLARE
    inst_id TEXT;
    attempts INT := 0;
    node_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_7_persistent;
    
    -- Wait until at least one node has started (status != 'pending')
    LOOP
        SELECT COUNT(*) INTO node_count
          FROM df.nodes
          WHERE instance_id = inst_id
            AND status != 'pending'
            AND status IS NOT NULL;
        EXIT WHEN node_count > 0 OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF node_count = 0 THEN
        RAISE EXCEPTION 'TEST SETUP FAILED (Test 7): sleep node never started';
    END IF;
    
    RAISE NOTICE 'Test 7: Sleep node started, now dropping role iso_ephemeral';
    
    -- Drop the user and their objects (no need to terminate backends)
    DROP OWNED BY iso_ephemeral;
    DROP ROLE iso_ephemeral;
    
    RAISE NOTICE 'Test 7: Dropped role iso_ephemeral, SQL node should fail when it tries to execute';
END $$;

-- Wait for execution and verify it fails with clear error
DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_7_persistent;
    
    -- Wait for the instance to complete (should fail when trying to execute SQL node)
    LOOP
        SELECT status INTO final_status FROM df.instances WHERE id = inst_id;
        EXIT WHEN lower(final_status) IN ('failed', 'completed') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF final_status IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED (Test 7 - dropped role): instance not found';
    END IF;
    
    IF lower(final_status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 7 - dropped role): expected failed, got %', final_status;
    END IF;
    
    -- The error should mention connection failure for the dropped role
    -- We're not checking the exact error text since it comes from libpq/sqlx,
    -- but we verified the instance transitioned to failed status
    
    RAISE NOTICE 'Test 7 PASSED: Dropped role causes clear failure (status=failed)';
END $$;

DROP TABLE _test_state_7_persistent;

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
