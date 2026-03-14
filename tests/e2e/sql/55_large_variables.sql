-- Test: Large variable payloads (A8)
-- Demonstrates: df.setvar() and {var} substitution handles large string values
--               without truncation or serialization errors.
-- Expected: Instance completes; the large value is preserved in the workflow.

SELECT df.clearvars();

-- Set a ~5KB variable value (a repeated pattern string)
SELECT df.setvar('big_val', repeat('abcdefghij', 500));  -- 5000 chars

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    result_text TEXT;
BEGIN
    -- Pass the big variable through a workflow step
    inst_id := df.start(
        'SELECT length(''{big_val}'') AS len' |=> 'result',
        'test-large-variable'
    );

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A8]: large variable expected completed, got %', status;
    END IF;

    SELECT r INTO result_text FROM df.result(inst_id) r;
    IF result_text IS NULL OR result_text NOT LIKE '%5000%' THEN
        RAISE EXCEPTION 'TEST FAILED [A8]: expected length 5000 in result, got %', result_text;
    END IF;

    RAISE NOTICE 'PASSED [A8]: 5KB variable payload handled without error';
END $$;

SELECT df.clearvars();
SELECT 'TEST PASSED' AS result;
