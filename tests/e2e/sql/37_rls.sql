-- Test: Row-Level Security (RLS)
--
-- Validates that RLS policies on df.instances and df.nodes enforce
-- per-user isolation at the table level. Tests:
-- 1. User can see only own instances
-- 2. User cannot see another user's nodes
-- 3. User cannot cancel another user's instance
-- 4. User cannot signal another user's instance
-- 5. Monitoring functions respect RLS (list_instances, instance_info)
-- 6. Superuser can see all instances (RLS bypass)
--
-- Must run as SUPERUSER because it uses SET SESSION AUTHORIZATION.

-- ============================================================================
-- Setup: Create two test users
-- ============================================================================
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

-- Only grant TEMPORARY for temp tables; df permissions are auto-granted to PUBLIC
GRANT TEMPORARY ON DATABASE postgres TO rls_alice, rls_bob;

-- ============================================================================
-- Submit instances as each user
-- ============================================================================

-- Alice submits a job
SET SESSION AUTHORIZATION rls_alice;
CREATE TEMP TABLE _rls_alice_state (instance_id TEXT);
INSERT INTO _rls_alice_state SELECT df.start(df.sql('SELECT 1 AS alice_result'), 'rls-alice-job');
RESET SESSION AUTHORIZATION;

-- Bob submits a job
SET SESSION AUTHORIZATION rls_bob;
CREATE TEMP TABLE _rls_bob_state (instance_id TEXT);
INSERT INTO _rls_bob_state SELECT df.start(df.sql('SELECT 2 AS bob_result'), 'rls-bob-job');
RESET SESSION AUTHORIZATION;

-- Wait for both to complete
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

-- ============================================================================
-- Test 1: User can only see own instances
-- ============================================================================
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
    found_label TEXT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    -- As Alice: should see only her instance
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

    -- As Bob: should see only his instance
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

-- ============================================================================
-- Test 2: User cannot see another user's nodes
-- ============================================================================
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    -- As Alice: should not see Bob's nodes
    SET SESSION AUTHORIZATION rls_alice;

    SELECT count(*) INTO cnt FROM df.nodes WHERE instance_id = bob_id;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Alice can see Bob''s nodes (count=%, expected 0)', cnt;
    END IF;

    -- Alice should see her own nodes
    SELECT count(*) INTO cnt FROM df.nodes WHERE instance_id = alice_id;
    IF cnt < 1 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Alice cannot see her own nodes (count=%, expected >= 1)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    -- As Bob: should not see Alice's nodes
    SET SESSION AUTHORIZATION rls_bob;

    SELECT count(*) INTO cnt FROM df.nodes WHERE instance_id = alice_id;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Bob can see Alice''s nodes (count=%, expected 0)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 2 PASSED: Users cannot see other users'' nodes';
END $$;

-- ============================================================================
-- Test 3: User cannot cancel another user's instance
-- ============================================================================

-- Submit a long-running job as Alice for Bob to attempt to cancel
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

    -- As Bob: try to cancel Alice's instance (should fail)
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

    -- Superuser cleans up by cancelling the job
    PERFORM df.cancel(alice_cancel_id);
END $$;

DROP TABLE _rls_cancel_state;

-- ============================================================================
-- Test 4: User cannot signal another user's instance
-- ============================================================================
DO $$
DECLARE
    alice_id TEXT;
    err_msg TEXT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;

    -- As Bob: try to signal Alice's instance (should fail)
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

-- ============================================================================
-- Test 5: Monitoring functions respect RLS
-- ============================================================================
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    -- As Alice: list_instances should only show Alice's instances
    SET SESSION AUTHORIZATION rls_alice;

    SELECT count(*) INTO cnt FROM df.list_instances();
    IF cnt < 1 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Alice sees no instances from list_instances';
    END IF;

    -- Verify Bob's instance is not in the listing
    SELECT count(*) INTO cnt FROM df.list_instances() li WHERE li.instance_id = bob_id;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Alice can see Bob''s instance in list_instances';
    END IF;

    -- instance_info should return empty for Bob's instance
    SELECT count(*) INTO cnt FROM df.instance_info(bob_id);
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Alice can see Bob''s instance_info';
    END IF;

    -- instance_info should work for Alice's own instance
    SELECT count(*) INTO cnt FROM df.instance_info(alice_id);
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Alice cannot see her own instance_info (count=%)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 5 PASSED: Monitoring functions respect RLS';
END $$;

-- ============================================================================
-- Test 6: Superuser can see all instances (RLS bypassed)
-- ============================================================================
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    -- Superuser should see both
    SELECT count(*) INTO cnt FROM df.instances WHERE id IN (alice_id, bob_id);
    IF cnt != 2 THEN
        RAISE EXCEPTION 'TEST 6 FAILED: Superuser cannot see both instances (count=%, expected 2)', cnt;
    END IF;

    RAISE NOTICE 'Test 6 PASSED: Superuser can see all instances';
END $$;

