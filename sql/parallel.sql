-- Test: Parallel execution with df.join() and & operator
DROP TABLE IF EXISTS test_parallel_log;
CREATE TABLE test_parallel_log (id SERIAL, branch TEXT, variant TEXT);

-- Test A: df.join() function
SELECT df.start(
    df.join(
        'INSERT INTO test_parallel_log (branch, variant) VALUES (''A'', ''func'')',
        'INSERT INTO test_parallel_log (branch, variant) VALUES (''B'', ''func'')'
    ),
    'test-parallel-func'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Test B: & operator
SELECT df.start(
    'INSERT INTO test_parallel_log (branch, variant) VALUES (''A'', ''op'')'
    & 'INSERT INTO test_parallel_log (branch, variant) VALUES (''B'', ''op'')',
    'test-parallel-op'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify results (deterministic output, ordered by branch then variant)
-- Both branches should have executed
SELECT branch, variant FROM test_parallel_log ORDER BY variant, branch;

-- Cleanup
DROP TABLE test_parallel_log;
