-- Test: Complex sub-orchestration composition
-- Tests combining named functions, inline calls, and fan-out patterns

DROP TABLE IF EXISTS test_complex_log;
CREATE TABLE test_complex_log (
    id SERIAL PRIMARY KEY,
    step TEXT,
    value INT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Define reusable sub-workflows
SELECT df.define(
    'step_a',
    'INSERT INTO test_complex_log (step, value) VALUES (''step_a'', 1)',
    'First reusable step'
);

SELECT df.define(
    'step_b',
    'INSERT INTO test_complex_log (step, value) VALUES (''step_b'', 2)',
    'Second reusable step'
);

-- Complex workflow: sequential -> parallel named functions -> inline call -> fan-out
CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state
SELECT df.start(
    df.seq(
        'INSERT INTO test_complex_log (step, value) VALUES (''start'', 0)',
        df.seq(
            -- Call two named functions in parallel
            df.join(
                df.call('step_a'),
                df.call('step_b')
            ),
            df.seq(
                -- Inline call
                df.call('INSERT INTO test_complex_log (step, value) VALUES (''inline'', 3)'),
                -- Fan-out with array
                df.when_all('[
                    "INSERT INTO test_complex_log (step, value) VALUES (''fan1'', 4)",
                    "INSERT INTO test_complex_log (step, value) VALUES (''fan2'', 5)",
                    "INSERT INTO test_complex_log (step, value) VALUES (''fan3'', 6)"
                ]')
            )
        )
    ),
    'test-complex-composition'
);

-- Poll until complete (30s timeout)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %, instance = %', status, inst_id;
    END IF;
END $$;

-- Verify all steps were executed
DO $$
DECLARE
    total_count INT;
    start_count INT;
    step_a_count INT;
    step_b_count INT;
    inline_count INT;
    fan_count INT;
BEGIN
    SELECT COUNT(*) INTO total_count FROM test_complex_log;
    SELECT COUNT(*) INTO start_count FROM test_complex_log WHERE step = 'start';
    SELECT COUNT(*) INTO step_a_count FROM test_complex_log WHERE step = 'step_a';
    SELECT COUNT(*) INTO step_b_count FROM test_complex_log WHERE step = 'step_b';
    SELECT COUNT(*) INTO inline_count FROM test_complex_log WHERE step = 'inline';
    SELECT COUNT(*) INTO fan_count FROM test_complex_log WHERE step LIKE 'fan%';
    
    IF total_count != 7 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 7 total steps, got %', total_count;
    END IF;
    
    IF start_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 start, got %', start_count;
    END IF;
    
    IF step_a_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 step_a, got %', step_a_count;
    END IF;
    
    IF step_b_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 step_b, got %', step_b_count;
    END IF;
    
    IF inline_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 inline, got %', inline_count;
    END IF;
    
    IF fan_count != 3 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 3 fan steps, got %', fan_count;
    END IF;
    
    RAISE NOTICE 'PASSED: complex_composition - all patterns work together';
END $$;

-- Cleanup
SELECT df.undefine('step_a');
SELECT df.undefine('step_b');
DROP TABLE _test_state;
DROP TABLE test_complex_log;
SELECT 'TEST PASSED' AS result;
