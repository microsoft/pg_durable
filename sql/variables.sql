-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: Variable substitution using |=> operator and df.as() function
SET ROLE df_regress_user;
DROP TABLE IF EXISTS test_vars_log;
CREATE TABLE test_vars_log (id SERIAL, val TEXT, variant TEXT);

-- Test A: Using |=> operator
SELECT df.start(
    'SELECT 100 as num' |=> 'x'
    ~> 'INSERT INTO test_vars_log (val, variant) VALUES ($x::text, ''op'')',
    'test-variables-op'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Test B: Using df.as() function
SELECT df.start(
    df.seq(
        df.as('SELECT 200 as num', 'y'),
        'INSERT INTO test_vars_log (val, variant) VALUES ($y::text, ''fn'')'
    ),
    'test-variables-fn'
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify results (deterministic output, ordered by id)
SELECT val, variant FROM test_vars_log ORDER BY id;

-- Cleanup
DROP TABLE test_vars_log;
