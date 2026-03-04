-- Test: Sequential execution using ~> operator and df.seq() function
DROP TABLE IF EXISTS test_sequence_log;
CREATE TABLE test_sequence_log (id SERIAL, step INT, variant TEXT);

-- Test A: Using ~> operator
SELECT df.start(
    'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''op'')'
    ~> 'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''op'')',
    'test-sequence-op'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Test B: Using df.seq() function
SELECT df.start(
    df.seq(
        df.seq(
            'INSERT INTO test_sequence_log (step, variant) VALUES (1, ''fn'')',
            'INSERT INTO test_sequence_log (step, variant) VALUES (2, ''fn'')'
        ),
        'INSERT INTO test_sequence_log (step, variant) VALUES (3, ''fn'')'
    ),
    'test-sequence-fn'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify results (deterministic output, ordered by id)
SELECT step, variant FROM test_sequence_log ORDER BY id;

-- Cleanup
DROP TABLE test_sequence_log;
