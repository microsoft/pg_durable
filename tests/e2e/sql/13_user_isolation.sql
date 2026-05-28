-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 26_superuser_scenarios, 27_user_isolation
-- Tests: superuser durable SQL (pg_authid access), per-user table isolation,
--        NOLOGIN group role rejection, SECURITY DEFINER semantics, dropped role handling
-- Runs as postgres throughout (creates/drops roles and user-owned tables)

-- === Test: 26_superuser_scenarios ===

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state
SELECT df.start(
    df.sql('SELECT (SELECT rolname FROM pg_authid LIMIT 1) AS any_role'),
    'test-superuser-pg_authid'
);

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
    IF result NOT LIKE '%any_role%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected result to contain any_role, got %', result;
    END IF;

    RAISE NOTICE 'TEST PASSED: superuser durable sql (pg_authid)';
END $$;

DROP TABLE _test_state;

-- === Test: 27_user_isolation ===

-- Setup: Create two test users with separate tables
DO $setup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename IN ('iso_alice', 'iso_bob')
        AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY iso_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY iso_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

CREATE ROLE iso_alice LOGIN;
CREATE ROLE iso_bob   LOGIN;

SELECT df.grant_usage('iso_alice');
SELECT df.grant_usage('iso_bob');

GRANT TEMPORARY ON DATABASE postgres TO iso_alice, iso_bob;

CREATE TABLE IF NOT EXISTS iso_alice_data (id SERIAL PRIMARY KEY, value TEXT);
ALTER TABLE iso_alice_data OWNER TO iso_alice;
INSERT INTO iso_alice_data (value) VALUES ('alice secret') ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS iso_bob_data (id SERIAL PRIMARY KEY, value TEXT);
ALTER TABLE iso_bob_data OWNER TO iso_bob;
INSERT INTO iso_bob_data (value) VALUES ('bob secret') ON CONFLICT DO NOTHING;

-- Test 1: Alice can access her own table via durable function
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

-- Test 2: Alice CANNOT access Bob's table via durable function
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

-- Test 3: Bob can access his own table via durable function
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

-- Test 4: Bob CANNOT access Alice's table via durable function
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

-- Test 5: SET ROLE with a NOLOGIN group role → df.start() rejects
DO $group_setup$
BEGIN
    BEGIN DROP OWNED BY iso_analysts; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_analysts;     EXCEPTION WHEN undefined_object THEN NULL; END;
END $group_setup$;

CREATE ROLE iso_analysts NOLOGIN;
CREATE TABLE IF NOT EXISTS iso_analyst_data (id SERIAL PRIMARY KEY, value TEXT);
ALTER TABLE iso_analyst_data OWNER TO iso_analysts;
INSERT INTO iso_analyst_data (value) VALUES ('analyst report') ON CONFLICT DO NOTHING;

GRANT iso_analysts TO iso_alice;
SELECT df.grant_usage('iso_analysts');
GRANT TEMPORARY ON DATABASE postgres TO iso_analysts;

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

    SELECT submitted_by::text INTO inst_submitted
      FROM df.instances WHERE id = inst_id;

    IF inst_submitted != 'iso_analysts' THEN
        RAISE EXCEPTION 'TEST FAILED (Test 5b): expected submitted_by=iso_analysts, got %', inst_submitted;
    END IF;

    RAISE NOTICE 'Test 5b PASSED: SET ROLE with LOGIN group role works (submitted_by=iso_analysts)';
END $$;

DROP TABLE _test_state_5b;

ALTER ROLE iso_analysts NOLOGIN;

-- Test 6: SECURITY DEFINER function - captures definer identity
CREATE TABLE IF NOT EXISTS iso_superuser_secrets (id SERIAL PRIMARY KEY, value TEXT);
INSERT INTO iso_superuser_secrets (value) VALUES ('classified') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION iso_submit_as_definer(q TEXT) RETURNS TEXT
LANGUAGE SQL SECURITY DEFINER
AS $$
    SELECT df.start(df.sql(q), 'secdef-test');
$$;

GRANT EXECUTE ON FUNCTION iso_submit_as_definer TO iso_alice;

-- Test 6a: Alice calls SECURITY DEFINER to query her own table
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

DROP FUNCTION IF EXISTS iso_submit_as_definer(TEXT);
DROP TABLE IF EXISTS iso_superuser_secrets CASCADE;

-- Test 7: Dropped role during execution
DO $test7_setup$
BEGIN
    BEGIN DROP OWNED BY iso_ephemeral; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE iso_ephemeral;     EXCEPTION WHEN undefined_object THEN NULL; END;
END $test7_setup$;

CREATE ROLE iso_ephemeral LOGIN;
SELECT df.grant_usage('iso_ephemeral');
GRANT TEMPORARY ON DATABASE postgres TO iso_ephemeral;

DROP TABLE IF EXISTS _test_state_7_persistent;
CREATE TABLE _test_state_7_persistent (instance_id TEXT);
GRANT INSERT ON _test_state_7_persistent TO iso_ephemeral;

SET SESSION AUTHORIZATION iso_ephemeral;
INSERT INTO _test_state_7_persistent SELECT df.start(df.sleep(3) ~> df.sql('SELECT 1'), 'ephemeral-test');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    attempts INT := 0;
    node_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_7_persistent;
    
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
    
    DROP OWNED BY iso_ephemeral;
    DROP ROLE iso_ephemeral;
    
    RAISE NOTICE 'Test 7: Dropped role iso_ephemeral, SQL node should fail when it tries to execute';
END $$;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_7_persistent;
    
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
    
    RAISE NOTICE 'Test 7 PASSED: Dropped role causes clear failure (status=failed)';
END $$;

DROP TABLE _test_state_7_persistent;

-- Cleanup
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
