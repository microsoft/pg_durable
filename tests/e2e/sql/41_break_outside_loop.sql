-- Test: df.break() used at the top level outside any loop (B10)
-- Demonstrates: Break sentinel propagated as final instance result
-- Expected: Instance completes (the break sentinel becomes the result),
--           does NOT hang or crash.

CREATE TEMP TABLE _b10_state AS
SELECT df.start(
    df.break('{"reason": "top-level-break"}'),
    'test-break-outside-loop'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    res TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b10_state;

    -- A top-level break has no enclosing loop to consume it, so the break
    -- sentinel propagates as the final result.  The instance should complete
    -- rather than hang or fail with an error.
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [B10]: expected Completed for top-level break, got %', status;
    END IF;

    SELECT r INTO res FROM df.result(inst_id) r;
    RAISE NOTICE 'B10 result (top-level break value): %', res;
    RAISE NOTICE 'PASSED [B10]: df.break() at top level completes gracefully';
END $$;

DROP TABLE _b10_state;
SELECT 'TEST PASSED' AS result;