-- ============================================================================
-- Test 7: User can UPDATE allowed columns (status, updated_at) on own rows
-- ============================================================================
DO $$
DECLARE
    alice_id TEXT;
    bob_id TEXT;
    cnt INT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;
    SELECT instance_id INTO bob_id FROM _rls_bob_state;

    SET SESSION AUTHORIZATION rls_alice;

    -- Alice can update status on her own instance (column-level grant)
    UPDATE df.instances SET status = 'completed', updated_at = now() WHERE id = alice_id;
    GET DIAGNOSTICS cnt = ROW_COUNT;
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST 7 FAILED: Alice could not UPDATE status on her own instance (rows=%)', cnt;
    END IF;

    -- Alice cannot update status on Bob's instance (RLS blocks it)
    UPDATE df.instances SET status = 'cancelled' WHERE id = bob_id;
    GET DIAGNOSTICS cnt = ROW_COUNT;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST 7 FAILED: Alice was able to UPDATE Bob''s instance (rows=%)', cnt;
    END IF;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 7 PASSED: Column-level UPDATE on status works, RLS enforced';
END $$;

-- ============================================================================
-- Test 8: User cannot DELETE instances (no DELETE grant)
-- ============================================================================
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

-- ============================================================================
-- Test 9: User cannot UPDATE identity columns (submitted_by, login_role)
-- ============================================================================
DO $$
DECLARE
    alice_id TEXT;
BEGIN
    SELECT instance_id INTO alice_id FROM _rls_alice_state;

    SET SESSION AUTHORIZATION rls_alice;

    -- login_role is not in the column-level UPDATE grant
    BEGIN
        UPDATE df.instances SET login_role = 'postgres'::regrole WHERE id = alice_id;
        RAISE EXCEPTION 'TEST 9 FAILED: Alice was able to tamper with login_role';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL; -- expected
    END;

    -- submitted_by is not in the column-level UPDATE grant
    BEGIN
        UPDATE df.instances SET submitted_by = 'postgres'::regrole WHERE id = alice_id;
        RAISE EXCEPTION 'TEST 9 FAILED: Alice was able to tamper with submitted_by';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL; -- expected
    END;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 9 PASSED: Cannot UPDATE identity columns (column-level grant restricts)';
END $$;

-- ============================================================================
-- Test 10: User cannot INSERT runtime-owned columns directly
-- ============================================================================
DO $$
BEGIN
    SET SESSION AUTHORIZATION rls_alice;

    BEGIN
        INSERT INTO df.instances (id, root_node, status, submitted_by, login_role)
        VALUES ('deadbeef', 'cafebabe', 'completed', current_user::regrole, session_user::regrole);
        RAISE EXCEPTION 'TEST 10 FAILED: Alice was able to INSERT status into df.instances';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL; -- expected
    END;

    BEGIN
        INSERT INTO df.nodes (id, instance_id, node_type, query, status, submitted_by, login_role)
        VALUES ('deadbeef', 'cafebabe', 'SQL', 'SELECT 1', 'completed', current_user::regrole, session_user::regrole);
        RAISE EXCEPTION 'TEST 10 FAILED: Alice was able to INSERT status into df.nodes';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL; -- expected
    END;

    BEGIN
        INSERT INTO df.instances (id, root_node, submitted_by, login_role)
        VALUES ('deadbeef', 'cafebabe', current_user::regrole, 'postgres'::regrole);
        RAISE EXCEPTION 'TEST 10 FAILED: Alice was able to spoof login_role on df.instances';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL; -- expected
    END;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 10 PASSED: INSERT is limited to df.start()-shaped columns';
END $$;

-- ============================================================================
-- Test 11: Direct INSERT still respects shape constraints
-- ============================================================================
DO $$
BEGIN
    SET SESSION AUTHORIZATION rls_alice;

    BEGIN
        INSERT INTO df.instances (id, root_node, submitted_by, login_role)
        VALUES ('not_hex!', 'cafebabe', current_user::regrole, session_user::regrole);
        RAISE EXCEPTION 'TEST 11 FAILED: Alice was able to INSERT malformed instance metadata';
    EXCEPTION
        WHEN check_violation THEN
            NULL; -- expected
    END;

    BEGIN
        INSERT INTO df.nodes (id, instance_id, node_type, query, result_name, submitted_by, login_role)
        VALUES ('deadbeef', 'cafebabe', 'SQL', 'SELECT 1', 'bad-name', current_user::regrole, session_user::regrole);
        RAISE EXCEPTION 'TEST 11 FAILED: Alice was able to INSERT malformed node metadata';
    EXCEPTION
        WHEN check_violation THEN
            NULL; -- expected
    END;

    RESET SESSION AUTHORIZATION;

    RAISE NOTICE 'Test 11 PASSED: Direct INSERT must satisfy metadata shape constraints';
END $$;

-- ============================================================================
-- Cleanup
-- ============================================================================
DROP TABLE IF EXISTS _rls_alice_state;
DROP TABLE IF EXISTS _rls_bob_state;

DO $cleanup$
BEGIN
    BEGIN DROP OWNED BY rls_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY rls_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE rls_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE rls_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $cleanup$;

SELECT 'TEST PASSED' AS result;
