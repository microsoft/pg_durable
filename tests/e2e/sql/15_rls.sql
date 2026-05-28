-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 37_rls, 38_rls_vars
-- Tests: RLS enforcement on df.instances and df.nodes (per-user isolation),
--        cross-user cancel/signal blocked, monitoring functions respect RLS,
--        RLS on df.vars (per-user variable isolation), df.clearvars/unsetvar scoping
-- Runs as postgres throughout (creates/drops roles and uses SET SESSION AUTHORIZATION)

-- === Test: 37_rls ===

-- Setup: Create two test users
DO $setup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename IN ('rls_alice', 'rls_bob')
        AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY rls_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY rls_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE rls_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE rls_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

CREATE ROLE rls_alice LOGIN;
CREATE ROLE rls_bob   LOGIN;

SELECT df.grant_usage('rls_alice');
SELECT df.grant_usage('rls_bob');

GRANT TEMPORARY ON DATABASE postgres TO rls_alice, rls_bob;

-- Submit instances as each user
SET SESSION AUTHORIZATION rls_alice;
CREATE TEMP TABLE _rls_alice_state (instance_id TEXT);
INSERT INTO _rls_alice_state SELECT df.start(df.sql('SELECT 1 AS alice_result'), 'rls-alice-job');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION rls_bob;
CREATE TEMP TABLE _rls_bob_state (instance_id TEXT);
INSERT INTO _rls_bob_state SELECT df.start(df.sql('SELECT 2 AS bob_result'), 'rls-bob-job');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    s TEXT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    SELECT df.wait_for_completion(alice_id, 30) INTO s;
    IF s != 'completed' THEN
        RAISE EXCEPTION 'Setup failed: Alice job status = %', s;
    END IF;

    SELECT df.wait_for_completion(bob_id, 30) INTO s;
    IF s != 'completed' THEN
        RAISE EXCEPTION 'Setup failed: Bob job status = %', s;
    END IF;
END $$;

-- Test 1: User can only see own instances
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    SET SESSION AUTHORIZATION rls_alice;

    SELECT count(*) INTO cnt FROM df.instances WHERE id = alice_id;
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Alice cannot see her own instance (count=%, expected 1)', cnt;
    END IF;

    SELECT count(*) INTO cnt FROM df.instances WHERE id = bob_id;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Alice can see Bob''s instance (count=%, expected 0)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    SET SESSION AUTHORIZATION rls_bob;

    SELECT count(*) INTO cnt FROM df.instances WHERE id = bob_id;
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Bob cannot see his own instance (count=%, expected 1)', cnt;
    END IF;

    SELECT count(*) INTO cnt FROM df.instances WHERE id = alice_id;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Bob can see Alice''s instance (count=%, expected 0)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 1 PASSED: Users can only see own instances';
END $$;

-- Test 2: User cannot see another user's nodes
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    SET SESSION AUTHORIZATION rls_alice;

    SELECT count(*) INTO cnt FROM df.nodes WHERE instance_id = bob_id;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Alice can see Bob''s nodes (count=%, expected 0)', cnt;
    END IF;

    SELECT count(*) INTO cnt FROM df.nodes WHERE instance_id = alice_id;
    IF cnt < 1 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Alice cannot see her own nodes (count=%, expected >= 1)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    SET SESSION AUTHORIZATION rls_bob;

    SELECT count(*) INTO cnt FROM df.nodes WHERE instance_id = alice_id;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Bob can see Alice''s nodes (count=%, expected 0)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 2 PASSED: Users cannot see other users'' nodes';
END $$;

-- Test 3: User cannot cancel another user's instance
SET SESSION AUTHORIZATION rls_alice;
CREATE TEMP TABLE _rls_cancel_state (instance_id TEXT);
INSERT INTO _rls_cancel_state SELECT df.start(df.sql('SELECT pg_sleep(30)'), 'rls-cancel-target');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    alice_cancel_id TEXT;
    err_msg TEXT;
