-- Test: Per-User Variable Isolation (RLS on df.vars)
--
-- Validates that df.vars is scoped per-user via the `owner` column + RLS:
-- 1. Alice's variables are invisible to Bob
-- 2. Bob cannot read Alice's variables via df.getvar()
-- 3. Each user's df.start() captures only their own vars
-- 4. df.clearvars() only clears the calling user's variables
-- 5. Superuser sees all variables (RLS bypass) but df.start() captures
--    only their own (explicit owner filter in code)
--
-- Must run as SUPERUSER because it uses SET SESSION AUTHORIZATION.

-- ============================================================================
-- Setup: Create two test users
-- ============================================================================
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

-- Grant df privileges explicitly (no longer auto-granted to PUBLIC)
SELECT df.grant_usage('vars_alice');
SELECT df.grant_usage('vars_bob');

GRANT TEMPORARY ON DATABASE postgres TO vars_alice, vars_bob;

-- Create a shared results table (owned by superuser so both users can INSERT)
DROP TABLE IF EXISTS vars_test_results;
CREATE TABLE vars_test_results (id SERIAL PRIMARY KEY, username TEXT, msg TEXT);
GRANT SELECT, INSERT ON vars_test_results TO PUBLIC;
GRANT USAGE ON SEQUENCE vars_test_results_id_seq TO PUBLIC;

-- ============================================================================
-- Test 1: Per-user variable isolation via direct table access
-- ============================================================================

-- Alice sets a variable
SET SESSION AUTHORIZATION vars_alice;
SELECT df.setvar('color', 'red');
RESET SESSION AUTHORIZATION;

-- Bob sets the same-named variable with a different value
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
    -- Alice should see only her variable
    SET SESSION AUTHORIZATION vars_alice;
    SELECT df.getvar('color') INTO alice_val;
    SELECT count(*) INTO alice_count FROM df.vars;
    RESET SESSION AUTHORIZATION;

    -- Bob should see only his variable
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

-- ============================================================================
-- Test 2: df.start() captures only the calling user's variables
-- ============================================================================

-- Alice starts a workflow that uses her variable
SET SESSION AUTHORIZATION vars_alice;
CREATE TEMP TABLE _vars_alice_state (instance_id TEXT);
INSERT INTO _vars_alice_state SELECT df.start(
    'INSERT INTO vars_test_results (username, msg) VALUES (''alice'', ''{color}'')' ::text,
    'vars-alice-color'
);
RESET SESSION AUTHORIZATION;

-- Bob starts a workflow that uses his variable
SET SESSION AUTHORIZATION vars_bob;
CREATE TEMP TABLE _vars_bob_state (instance_id TEXT);
INSERT INTO _vars_bob_state SELECT df.start(
    'INSERT INTO vars_test_results (username, msg) VALUES (''bob'', ''{color}'')' ::text,
    'vars-bob-color'
);
RESET SESSION AUTHORIZATION;

-- Wait for both to complete
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

-- Verify each workflow used the correct user's variable
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

-- ============================================================================
-- Test 3: df.clearvars() only clears the calling user's variables
-- ============================================================================

-- Alice clears her vars
SET SESSION AUTHORIZATION vars_alice;
SELECT df.clearvars();
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    alice_val TEXT;
    bob_val TEXT;
BEGIN
    -- Alice's var should be gone
    SET SESSION AUTHORIZATION vars_alice;
    SELECT df.getvar('color') INTO alice_val;
    RESET SESSION AUTHORIZATION;

    -- Bob's var should still exist
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

-- ============================================================================
-- Test 4: df.unsetvar() only removes the calling user's variable
-- ============================================================================

-- Re-create Alice's variable
SET SESSION AUTHORIZATION vars_alice;
SELECT df.setvar('shared_key', 'alice_value');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION vars_bob;
SELECT df.setvar('shared_key', 'bob_value');
-- Bob tries to unset 'shared_key' — should only remove his own
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

-- ============================================================================
-- Test 5: Superuser sees all variables (RLS bypass) but df.start()
--         captures only superuser's own vars
-- ============================================================================

-- Set up: Alice has 'shared_key', Bob has nothing, superuser sets its own var
SET SESSION AUTHORIZATION vars_bob;
SELECT df.clearvars();
RESET SESSION AUTHORIZATION;

-- Superuser sets its own variable
SELECT df.setvar('su_var', 'superuser_value');

DO $$
DECLARE
    total_count INT;
BEGIN
    -- Superuser should see exactly 2 vars (bypasses RLS): Alice's shared_key + superuser's su_var
    SELECT count(*) INTO total_count FROM df.vars;

    IF total_count != 2 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Superuser should see exactly 2 vars (alice + su), saw %', total_count;
    END IF;

    RAISE NOTICE 'Test 5 PASSED: Superuser sees all variables (% total)', total_count;
END $$;

-- Superuser starts a workflow — should capture only its own vars, not Alice's
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

-- ============================================================================
-- Cleanup
-- ============================================================================
DROP TABLE IF EXISTS _vars_alice_state;
DROP TABLE IF EXISTS _vars_bob_state;
DROP TABLE IF EXISTS _vars_su_state;
DROP TABLE IF EXISTS vars_test_results;

-- Clear all vars (as superuser, bypasses RLS)
DELETE FROM df.vars WHERE owner IN ('vars_alice'::regrole, 'vars_bob'::regrole);
-- Clear superuser's vars
SELECT df.clearvars();

DO $cleanup$
BEGIN
    BEGIN DROP OWNED BY vars_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY vars_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE vars_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE vars_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $cleanup$;

SELECT 'TEST PASSED' AS result;
