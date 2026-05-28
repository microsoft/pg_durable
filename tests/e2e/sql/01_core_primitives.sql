-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 01_simple_sql, 02_sequence, 04_parallel_join, 07_sleep, 16_scenario_join3, 17_race
-- Tests: simple SQL execution, sequential steps, parallel join, sleep/timer,
--        three-way parallel join, race/first-wins execution
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 01_simple_sql ===

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: Auto-wrapped SQL (plain string)
INSERT INTO _test_state 
SELECT df.start('SELECT 42 as answer', 'test-simple-auto'), 'auto';

-- Variant B: Explicit df.sql() function
INSERT INTO _test_state 
SELECT df.start(df.sql('SELECT 42 as answer'), 'test-simple-func'), 'func';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    result TEXT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected completed, got %', rec.variant, status;
        END IF;
        
        SELECT r INTO result FROM df.result(rec.instance_id) r;
        IF result NOT LIKE '%42%' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: result should contain 42, got %', rec.variant, result;
        END IF;
        
        RAISE NOTICE 'PASSED: simple_sql [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: simple_sql (both variants)';
END $$;

DROP TABLE _test_state;

-- === Test: 02_sequence ===

DROP TABLE IF EXISTS test_sequence_log;
CREATE TABLE test_sequence_log (id SERIAL, step INT, variant TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Variant A: Using ~> operator
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''op'')',
    'test-sequence-op'
), 'operator';

-- Variant B: Using df.seq() function
INSERT INTO _test_state SELECT df.start(
    df.seq(
        df.seq(
            'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''fn'')',
            'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''fn'')'
        ),
        'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''fn'')'
    ),
    'test-sequence-fn'
), 'function';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    steps INT[];
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;
        
        IF rec.variant = 'operator' THEN
            SELECT array_agg(step ORDER BY id) INTO steps 
            FROM test_sequence_log WHERE variant = 'op';
        ELSE
            SELECT array_agg(step ORDER BY id) INTO steps 
            FROM test_sequence_log WHERE variant = 'fn';
        END IF;
        
        IF steps != ARRAY[1,2,3] THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected [1,2,3], got %', rec.variant, steps;
        END IF;
        
        RAISE NOTICE 'PASSED: sequence [%]', rec.variant;
    END LOOP;
    
    RAISE NOTICE 'TEST PASSED: sequence (both variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_sequence_log;

-- === Test: 04_parallel_join ===

DROP TABLE IF EXISTS test_parallel_log;
CREATE TABLE test_parallel_log (id SERIAL, branch TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Test A: df.join() function
INSERT INTO _test_state SELECT df.start(
    df.join(
        'INSERT INTO test_parallel_log (branch, variant) VALUES (''A'', ''func'')',
        'INSERT INTO test_parallel_log (branch, variant) VALUES (''B'', ''func'')'
    ),
    'test-parallel-func'
), 'func';

-- Test B: & operator
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_parallel_log (branch, variant) VALUES (''A'', ''op'')'
    & 'INSERT INTO test_parallel_log (branch, variant) VALUES (''B'', ''op'')',
    'test-parallel-op'
), 'op';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;

        SELECT COUNT(DISTINCT branch) INTO cnt FROM test_parallel_log WHERE variant = rec.variant;
        IF cnt != 2 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected 2 branches, got %', rec.variant, cnt;
        END IF;
    END LOOP;

    RAISE NOTICE 'PASSED: parallel_join [func + & operator]';
END $$;

DROP TABLE _test_state;
DROP TABLE test_parallel_log;

-- === Test: 07_sleep ===

DROP TABLE IF EXISTS test_sleep_log;
CREATE TABLE test_sleep_log (id SERIAL, ts TIMESTAMP DEFAULT now());

INSERT INTO test_sleep_log DEFAULT VALUES;

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.sleep(2) ~> 'INSERT INTO test_sleep_log DEFAULT VALUES',
    'test-sleep'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    cnt INT;
    time_diff INTERVAL;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 50) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
    
    SELECT COUNT(*) INTO cnt FROM test_sleep_log;
    IF cnt != 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 2 log entries, got %', cnt;
    END IF;
    
    SELECT MAX(ts) - MIN(ts) INTO time_diff FROM test_sleep_log;
    IF time_diff < interval '1.5 seconds' THEN
        RAISE EXCEPTION 'TEST FAILED: sleep should be at least 2s, got %', time_diff;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: sleep';
END $$;

DROP TABLE _test_state;
DROP TABLE test_sleep_log;

-- === Test: 16_scenario_join3 ===

DROP TABLE IF EXISTS test_join3_log;
CREATE TABLE test_join3_log (id SERIAL, branch TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.join3(
        'INSERT INTO test_join3_log (branch) VALUES (''A'')',
        'INSERT INTO test_join3_log (branch) VALUES (''B'')',
        'INSERT INTO test_join3_log (branch) VALUES (''C'')'
    ),
    'scenario-join3'
);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    branch_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing join3: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO inst_status;

    IF inst_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: join3 status = %', inst_status;
    END IF;
    
    SELECT COUNT(DISTINCT branch) INTO branch_count FROM test_join3_log;
    IF branch_count != 3 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 3 branches, got %', branch_count;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_join3';
END $$;

DROP TABLE _test_state;
DROP TABLE test_join3_log;

-- === Test: 17_race ===

DROP TABLE IF EXISTS test_race_log;
CREATE TABLE test_race_log (id SERIAL, branch TEXT, variant TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Test A: df.race() function - fast vs slow
INSERT INTO _test_state SELECT df.start(
    df.race(
        'INSERT INTO test_race_log (branch, variant) VALUES (''fast'', ''func'') RETURNING ''fast''',
        df.sleep(10) ~> 'INSERT INTO test_race_log (branch, variant) VALUES (''slow'', ''func'') RETURNING ''slow'''
    ),
    'test-race-func'
), 'func';

-- Test B: | operator - fast vs slow
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_race_log (branch, variant) VALUES (''fast'', ''op'') RETURNING ''fast'''
    | (df.sleep(10) ~> 'INSERT INTO test_race_log (branch, variant) VALUES (''slow'', ''op'') RETURNING ''slow'''),
    'test-race-op'
), 'op';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;

        SELECT COUNT(*) INTO cnt FROM test_race_log WHERE variant = rec.variant AND branch = 'fast';
        IF cnt < 1 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: fast branch should have completed', rec.variant;
        END IF;
    END LOOP;

    RAISE NOTICE 'PASSED: race [func + | operator]';
END $$;

DROP TABLE _test_state;
DROP TABLE test_race_log;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
