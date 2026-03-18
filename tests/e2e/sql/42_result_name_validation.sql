-- Test: Result name validation rejects unsafe identifiers
-- Ensures df.as() / |=> reject names that aren't valid SQL identifiers

-- ============================================================================
-- Test 1: Valid names should work
-- ============================================================================

DROP TABLE IF EXISTS test_name_valid_results;
CREATE TABLE test_name_valid_results (id SERIAL, val INT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT 42 AS num$$ |=> 'my_result'
    ~> $$INSERT INTO test_name_valid_results (val) VALUES ($my_result)$$,
    'test-name-valid'
), 'valid_name';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE variant = 'valid_name';
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [valid_name]: status = %', status;
    END IF;

    RAISE NOTICE 'PASSED: valid result name accepted';
END $$;

-- ============================================================================
-- Test 2: SQL injection attempt should be rejected at DSL time
-- ============================================================================

DO $$
BEGIN
    PERFORM df.start(
        df.as(df.sql('SELECT 1'), 'x) UNION SELECT version()--')
        ~> df.sql('SELECT 1'),
        'test-injection'
    );
    RAISE EXCEPTION 'TEST FAILED: injection name was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%not a valid identifier%' THEN
            RAISE NOTICE 'PASSED: injection name correctly rejected: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected error: %', SQLERRM;
        END IF;
END $$;

-- ============================================================================
-- Test 3: Name with spaces should be rejected
-- ============================================================================

DO $$
BEGIN
    PERFORM df.sql('SELECT 1') |=> 'has space';
    RAISE EXCEPTION 'TEST FAILED: spaced name was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%not a valid identifier%' THEN
            RAISE NOTICE 'PASSED: spaced name correctly rejected: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected error: %', SQLERRM;
        END IF;
END $$;

-- ============================================================================
-- Test 4: Name starting with digit should be rejected
-- ============================================================================

DO $$
BEGIN
    PERFORM df.sql('SELECT 1') |=> '123abc';
    RAISE EXCEPTION 'TEST FAILED: digit-start name was not rejected';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%not a valid identifier%' THEN
            RAISE NOTICE 'PASSED: digit-start name correctly rejected: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected error: %', SQLERRM;
        END IF;
END $$;

-- Cleanup
DROP TABLE _test_state;
DROP TABLE test_name_valid_results;
SELECT 'TEST PASSED' AS result;
