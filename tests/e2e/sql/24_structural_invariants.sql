-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.assert_structural_invariants() structural-invariant oracle (#232, Phase 1).
-- Covers the happy path (sequence/IF/JOIN/loop all pass), the fail_on_violation
-- assertion form (no raise on a clean instance), and the missing-instance path
-- (instance_found=false, and a raise when fail_on_violation => true).
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test 1: happy-path sequence — every invariant passes ===

DROP TABLE IF EXISTS test_inv_log;
CREATE TABLE test_inv_log (id SERIAL, val INT);

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    $$INSERT INTO test_inv_log (val) VALUES (1)$$
        ~> $$INSERT INTO test_inv_log (val) VALUES (2)$$,
    'test-inv-sequence'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    all_passed BOOLEAN;
    viol_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [sequence]: status = %', status;
    END IF;

    SELECT bool_and(passed), count(*) FILTER (WHERE NOT passed)
      INTO all_passed, viol_count
      FROM df.assert_structural_invariants(inst_id);

    IF NOT all_passed OR viol_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILED [sequence]: % violation(s) on a clean instance', viol_count;
    END IF;

    -- Assertion form must NOT raise on a clean instance.
    PERFORM count(*) FROM df.assert_structural_invariants(inst_id, true);

    RAISE NOTICE 'PASSED: sequence invariants';
END $$;

DROP TABLE _test_state;
DROP TABLE test_inv_log;

-- === Test 2: IF — taken branch completed, untaken branch pending ===

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.if('SELECT true', 'SELECT 1', 'SELECT 2'),
    'test-inv-if'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    all_passed BOOLEAN;
    untaken_passed BOOLEAN;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [if]: status = %', status;
    END IF;

    SELECT bool_and(passed) INTO all_passed
      FROM df.assert_structural_invariants(inst_id);

    SELECT bool_and(passed) INTO untaken_passed
      FROM df.assert_structural_invariants(inst_id)
      WHERE invariant = 'untaken_if_branch_pending';

    IF NOT all_passed THEN
        RAISE EXCEPTION 'TEST FAILED [if]: unexpected invariant violation';
    END IF;

    IF untaken_passed IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED [if]: untaken_if_branch_pending did not pass';
    END IF;

    RAISE NOTICE 'PASSED: IF invariants';
END $$;

DROP TABLE _test_state;

-- === Test 3: JOIN — all parallel branches completed ===

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.join('SELECT 1', 'SELECT 2'),
    'test-inv-join'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    branches_passed BOOLEAN;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [join]: status = %', status;
    END IF;

    SELECT bool_and(passed) INTO branches_passed
      FROM df.assert_structural_invariants(inst_id);

    IF branches_passed IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED [join]: unexpected invariant violation';
    END IF;

    RAISE NOTICE 'PASSED: JOIN invariants';
END $$;

DROP TABLE _test_state;

-- === Test 4: terminating while-loop — relaxed loop-body checks still pass ===

DROP TABLE IF EXISTS test_inv_counter;
CREATE TABLE test_inv_counter (n INT);
INSERT INTO test_inv_counter VALUES (0);

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.loop(
        $$UPDATE test_inv_counter SET n = n + 1$$,
        $$SELECT (SELECT n FROM test_inv_counter) < 3$$
    ),
    'test-inv-loop'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    loop_passed BOOLEAN;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop]: status = %', status;
    END IF;

    SELECT bool_and(passed) INTO loop_passed
      FROM df.assert_structural_invariants(inst_id);

    IF loop_passed IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED [loop]: relaxed loop checks reported a false violation';
    END IF;

    RAISE NOTICE 'PASSED: loop invariants (relaxed)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_inv_counter;

-- === Test 5: missing / not-visible instance — instance_found=false and raises ===

DO $$
DECLARE
    found_passed BOOLEAN;
    inv_name TEXT;
BEGIN
    SELECT passed, invariant INTO found_passed, inv_name
      FROM df.assert_structural_invariants('no-such-instance-0000')
      LIMIT 1;

    IF inv_name IS DISTINCT FROM 'instance_found' OR found_passed IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'TEST FAILED [missing]: expected instance_found=false, got %/%', inv_name, found_passed;
    END IF;

    -- fail_on_violation => true must raise for a missing instance.
    BEGIN
        PERFORM count(*) FROM df.assert_structural_invariants('no-such-instance-0000', true);
        RAISE EXCEPTION 'TEST FAILED [missing]: fail_on_violation did not raise';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'TEST FAILED%' THEN
            RAISE;
        END IF;
        RAISE NOTICE 'PASSED: missing instance raises with fail_on_violation (%)' , SQLERRM;
    END;
END $$;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
