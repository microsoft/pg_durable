-- Test: Conditional execution - false branch
-- Tests df.if() function and ?> !> operators
-- Expected: Else branch executes when condition is false

DROP TABLE IF EXISTS test_cond_false_log;
CREATE TABLE test_cond_false_log (id SERIAL, branch TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: df.if() function
INSERT INTO _test_state SELECT df.start(
    df.if(
        'SELECT false',
        'INSERT INTO test_cond_false_log (branch, variant) VALUES (''then'', ''func'')',
        'INSERT INTO test_cond_false_log (branch, variant) VALUES (''else'', ''func'')'
    ),
    'test-cond-false-func'
), 'func';

-- Variant B: ?> !> operators
INSERT INTO _test_state SELECT df.start(
    'SELECT false'
        ?> 'INSERT INTO test_cond_false_log (branch, variant) VALUES (''then'', ''op'')'
        !> 'INSERT INTO test_cond_false_log (branch, variant) VALUES (''else'', ''op'')',
    'test-cond-false-op'
), 'op';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    branch_val TEXT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;
        
        SELECT branch INTO branch_val 
        FROM test_cond_false_log WHERE variant = rec.variant ORDER BY id DESC LIMIT 1;
        
        IF branch_val != 'else' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected else branch, got %', rec.variant, branch_val;
        END IF;
        
        RAISE NOTICE 'PASSED: conditional_false [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: conditional_false (func + ?> !> operators)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_cond_false_log;
SELECT 'TEST PASSED' AS result;
