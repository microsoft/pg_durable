-- Test: Named result dot-notation, null-safe accessor, strict fail
-- Tests $name.column, $name.column?, $name?, and fail-fast on no-rows/NULL

-- ============================================================================
-- Test 1: Dot-notation — access specific columns
-- ============================================================================

DROP TABLE IF EXISTS test_dot_results;
CREATE TABLE test_dot_results (id SERIAL, got_id INT, got_content TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT 42 AS id, 'hello' AS content$$ |=> 'doc'
    ~> $$INSERT INTO test_dot_results (got_id, got_content) VALUES ($doc.id, $doc.content)$$,
    'test-dot-notation'
), 'dot';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    r_id INT;
    r_content TEXT;
BEGIN
    SELECT instance_id INTO rec FROM _test_state WHERE variant = 'dot';

    SELECT df.wait_for_completion(rec.instance_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [dot-notation]: status = %', status;
    END IF;

    SELECT got_id, got_content INTO r_id, r_content FROM test_dot_results ORDER BY id DESC LIMIT 1;

    IF r_id != 42 THEN
        RAISE EXCEPTION 'TEST FAILED [dot-notation]: expected id=42, got %', r_id;
    END IF;

    IF r_content != 'hello' THEN
        RAISE EXCEPTION 'TEST FAILED [dot-notation]: expected content=hello, got %', r_content;
    END IF;

    RAISE NOTICE 'PASSED: dot-notation';
END $$;

DROP TABLE _test_state;
DROP TABLE test_dot_results;

-- ============================================================================
-- Test 2: Null-safe accessor — $name.col? substitutes NULL
-- ============================================================================

DROP TABLE IF EXISTS test_nullsafe_results;
CREATE TABLE test_nullsafe_results (id SERIAL, val TEXT);

CREATE TEMP TABLE _test_state2 (instance_id TEXT);

INSERT INTO _test_state2 SELECT df.start(
    $$SELECT NULL::text AS val$$ |=> 'x'
    ~> $$INSERT INTO test_nullsafe_results (val) VALUES (COALESCE($x.val?, 'fallback'))$$,
    'test-null-safe'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    val_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state2;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [null-safe]: status = %', status;
    END IF;

    SELECT val INTO val_result FROM test_nullsafe_results ORDER BY id DESC LIMIT 1;

    IF val_result != 'fallback' THEN
        RAISE EXCEPTION 'TEST FAILED [null-safe]: expected fallback, got %', val_result;
    END IF;

    RAISE NOTICE 'PASSED: null-safe accessor';
END $$;

DROP TABLE _test_state2;
DROP TABLE test_nullsafe_results;

-- ============================================================================
-- Test 3: Strict fail — $name on empty result fails the instance
-- ============================================================================

CREATE TEMP TABLE _test_state3 (instance_id TEXT);

INSERT INTO _test_state3 SELECT df.start(
    $$SELECT 1 WHERE false$$ |=> 'empty'
    ~> $$SELECT $empty$$,
    'test-strict-fail'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state3;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [strict-fail]: expected failed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED: strict fail on no-rows';
END $$;

DROP TABLE _test_state3;

SELECT 'TEST PASSED' AS result;
