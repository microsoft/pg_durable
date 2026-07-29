-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Replay-recorded vars and named results must serialize canonically across JOIN and loop children.
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_loop_ordering_log;
CREATE TABLE test_loop_ordering_log (
    iteration INT,
    left_value TEXT,
    right_value TEXT,
    first_var TEXT,
    second_var TEXT
);

SELECT df.clearvars();
SELECT df.setvar('second_var', 'var-b');
SELECT df.setvar('first_var', 'var-a');

CREATE TEMP TABLE _loop_ordering_instance AS
SELECT df.start(
    df.seq(
        ('SELECT ''left'' AS value' |=> 'z_left')
        & ('SELECT ''right'' AS value' |=> 'a_right'),
        df.loop(
            $$INSERT INTO test_loop_ordering_log
                (iteration, left_value, right_value, first_var, second_var)
              SELECT
                (SELECT COUNT(*) + 1 FROM test_loop_ordering_log),
                $z_left,
                $a_right,
                '{first_var}',
                '{second_var}'$$
            ~> (
                'SELECT COUNT(*) >= 2 FROM test_loop_ordering_log'
                    ?> df.break('ordered')
                    !> df.sleep(1)
            )
        )
    ),
    'test-loop-child-result-ordering'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    bad_rows INT;
BEGIN
    SELECT l.instance_id INTO instance_id FROM _loop_ordering_instance l;
    SELECT df.await_instance(instance_id, 30) INTO final_status;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-child-ordering]: expected completed, got %', final_status;
    END IF;

    SELECT COUNT(*) INTO bad_rows
    FROM test_loop_ordering_log
    WHERE left_value IS DISTINCT FROM 'left'
       OR right_value IS DISTINCT FROM 'right'
       OR first_var IS DISTINCT FROM 'var-a'
       OR second_var IS DISTINCT FROM 'var-b';

    IF (SELECT COUNT(*) FROM test_loop_ordering_log) != 2 OR bad_rows != 0 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-child-ordering]: expected two canonical rows, bad rows = %', bad_rows;
    END IF;
END $$;

DROP TABLE _loop_ordering_instance;
DROP TABLE test_loop_ordering_log;
SELECT df.clearvars();
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
