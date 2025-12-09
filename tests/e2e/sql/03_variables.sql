-- Test: Variable substitution
-- Tests both |=> operator and df.as() function
-- Expected: Second step receives value from first step

DROP TABLE IF EXISTS test_vars_log;
CREATE TABLE test_vars_log (id SERIAL, val TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: Using |=> operator
INSERT INTO _test_state SELECT df.start(
    'SELECT 100 as num' |=> 'x'
    ~> 'INSERT INTO test_vars_log (val, variant) VALUES ($x::text, ''op'')',
    'test-variables-op'
), 'operator';

-- Variant B: Using df.as() function
INSERT INTO _test_state SELECT df.start(
    df.seq(
        df.as('SELECT 200 as num', 'y'),
        'INSERT INTO test_vars_log (val, variant) VALUES ($y::text, ''fn'')'
    ),
    'test-variables-fn'
), 'function';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    val_result TEXT;
    expected TEXT;
    attempts INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;
        attempts := 0;
        
        LOOP
            SELECT s INTO status FROM df.status(rec.instance_id) s;
            EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        
        IF lower(status) != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;
        
        IF rec.variant = 'operator' THEN
            expected := '100';
            SELECT val INTO val_result FROM test_vars_log WHERE variant = 'op' ORDER BY id DESC LIMIT 1;
        ELSE
            expected := '200';
            SELECT val INTO val_result FROM test_vars_log WHERE variant = 'fn' ORDER BY id DESC LIMIT 1;
        END IF;
        
        IF val_result IS NULL OR val_result NOT LIKE '%' || expected || '%' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected value containing %, got %', rec.variant, expected, val_result;
        END IF;
        
        RAISE NOTICE 'PASSED: variables [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: variables (both variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_vars_log;
SELECT 'TEST PASSED' AS result;
