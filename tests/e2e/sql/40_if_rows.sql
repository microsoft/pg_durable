-- Test: df.if_rows — branch on whether a named result has rows
-- Tests df.if_rows() with rows present (then branch) and zero rows (else branch)

-- ============================================================================
-- Test 1: if_rows with rows present → then branch executes
-- ============================================================================

DROP TABLE IF EXISTS test_if_rows_log;
CREATE TABLE test_if_rows_log (id SERIAL, branch TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT 1 AS val$$ |=> 'data'
    ~> df.if_rows(
        'data',
        $$INSERT INTO test_if_rows_log (branch, variant) VALUES ('then', 'has_rows')$$,
        $$INSERT INTO test_if_rows_log (branch, variant) VALUES ('else', 'has_rows')$$
    ),
    'test-if-rows-has-rows'
), 'has_rows';

-- Test 2: if_rows with zero rows → else branch executes
INSERT INTO _test_state SELECT df.start(
    $$SELECT 1 WHERE false$$ |=> 'empty'
    ~> df.if_rows(
        'empty',
        $$INSERT INTO test_if_rows_log (branch, variant) VALUES ('then', 'no_rows')$$,
        $$INSERT INTO test_if_rows_log (branch, variant) VALUES ('else', 'no_rows')$$
    ),
    'test-if-rows-no-rows'
), 'no_rows';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    branch_val TEXT;
    expected_branch TEXT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;

        IF rec.variant = 'has_rows' THEN
            expected_branch := 'then';
        ELSE
            expected_branch := 'else';
        END IF;

        SELECT branch INTO branch_val
        FROM test_if_rows_log
        WHERE variant = rec.variant
        ORDER BY id DESC LIMIT 1;

        IF branch_val != expected_branch THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected % branch, got %', rec.variant, expected_branch, branch_val;
        END IF;

        RAISE NOTICE 'PASSED: if_rows [%]', rec.variant;
    END LOOP;

    RAISE NOTICE 'TEST PASSED: if_rows (both variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_if_rows_log;

-- ============================================================================
-- Test 3: if_rows combined with dot-notation in then branch
-- ============================================================================

DROP TABLE IF EXISTS test_if_rows_dot;
CREATE TABLE test_if_rows_dot (id SERIAL, val INT);

CREATE TEMP TABLE _test_state2 (instance_id TEXT);

INSERT INTO _test_state2 SELECT df.start(
    $$SELECT 99 AS num$$ |=> 'result'
    ~> df.if_rows(
        'result',
        $$INSERT INTO test_if_rows_dot (val) VALUES ($result.num)$$,
        $$INSERT INTO test_if_rows_dot (val) VALUES (-1)$$
    ),
    'test-if-rows-dot'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    val_result INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state2;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [if_rows+dot]: status = %', status;
    END IF;

    SELECT val INTO val_result FROM test_if_rows_dot ORDER BY id DESC LIMIT 1;

    IF val_result != 99 THEN
        RAISE EXCEPTION 'TEST FAILED [if_rows+dot]: expected 99, got %', val_result;
    END IF;

    RAISE NOTICE 'PASSED: if_rows combined with dot-notation';
END $$;

DROP TABLE _test_state2;
DROP TABLE test_if_rows_dot;

SELECT 'TEST PASSED' AS result;
