-- Test: Signal edge cases (B12 / B13)
-- B12: Signal to non-existent or already-completed instance
-- B13: Multiple signals with the same name sent to one instance

-- ============================================================================
-- B12a: Signal to a garbage/non-existent instance ID
-- ============================================================================
DO $$
BEGIN
    BEGIN
        PERFORM df.signal('nonexistentid', 'approve', '{}');
        -- Sending to a non-existent ID may silently succeed (no row to update)
        -- or raise an error — document the actual behavior
        RAISE NOTICE 'B12a: df.signal to non-existent ID did not raise an error';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'B12a: df.signal to non-existent ID raised: %', SQLERRM;
    END;
END $$;

-- ============================================================================
-- B12b: Signal to an already-completed instance
-- ============================================================================
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    -- Start and complete a trivial instance
    inst_id := df.start('SELECT 1', 'test-signal-after-complete');
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST SETUP FAILED [B12b]: instance did not complete, got %', status;
    END IF;

    -- Now try to signal the completed instance
    BEGIN
        PERFORM df.signal(inst_id, 'too-late', '{"note": "already done"}');
        RAISE NOTICE 'B12b: df.signal to completed instance did not raise an error';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'B12b: df.signal to completed instance raised: %', SQLERRM;
    END;
END $$;

-- ============================================================================
-- B13: Multiple signals with the same name to the same waiting instance
-- ============================================================================
CREATE TEMP TABLE _b13_state AS
SELECT df.start(
    df.wait_for_signal('multi-signal') |=> 'sig'
    ~> 'SELECT $sig',
    'test-multi-signal'
) AS instance_id;

-- Wait for the instance to reach the waiting-for-signal state
SELECT pg_sleep(2);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b13_state;
    RAISE NOTICE 'B13: instance waiting for signal: %', inst_id;

    -- Send the signal twice
    BEGIN
        PERFORM df.signal(inst_id, 'multi-signal', '{"delivery": 1}');
        RAISE NOTICE 'B13: first signal sent';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'B13: first signal error: %', SQLERRM;
    END;

    BEGIN
        PERFORM df.signal(inst_id, 'multi-signal', '{"delivery": 2}');
        RAISE NOTICE 'B13: second signal sent';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'B13: second signal error: %', SQLERRM;
    END;

    -- Wait for instance to complete
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('completed', 'failed') THEN
        RAISE EXCEPTION 'TEST FAILED [B13]: expected Completed or Failed, got %', status;
    END IF;

    RAISE NOTICE 'B13: multiple signals result status = %', status;
    RAISE NOTICE 'PASSED [B13]: duplicate signal handled without crash';
END $$;

DROP TABLE _b13_state;
SELECT 'TEST PASSED' AS result;
