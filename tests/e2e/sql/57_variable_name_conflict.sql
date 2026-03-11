-- Test: Variable substitution edge cases — name conflicts and overwrites (B4 / B14)
-- B4: A result binding that shadows a user variable of the same name
-- B14: Two sequential steps binding the same result name (the second overwrites the first)
-- Expected: System handles shadowing/overwriting gracefully without error

SELECT df.clearvars();

-- ============================================================================
-- B14: Two steps bound to the same result name — second value wins
-- ============================================================================
DROP TABLE IF EXISTS test_var_conflict_log;
CREATE TABLE test_var_conflict_log (id SERIAL, val TEXT);

-- Start instance at top level so it commits before polling
CREATE TEMP TABLE _b14_state AS SELECT df.start(
    'SELECT ''first'' AS val' |=> 'x'
    ~> ('SELECT ''second'' AS val' |=> 'x')
    ~> 'INSERT INTO test_var_conflict_log (val) VALUES ($x) RETURNING val',
    'test-var-name-conflict-b14'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    log_val TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b14_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [B14]: expected completed, got %', status;
    END IF;

    SELECT val INTO log_val FROM test_var_conflict_log ORDER BY id DESC LIMIT 1;
    IF log_val IS NULL OR log_val NOT LIKE '%second%' THEN
        RAISE EXCEPTION 'TEST FAILED [B14]: expected second to win name conflict, got %', log_val;
    END IF;

    RAISE NOTICE 'PASSED [B14]: second binding of same name correctly overwrites first';
END $$;

DROP TABLE _b14_state;

-- ============================================================================
-- B4: User variable shadowed by a step result of the same name
-- ============================================================================
SELECT df.clearvars();
SELECT df.setvar('user_val', 'from_user');

-- Start instance at top level so it commits before polling
CREATE TEMP TABLE _b4_state AS SELECT df.start(
    'SELECT ''from_step'' AS val' |=> 'user_val'
    ~> 'INSERT INTO test_var_conflict_log (val) VALUES ($user_val) RETURNING val',
    'test-var-shadow-b4'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    log_val TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b4_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [B4]: expected completed, got %', status;
    END IF;

    SELECT val INTO log_val FROM test_var_conflict_log ORDER BY id DESC LIMIT 1;
    IF log_val IS NULL OR log_val NOT LIKE '%from_step%' THEN
        RAISE EXCEPTION 'TEST FAILED [B4]: expected step result to shadow user var, got %', log_val;
    END IF;

    RAISE NOTICE 'PASSED [B4]: step result correctly shadows user-defined var of same name';
END $$;

DROP TABLE _b4_state;

SELECT df.clearvars();
DROP TABLE test_var_conflict_log;
SELECT 'TEST PASSED' AS result;
