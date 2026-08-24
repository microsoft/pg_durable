-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- A loop running directly as a JOIN branch must propagate its body failure
-- through the child boundary while leaving both the loop node and parent
-- instance terminal. The sibling branch is allowed to finish independently.
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_loop_branch_failure_iterations;
DROP TABLE IF EXISTS test_loop_branch_failure_sibling;
CREATE TABLE test_loop_branch_failure_iterations (iteration INT PRIMARY KEY);
CREATE TABLE test_loop_branch_failure_sibling (marker INT);

CREATE TEMP TABLE _loop_branch_failure_instance AS
SELECT df.start(
    df.loop(
        $$INSERT INTO test_loop_branch_failure_iterations
            SELECT COUNT(*) + 1 FROM test_loop_branch_failure_iterations$$
        ~> df.if(
            'SELECT COUNT(*) >= 2 FROM test_loop_branch_failure_iterations',
            'SELECT 1/0',
            df.sleep(1)
        )
    )
    & 'INSERT INTO test_loop_branch_failure_sibling VALUES (1)',
    'test-loop-branch-failure',
    max_attempts => 1,
    on_failure => 'fail'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    instance_output TEXT;
    loop_status TEXT;
    loop_inferred_status TEXT;
    loop_result TEXT;
    iteration_count INT;
    sibling_count INT;
BEGIN
    SELECT i.instance_id INTO instance_id FROM _loop_branch_failure_instance i;
    SELECT df.await_instance(instance_id, 60) INTO final_status;

    IF final_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-branch-failure]: expected failed instance, got %', final_status;
    END IF;

    SELECT count(*) INTO iteration_count FROM test_loop_branch_failure_iterations;
    SELECT count(*) INTO sibling_count FROM test_loop_branch_failure_sibling;
    IF iteration_count != 2 OR sibling_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-branch-failure]: expected 2 loop iterations and 1 sibling write, got % / %',
            iteration_count, sibling_count;
    END IF;

    SELECT n.status, n.inferred_status, n.result
    INTO loop_status, loop_inferred_status, loop_result
    FROM df.instance_nodes(instance_id) n
    WHERE n.node_type = 'LOOP';

    IF loop_status IS DISTINCT FROM 'failed' OR loop_inferred_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-branch-failure]: LOOP node physical/inferred status = % / %',
            loop_status, loop_inferred_status;
    END IF;

    SELECT output INTO instance_output FROM df.instance_info(instance_id);
    IF COALESCE(instance_output, loop_result, '') NOT LIKE '%division by zero%' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-branch-failure]: original SQL error did not surface: instance %, loop %',
            instance_output, loop_result;
    END IF;
END $$;

DROP TABLE _loop_branch_failure_instance;
DROP TABLE test_loop_branch_failure_iterations;
DROP TABLE test_loop_branch_failure_sibling;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
