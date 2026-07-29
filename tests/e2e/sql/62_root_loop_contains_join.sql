-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Regression for issue #230: a root loop containing a JOIN must use fresh child
-- orchestration state on every continue-as-new generation.
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_root_loop_join_left;
DROP TABLE IF EXISTS test_root_loop_join_right;
CREATE TABLE test_root_loop_join_left (iteration INT PRIMARY KEY);
CREATE TABLE test_root_loop_join_right (iteration INT PRIMARY KEY);

CREATE TEMP TABLE _root_loop_join_instance AS
SELECT df.start(
    df.loop(
        (
            $$INSERT INTO test_root_loop_join_left
                SELECT COUNT(*) + 1 FROM test_root_loop_join_left$$
            &
            $$INSERT INTO test_root_loop_join_right
                SELECT COUNT(*) + 1 FROM test_root_loop_join_right$$
        )
        ~> (
            'SELECT COUNT(*) >= 3 FROM test_root_loop_join_left'
                ?> df.break('done')
                !> df.sleep(1)
        )
    ),
    'test-root-loop-contains-join'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    left_iterations INT[];
    right_iterations INT[];
BEGIN
    SELECT i.instance_id INTO instance_id FROM _root_loop_join_instance i;
    SELECT df.await_instance(instance_id, 60) INTO final_status;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [root-loop-join]: expected completed, got %', final_status;
    END IF;

    SELECT array_agg(iteration ORDER BY iteration)
    INTO left_iterations
    FROM test_root_loop_join_left;

    SELECT array_agg(iteration ORDER BY iteration)
    INTO right_iterations
    FROM test_root_loop_join_right;

    IF left_iterations IS DISTINCT FROM ARRAY[1, 2, 3] THEN
        RAISE EXCEPTION 'TEST FAILED [root-loop-join]: expected left iterations {1,2,3}, got %', left_iterations;
    END IF;

    IF right_iterations IS DISTINCT FROM ARRAY[1, 2, 3] THEN
        RAISE EXCEPTION 'TEST FAILED [root-loop-join]: expected right iterations {1,2,3}, got %', right_iterations;
    END IF;
END $$;

DROP TABLE _root_loop_join_instance;
DROP TABLE test_root_loop_join_left;
DROP TABLE test_root_loop_join_right;

-- A root loop containing a RACE exercises the same generation boundary with
-- select cancellation rather than join completion.
DROP TABLE IF EXISTS test_root_loop_race_iterations;
DROP TABLE IF EXISTS test_root_loop_race_winners;
CREATE TABLE test_root_loop_race_iterations (iteration INT PRIMARY KEY);
CREATE TABLE test_root_loop_race_winners (iteration INT PRIMARY KEY);

CREATE TEMP TABLE _root_loop_race_instance AS
SELECT df.start(
    df.loop(
        $$INSERT INTO test_root_loop_race_iterations
            SELECT COUNT(*) + 1 FROM test_root_loop_race_iterations$$
        ~> df.race(
            $$INSERT INTO test_root_loop_race_winners
                SELECT COUNT(*) FROM test_root_loop_race_iterations$$,
            df.sleep(30)
        )
        ~> (
            'SELECT COUNT(*) >= 3 FROM test_root_loop_race_iterations'
                ?> df.break('done')
                !> df.sleep(1)
        )
    ),
    'test-root-loop-contains-race'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    iterations INT[];
    winners INT[];
BEGIN
    SELECT i.instance_id INTO instance_id FROM _root_loop_race_instance i;
    SELECT df.await_instance(instance_id, 60) INTO final_status;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [root-loop-race]: expected completed, got %', final_status;
    END IF;

    SELECT array_agg(iteration ORDER BY iteration)
    INTO iterations
    FROM test_root_loop_race_iterations;

    SELECT array_agg(iteration ORDER BY iteration)
    INTO winners
    FROM test_root_loop_race_winners;

    IF iterations IS DISTINCT FROM ARRAY[1, 2, 3] OR winners IS DISTINCT FROM ARRAY[1, 2, 3] THEN
        RAISE EXCEPTION 'TEST FAILED [root-loop-race]: expected iterations/winners {1,2,3}, got % / %',
            iterations, winners;
    END IF;
END $$;

DROP TABLE _root_loop_race_instance;
DROP TABLE test_root_loop_race_iterations;
DROP TABLE test_root_loop_race_winners;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;