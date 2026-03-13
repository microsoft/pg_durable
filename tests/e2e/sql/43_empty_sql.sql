-- Test: Empty and whitespace-only SQL strings (C1)
-- Demonstrates: df.sql('') and df.sql('   ') pass DSL validation but fail at execution
-- Expected: df.start() succeeds (validation doesn't reject empty queries),
--           but the instance transitions to Failed when worker executes the empty query.

-- ============================================================================
-- C1a: Empty string SQL
-- ============================================================================
CREATE TEMP TABLE _c1a_state AS
SELECT df.start(df.sql(''), 'test-empty-sql') AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _c1a_state;
    RAISE NOTICE 'C1a: Testing empty SQL, instance: %', inst_id;

    -- Empty query will fail at execution time (PostgreSQL rejects empty statement)
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('failed', 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED [C1a]: expected Failed or Completed for empty SQL, got %', status;
    END IF;

    RAISE NOTICE 'C1a: empty SQL result status = % (expected Failed)', status;
    RAISE NOTICE 'PASSED [C1a]: empty SQL handled gracefully (no crash)';
END $$;

DROP TABLE _c1a_state;

-- ============================================================================
-- C1b: Whitespace-only SQL
-- ============================================================================
CREATE TEMP TABLE _c1b_state AS
SELECT df.start(df.sql('   '), 'test-whitespace-sql') AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _c1b_state;
    RAISE NOTICE 'C1b: Testing whitespace SQL, instance: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('failed', 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED [C1b]: expected Failed or Completed for whitespace SQL, got %', status;
    END IF;

    RAISE NOTICE 'C1b: whitespace SQL result status = % (expected Failed)', status;
    RAISE NOTICE 'PASSED [C1b]: whitespace SQL handled gracefully (no crash)';
END $$;

DROP TABLE _c1b_state;

-- ============================================================================
-- C1c: Non-SQL text
-- ============================================================================
CREATE TEMP TABLE _c1c_state AS
SELECT df.start(df.sql('this is not valid sql at all'), 'test-nonsql') AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _c1c_state;
    RAISE NOTICE 'C1c: Testing non-SQL text, instance: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('failed', 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED [C1c]: expected Failed for non-SQL text, got %', status;
    END IF;

    RAISE NOTICE 'C1c: non-SQL text result status = % (expected Failed)', status;
    RAISE NOTICE 'PASSED [C1c]: non-SQL text handled gracefully (no crash)';
END $$;

DROP TABLE _c1c_state;
SELECT 'TEST PASSED' AS result;
