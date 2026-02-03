-- Test: Explain on plain SQL input (auto-wrap)
-- Expected: df.explain('SELECT 1') produces a SQL node visualization

DO $body$
DECLARE
    explain_output TEXT;
BEGIN
    SELECT df.explain('SELECT 1') INTO explain_output;

    IF explain_output IS NULL OR explain_output = '' THEN
        RAISE EXCEPTION 'TEST FAILED: explain returned empty output';
    END IF;

    IF explain_output NOT LIKE '%SQL:%' OR explain_output NOT LIKE '%SELECT 1%' THEN
        RAISE EXCEPTION 'TEST FAILED: explain should show SQL: SELECT 1, got: %', explain_output;
    END IF;

    RAISE NOTICE 'TEST PASSED: explain plain SQL';
END $body$;

SELECT 'TEST PASSED' AS result;
