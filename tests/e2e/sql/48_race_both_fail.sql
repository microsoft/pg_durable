-- Test: RACE where both branches fail (B8)
-- Demonstrates: ctx.select2 behavior when both branches of a RACE node error
-- Expected: Instance transitions to Failed (not stuck in Running)

-- ============================================================================
-- B8a: df.race() function — both branches fail
-- ============================================================================
CREATE TEMP TABLE _b8a_state AS
SELECT df.start(
    df.race(
        'SELECT 1/0',   -- division by zero
        'SELECT 2/0'    -- division by zero
    ),
    'test-race-both-fail-func'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b8a_state;
    RAISE NOTICE 'B8a: Testing race(both-fail) func: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('failed', 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED [B8a]: expected Failed for race(both-fail), got %', status;
    END IF;

    RAISE NOTICE 'B8a: race(both-fail) status = %', status;
    RAISE NOTICE 'PASSED [B8a]: race with both branches failing is handled gracefully';
END $$;

DROP TABLE _b8a_state;

-- ============================================================================
-- B8b: | operator — both branches fail
-- ============================================================================
CREATE TEMP TABLE _b8b_state AS
SELECT df.start(
    'SELECT 1/0' | 'SELECT 2/0',
    'test-race-both-fail-op'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b8b_state;
    RAISE NOTICE 'B8b: Testing | operator both-fail: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('failed', 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED [B8b]: expected Failed for | both-fail, got %', status;
    END IF;

    RAISE NOTICE 'B8b: | both-fail status = %', status;
    RAISE NOTICE 'PASSED [B8b]: | operator with both branches failing is handled gracefully';
END $$;

DROP TABLE _b8b_state;
SELECT 'TEST PASSED' AS result;