BEGIN
    SELECT instance_id INTO alice_cancel_id FROM _rls_cancel_state;

    SET SESSION AUTHORIZATION rls_bob;

    BEGIN
        PERFORM df.cancel(alice_cancel_id);
        RAISE EXCEPTION 'TEST 3 FAILED: Bob was able to cancel Alice''s instance';
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS err_msg = MESSAGE_TEXT;
            IF err_msg LIKE '%not found or access denied%' THEN
                RAISE NOTICE 'Test 3 PASSED: Bob cannot cancel Alice''s instance';
            ELSE
                RAISE EXCEPTION 'TEST 3 FAILED: Unexpected error: %', err_msg;
            END IF;
    END;

    RESET SESSION AUTHORIZATION;

    PERFORM df.cancel(alice_cancel_id);
END $$;

DROP TABLE _rls_cancel_state;

-- Test 4: User cannot signal another user's instance
DO $$
DECLARE
    alice_id TEXT;
    err_msg TEXT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;

    SET SESSION AUTHORIZATION rls_bob;

    BEGIN
        PERFORM df.signal(alice_id, 'test-signal', '{}');
        RAISE EXCEPTION 'TEST 4 FAILED: Bob was able to signal Alice''s instance';
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS err_msg = MESSAGE_TEXT;
            IF err_msg LIKE '%not found or access denied%' THEN
                RAISE NOTICE 'Test 4 PASSED: Bob cannot signal Alice''s instance';
            ELSE
                RAISE EXCEPTION 'TEST 4 FAILED: Unexpected error: %', err_msg;
            END IF;
    END;

    RESET SESSION AUTHORIZATION;
END $$;

-- Test 5: Monitoring functions respect RLS
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    SET SESSION AUTHORIZATION rls_alice;

    SELECT count(*) INTO cnt FROM df.list_instances();
    IF cnt < 1 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Alice sees no instances from list_instances';
    END IF;

    SELECT count(*) INTO cnt FROM df.list_instances() li WHERE li.instance_id = bob_id;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Alice can see Bob''s instance in list_instances';
    END IF;

    SELECT count(*) INTO cnt FROM df.instance_info(bob_id);
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Alice can see Bob''s instance_info';
    END IF;

    SELECT count(*) INTO cnt FROM df.instance_info(alice_id);
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Alice cannot see her own instance_info (count=%)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 5 PASSED: Monitoring functions respect RLS';
END $$;

-- Test 6: Superuser can see all instances (RLS bypassed)
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    SELECT count(*) INTO cnt FROM df.instances WHERE id IN (alice_id, bob_id);
    IF cnt != 2 THEN
        RAISE EXCEPTION 'TEST 6 FAILED: Superuser cannot see both instances (count=%, expected 2)', cnt;
    END IF;

    RAISE NOTICE 'Test 6 PASSED: Superuser can see all instances';
END $$;

-- Test 7: User can UPDATE allowed columns on own rows
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    SET SESSION AUTHORIZATION rls_alice;

    UPDATE df.instances SET status = 'completed', updated_at = now() WHERE id = alice_id;
    GET DIAGNOSTICS cnt = ROW_COUNT;
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST 7 FAILED: Alice could not UPDATE status on her own instance (rows=%)', cnt;
    END IF;

    UPDATE df.instances SET status = 'cancelled' WHERE id = bob_id;
    GET DIAGNOSTICS cnt = ROW_COUNT;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 7 FAILED: Alice was able to UPDATE Bob''s instance (rows=%)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 7 PASSED: Column-level UPDATE on status works, RLS enforced';
END $$;

-- Test 8: User cannot DELETE instances
DO $$
DECLARE
    alice_id TEXT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;

    SET SESSION AUTHORIZATION rls_alice;

    BEGIN
        DELETE FROM df.instances WHERE id = alice_id;
        RAISE EXCEPTION 'TEST 8 FAILED: Alice was able to DELETE her own instance';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'Test 8 PASSED: DELETE on df.instances denied (no DELETE grant)';
    END;

    RESET SESSION AUTHORIZATION;
