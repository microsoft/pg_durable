-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: Conditional execution using df.if() and ?> !> operators
SET ROLE df_regress_user;
DROP TABLE IF EXISTS test_cond_log;
CREATE TABLE test_cond_log (id SERIAL, branch TEXT, variant TEXT);

-- Test A: df.if() with true condition (then branch executes)
SELECT df.start(
    df.if(
        'SELECT true',
        'INSERT INTO test_cond_log (branch, variant) VALUES (''then'', ''true-func'')',
        'INSERT INTO test_cond_log (branch, variant) VALUES (''else'', ''true-func'')'
    ),
    'test-cond-true-func'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Test B: ?> !> operators with true condition
SELECT df.start(
    'SELECT true' 
        ?> 'INSERT INTO test_cond_log (branch, variant) VALUES (''then'', ''true-op'')'
        !> 'INSERT INTO test_cond_log (branch, variant) VALUES (''else'', ''true-op'')',
    'test-cond-true-op'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Test C: df.if() with false condition (else branch executes)
SELECT df.start(
    df.if(
        'SELECT false',
        'INSERT INTO test_cond_log (branch, variant) VALUES (''then'', ''false-func'')',
        'INSERT INTO test_cond_log (branch, variant) VALUES (''else'', ''false-func'')'
    ),
    'test-cond-false-func'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Test D: ?> !> operators with false condition
SELECT df.start(
    'SELECT false'
        ?> 'INSERT INTO test_cond_log (branch, variant) VALUES (''then'', ''false-op'')'
        !> 'INSERT INTO test_cond_log (branch, variant) VALUES (''else'', ''false-op'')',
    'test-cond-false-op'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify results (deterministic output, ordered by id)
SELECT branch, variant FROM test_cond_log ORDER BY id;

-- Cleanup
DROP TABLE test_cond_log;
