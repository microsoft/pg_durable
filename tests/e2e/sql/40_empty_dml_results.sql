-- Test: SQL nodes returning 0 rows or DML without RETURNING (B5 / B6)
-- Demonstrates: How empty result sets and DML results flow through |=> and $var
-- Expected: Both patterns complete successfully; documents the JSON result shape

DROP TABLE IF EXISTS test_dml_target;
CREATE TABLE test_dml_target (id SERIAL, val TEXT);

-- ============================================================================
-- B5: SQL node that returns 0 rows, result used in next node
-- ============================================================================
CREATE TEMP TABLE _b5_state AS
SELECT df.start(
    'SELECT 1 WHERE false' |=> 'empty_result'
    ~> 'SELECT $empty_result',   -- uses the empty result JSON
    'test-empty-result'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    res TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b5_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [B5]: expected Completed, got %', status;
    END IF;

    SELECT r INTO res FROM df.result(inst_id) r;
    RAISE NOTICE 'B5 result (empty result passed as $var): %', res;
    RAISE NOTICE 'PASSED [B5]: zero-row SQL result flows through |=> correctly';
END $$;

DROP TABLE _b5_state;

-- ============================================================================
-- B6: DML node without RETURNING, result used in next node
-- ============================================================================
INSERT INTO test_dml_target (val) VALUES ('initial');

CREATE TEMP TABLE _b6_state AS
SELECT df.start(
    'UPDATE test_dml_target SET val = ''updated''' |=> 'update_result'
    ~> 'SELECT $update_result',  -- uses the DML result JSON (0 rows, row_count > 0)
    'test-dml-result'
) AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    res TEXT;
    updated_val TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _b6_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [B6]: expected Completed, got %', status;
    END IF;

    SELECT r INTO res FROM df.result(inst_id) r;
    RAISE NOTICE 'B6 result (DML result passed as $var): %', res;

    -- Verify the DML actually ran
    SELECT val INTO updated_val FROM test_dml_target LIMIT 1;
    IF updated_val != 'updated' THEN
        RAISE EXCEPTION 'TEST FAILED [B6]: DML did not execute, val = %', updated_val;
    END IF;

    RAISE NOTICE 'PASSED [B6]: DML result flows through |=> correctly';
END $$;

DROP TABLE _b6_state;

-- ============================================================================
-- Cleanup
-- ============================================================================
DROP TABLE test_dml_target;
SELECT 'TEST PASSED' AS result;