END $$;

-- Test 9: User cannot UPDATE identity columns
DO $$
DECLARE
    alice_id TEXT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;

    SET SESSION AUTHORIZATION rls_alice;

    BEGIN
        UPDATE df.instances SET submitted_by = 'postgres'::regrole WHERE id = alice_id;
        RAISE EXCEPTION 'TEST 9 FAILED: Alice was able to tamper with submitted_by';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 9 PASSED: Cannot UPDATE identity columns (column-level grant restricts)';
END $$;

-- Test 10: User cannot INSERT runtime-owned columns directly
DO $$
BEGIN
    SET SESSION AUTHORIZATION rls_alice;

    BEGIN
        INSERT INTO df.instances (id, root_node, status, submitted_by)
        VALUES ('deadbeef', 'cafebabe', 'completed', current_user::regrole);
        RAISE EXCEPTION 'TEST 10 FAILED: Alice was able to INSERT status into df.instances';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;

    BEGIN
        INSERT INTO df.nodes (id, instance_id, node_type, query, status, submitted_by)
        VALUES ('deadbeef', 'cafebabe', 'SQL', 'SELECT 1', 'completed', current_user::regrole);
        RAISE EXCEPTION 'TEST 10 FAILED: Alice was able to INSERT status into df.nodes';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 10 PASSED: INSERT is limited to df.start()-shaped columns';
END $$;

-- Test 11: Direct INSERT still respects shape constraints
DO $$
BEGIN
    SET SESSION AUTHORIZATION rls_alice;

    BEGIN
        INSERT INTO df.instances (id, root_node, submitted_by)
        VALUES ('not_hex!', 'cafebabe', current_user::regrole);
        RAISE EXCEPTION 'TEST 11 FAILED: Alice was able to INSERT malformed instance metadata';
    EXCEPTION
        WHEN check_violation THEN
            NULL;
    END;

    BEGIN
        INSERT INTO df.nodes (id, instance_id, node_type, query, result_name, submitted_by)
        VALUES ('deadbeef', 'cafebabe', 'SQL', 'SELECT 1', 'bad-name', current_user::regrole);
        RAISE EXCEPTION 'TEST 11 FAILED: Alice was able to INSERT malformed node metadata';
    EXCEPTION
        WHEN check_violation THEN
            NULL;
    END;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 11 PASSED: Direct INSERT must satisfy metadata shape constraints';
END $$;

-- Cleanup 37_rls
DROP TABLE IF EXISTS _rls_alice_state;
DROP TABLE IF EXISTS _rls_bob_state;

DO $cleanup_rls$
BEGIN
    BEGIN DROP OWNED BY rls_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY rls_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE rls_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE rls_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $cleanup_rls$;

-- === Test: 38_rls_vars ===

-- Setup: Create two test users
DO $setup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename IN ('vars_alice', 'vars_bob')
        AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY vars_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY vars_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE vars_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE vars_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

CREATE ROLE vars_alice LOGIN;
CREATE ROLE vars_bob   LOGIN;

SELECT df.grant_usage('vars_alice');
SELECT df.grant_usage('vars_bob');

GRANT TEMPORARY ON DATABASE postgres TO vars_alice, vars_bob;

DROP TABLE IF EXISTS vars_test_results;
CREATE TABLE vars_test_results (id SERIAL PRIMARY KEY, username TEXT, msg TEXT);
GRANT SELECT, INSERT ON vars_test_results TO PUBLIC;
GRANT USAGE ON SEQUENCE vars_test_results_id_seq TO PUBLIC;

