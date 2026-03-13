-- Test: Multi-statement SQL in df.sql()
-- Verifies that df.sql() can execute multiple semicolon-separated statements
-- e.g. df.sql('INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)')

DROP TABLE IF EXISTS test_multi_stmt;
CREATE TABLE test_multi_stmt (id SERIAL, step INT);

CREATE TEMP TABLE _test_state (instance_id TEXT, test_name TEXT);

-- ============================================================
-- Test 1: Two INSERT statements separated by semicolon
-- Both should execute and each insert a row.
-- ============================================================

INSERT INTO _test_state SELECT df.start(
    df.sql('INSERT INTO test_multi_stmt (step) VALUES (1); INSERT INTO test_multi_stmt (step) VALUES (2)'),
    'test-multi-stmt-two-inserts'
), 'two_inserts';

-- ============================================================
-- Test 2: Three statements with different operations
-- ============================================================

INSERT INTO _test_state SELECT df.start(
    df.sql('INSERT INTO test_multi_stmt (step) VALUES (10); INSERT INTO test_multi_stmt (step) VALUES (20); INSERT INTO test_multi_stmt (step) VALUES (30)'),
    'test-multi-stmt-three-inserts'
), 'three_inserts';

-- ============================================================
-- Test 3: Multi-statement SQL with a result piped to next node
-- The last SELECT's result should be available via |=>
-- ============================================================

INSERT INTO _test_state SELECT df.start(
    df.sql('INSERT INTO test_multi_stmt (step) VALUES (100); SELECT 42 AS answer') |=> 'multi_result'
    ~> df.sql('INSERT INTO test_multi_stmt (step) VALUES ($multi_result::int)'),
    'test-multi-stmt-result'
), 'result_pipe';

-- ============================================================
-- Test 4: Atomicity — if the second statement fails, the first
-- should be rolled back (multi-statement runs in a transaction)
-- ============================================================

INSERT INTO _test_state SELECT df.start(
    df.sql('INSERT INTO test_multi_stmt (step) VALUES (999); INSERT INTO nonexistent_table_xyz VALUES (1)'),
    'test-multi-stmt-rollback'
), 'rollback';

-- ============================================================
-- Verify results
-- ============================================================

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
    val INT;
BEGIN
    -- Wait for all instances (some expected to fail)
    FOR rec IN SELECT instance_id, test_name FROM _test_state LOOP
        RAISE NOTICE 'Waiting for [%]: %', rec.test_name, rec.instance_id;
        SELECT df.wait_for_completion(rec.instance_id, 30) INTO status;

        IF rec.test_name = 'rollback' THEN
            -- This one should fail
            IF lower(status) != 'failed' THEN
                RAISE EXCEPTION 'TEST FAILED [rollback]: expected failed, got %', status;
            END IF;
            RAISE NOTICE '[%] failed as expected', rec.test_name;
        ELSE
            IF lower(status) != 'completed' THEN
                RAISE EXCEPTION 'TEST FAILED [%]: expected completed, got %', rec.test_name, status;
            END IF;
            RAISE NOTICE '[%] completed', rec.test_name;
        END IF;
    END LOOP;

    -- Test 1: Both inserts should have run
    SELECT COUNT(*) INTO cnt FROM test_multi_stmt WHERE step IN (1, 2);
    IF cnt != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [two_inserts]: expected 2 rows with step 1,2 but got %', cnt;
    END IF;

    -- Test 2: All three inserts should have run
    SELECT COUNT(*) INTO cnt FROM test_multi_stmt WHERE step IN (10, 20, 30);
    IF cnt != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [three_inserts]: expected 3 rows with step 10,20,30 but got %', cnt;
    END IF;

    -- Test 3: The INSERT (step=100) + the piped result INSERT (step=42)
    SELECT COUNT(*) INTO cnt FROM test_multi_stmt WHERE step = 100;
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [result_pipe]: expected 1 row with step=100 but got %', cnt;
    END IF;
    SELECT COUNT(*) INTO cnt FROM test_multi_stmt WHERE step = 42;
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [result_pipe]: expected 1 row with step=42 (piped from multi-stmt SELECT) but got %', cnt;
    END IF;

    -- Test 4: The INSERT of step=999 should have been rolled back
    SELECT COUNT(*) INTO cnt FROM test_multi_stmt WHERE step = 999;
    IF cnt != 0 THEN
        RAISE EXCEPTION 'TEST FAILED [rollback]: expected 0 rows with step=999 (should be rolled back) but got %', cnt;
    END IF;

    RAISE NOTICE 'All multi-statement SQL tests passed';
END $$;

DROP TABLE _test_state;
DROP TABLE test_multi_stmt;
SELECT 'TEST PASSED' AS result;
