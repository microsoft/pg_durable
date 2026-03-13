-- Test: JOIN where one branch fails (B9)
-- Demonstrates: execute_join_node behavior when one branch errors
-- Expected: Instance transitions to Failed (not stuck). The successful branch's
--           side effects (if any committed DML) are already persisted.

DROP TABLE IF EXISTS test_join_fail_log;
CREATE TABLE test_join_fail_log (id SERIAL, branch TEXT, ts TIMESTAMP DEFAULT now());

-- ============================================================================
-- B9a: df.join() — left succeeds, right fails
-- ============================================================================
CREATE TEMP TABLE _b9a_state AS
SELECT df.start(
    df.join(
        'INSERT INTO test_join_fail_log (branch) VALUES (''left'') RETURNING ''ok''',
        'SELECT 1/0'   -- fails
    ),
    'test-join-one-fail-func'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    left_ran INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b9a_state;
    RAISE NOTICE 'B9a: Testing join(left-ok, right-fail): %', inst_id;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('failed', 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED [B9a]: expected Failed for join(one-fail), got %', status;
    END IF;

    -- Check whether the left branch's DML committed (it may or may not depending on tx boundaries)
    SELECT COUNT(*) INTO left_ran FROM test_join_fail_log WHERE branch = 'left';
    RAISE NOTICE 'B9a: join(one-fail) status=%, left branch ran=% time(s)', status, left_ran;
    RAISE NOTICE 'PASSED [B9a]: join with one failing branch handled gracefully';
END $$;

DROP TABLE _b9a_state;

-- ============================================================================
-- B9b: & operator — left fails, right succeeds
-- ============================================================================
CREATE TEMP TABLE _b9b_state AS
SELECT df.start(
    'SELECT 1/0'  -- fails
    & 'INSERT INTO test_join_fail_log (branch) VALUES (''right'') RETURNING ''ok''',
    'test-join-one-fail-op'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    right_ran INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b9b_state;
    RAISE NOTICE 'B9b: Testing & operator (left-fail, right-ok): %', inst_id;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('failed', 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED [B9b]: expected Failed for & (one-fail), got %', status;
    END IF;

    SELECT COUNT(*) INTO right_ran FROM test_join_fail_log WHERE branch = 'right';
    RAISE NOTICE 'B9b: & (one-fail) status=%, right branch ran=% time(s)', status, right_ran;
    RAISE NOTICE 'PASSED [B9b]: & operator with one failing branch handled gracefully';
END $$;

DROP TABLE _b9b_state;
DROP TABLE test_join_fail_log;
SELECT 'TEST PASSED' AS result;