-- Test 1: Per-user variable isolation via direct table access
SET SESSION AUTHORIZATION vars_alice;
SELECT df.setvar('color', 'red');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION vars_bob;
SELECT df.setvar('color', 'blue');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    alice_val TEXT;
    bob_val TEXT;
    alice_count INT;
    bob_count INT;
BEGIN
    SET SESSION AUTHORIZATION vars_alice;
    SELECT df.getvar('color') INTO alice_val;
    SELECT count(*) INTO alice_count FROM df.vars;
    RESET SESSION AUTHORIZATION;

    SET SESSION AUTHORIZATION vars_bob;
    SELECT df.getvar('color') INTO bob_val;
    SELECT count(*) INTO bob_count FROM df.vars;
    RESET SESSION AUTHORIZATION;

    IF alice_val != 'red' THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Alice expected "red", got "%"', alice_val;
    END IF;

    IF bob_val != 'blue' THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Bob expected "blue", got "%"', bob_val;
    END IF;

    IF alice_count != 1 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Alice should see 1 var, saw %', alice_count;
    END IF;

    IF bob_count != 1 THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Bob should see 1 var, saw %', bob_count;
    END IF;

    RAISE NOTICE 'Test 1 PASSED: Per-user variable isolation (same key, different values)';
END $$;

-- Test 2: df.start() captures only the calling user's variables
SET SESSION AUTHORIZATION vars_alice;
CREATE TEMP TABLE _vars_alice_state (instance_id TEXT);
INSERT INTO _vars_alice_state SELECT df.start(
    'INSERT INTO vars_test_results (username, msg) VALUES (''alice'', ''{color}'')' ::text,
    'vars-alice-color'
);
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION vars_bob;
CREATE TEMP TABLE _vars_bob_state (instance_id TEXT);
INSERT INTO _vars_bob_state SELECT df.start(
    'INSERT INTO vars_test_results (username, msg) VALUES (''bob'', ''{color}'')' ::text,
    'vars-bob-color'
);
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    s TEXT;
BEGIN
    SELECT instance_id INTO alice_id FROM _vars_alice_state;
    SELECT instance_id INTO bob_id FROM _vars_bob_state;

    SELECT df.wait_for_completion(alice_id, 30) INTO s;
    IF s != 'completed' THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Alice workflow status = %', s;
    END IF;

    SELECT df.wait_for_completion(bob_id, 30) INTO s;
    IF s != 'completed' THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Bob workflow status = %', s;
    END IF;
END $$;

DO $$
DECLARE
    alice_msg TEXT;
    bob_msg TEXT;
BEGIN
    SELECT msg INTO alice_msg FROM vars_test_results WHERE username = 'alice' ORDER BY id DESC LIMIT 1;
    SELECT msg INTO bob_msg FROM vars_test_results WHERE username = 'bob' ORDER BY id DESC LIMIT 1;

    IF alice_msg != 'red' THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Alice workflow should have used "red", got "%"', alice_msg;
    END IF;

    IF bob_msg != 'blue' THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Bob workflow should have used "blue", got "%"', bob_msg;
    END IF;

    RAISE NOTICE 'Test 2 PASSED: df.start() captures only the calling user''s vars';
END $$;

-- Test 3: df.clearvars() only clears the calling user's variables
SET SESSION AUTHORIZATION vars_alice;
SELECT df.clearvars();
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    alice_val TEXT;
    bob_val TEXT;
BEGIN
    SET SESSION AUTHORIZATION vars_alice;
    SELECT df.getvar('color') INTO alice_val;
    RESET SESSION AUTHORIZATION;

    SET SESSION AUTHORIZATION vars_bob;
    SELECT df.getvar('color') INTO bob_val;
    RESET SESSION AUTHORIZATION;

    IF alice_val IS NOT NULL THEN
        RAISE EXCEPTION 'TEST 3 FAILED: Alice''s var should be gone after clearvars, got "%"', alice_val;
    END IF;

    IF bob_val != 'blue' THEN
        RAISE EXCEPTION 'TEST 3 FAILED: Bob''s var should survive Alice''s clearvars, got "%"', bob_val;
    END IF;

    RAISE NOTICE 'Test 3 PASSED: df.clearvars() only clears the calling user''s variables';
END $$;

-- Test 4: df.unsetvar() only removes the calling user's variable
SET SESSION AUTHORIZATION vars_alice;
SELECT df.setvar('shared_key', 'alice_value');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION vars_bob;
SELECT df.setvar('shared_key', 'bob_value');
SELECT df.unsetvar('shared_key');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    alice_val TEXT;
    bob_val TEXT;
BEGIN
    SET SESSION AUTHORIZATION vars_alice;
    SELECT df.getvar('shared_key') INTO alice_val;
    RESET SESSION AUTHORIZATION;

    SET SESSION AUTHORIZATION vars_bob;
    SELECT df.getvar('shared_key') INTO bob_val;
    RESET SESSION AUTHORIZATION;

    IF alice_val != 'alice_value' THEN
        RAISE EXCEPTION 'TEST 4 FAILED: Alice''s shared_key should survive Bob''s unsetvar, got "%"', alice_val;
    END IF;

    IF bob_val IS NOT NULL THEN
        RAISE EXCEPTION 'TEST 4 FAILED: Bob''s shared_key should be removed, got "%"', bob_val;
    END IF;

    RAISE NOTICE 'Test 4 PASSED: df.unsetvar() only removes the calling user''s variable';
END $$;

-- Test 5: Superuser sees all variables (RLS bypass) but df.start() captures only its own vars
SET SESSION AUTHORIZATION vars_bob;
SELECT df.clearvars();
RESET SESSION AUTHORIZATION;

SELECT df.setvar('su_var', 'superuser_value');

DO $$
DECLARE
    total_count INT;
BEGIN
    SELECT count(*) INTO total_count FROM df.vars;

    IF total_count != 2 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Superuser should see exactly 2 vars (alice + su), saw %', total_count;
    END IF;

    RAISE NOTICE 'Test 5 PASSED: Superuser sees all variables (% total)', total_count;
END $$;

TRUNCATE vars_test_results;

CREATE TEMP TABLE _vars_su_state (instance_id TEXT);
INSERT INTO _vars_su_state SELECT df.start(
    'INSERT INTO vars_test_results (username, msg) VALUES (''superuser'', ''{su_var}'')' ::text,
    'vars-su-test'
);

DO $$
DECLARE
    su_id TEXT;
    s TEXT;
    su_msg TEXT;
BEGIN
    SELECT instance_id INTO su_id FROM _vars_su_state;
    SELECT df.wait_for_completion(su_id, 30) INTO s;

    IF s != 'completed' THEN
        RAISE EXCEPTION 'TEST 5b FAILED: Superuser workflow status = %', s;
    END IF;

    SELECT msg INTO su_msg FROM vars_test_results WHERE username = 'superuser' ORDER BY id DESC LIMIT 1;

    IF su_msg != 'superuser_value' THEN
        RAISE EXCEPTION 'TEST 5b FAILED: Superuser workflow should use "superuser_value", got "%"', su_msg;
    END IF;

    RAISE NOTICE 'Test 5b PASSED: Superuser df.start() captures only its own vars';
END $$;

-- Cleanup
DROP TABLE IF EXISTS _vars_alice_state;
DROP TABLE IF EXISTS _vars_bob_state;
DROP TABLE IF EXISTS _vars_su_state;
DROP TABLE IF EXISTS vars_test_results;

DELETE FROM df.vars WHERE owner IN ('vars_alice'::regrole, 'vars_bob'::regrole);
SELECT df.clearvars();

DO $cleanup$
BEGIN
    BEGIN DROP OWNED BY vars_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY vars_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE vars_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE vars_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $cleanup$;

SELECT 'TEST PASSED' AS result;
