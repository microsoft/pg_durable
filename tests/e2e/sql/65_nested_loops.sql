-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Three outer iterations each spawn an inner loop that runs twice. The outer
-- row id is carried as a named result into the nested child so ordering and
-- result propagation are both observable.
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_nested_loop_outer;
DROP TABLE IF EXISTS test_nested_loop_inner;
CREATE TABLE test_nested_loop_outer (outer_iteration SERIAL PRIMARY KEY);
CREATE TABLE test_nested_loop_inner (
    sequence_no SERIAL PRIMARY KEY,
    outer_iteration INT NOT NULL,
    inner_iteration INT NOT NULL
);

CREATE TEMP TABLE _nested_loop_instance AS
SELECT df.start(
    'SELECT 1'
    ~> df.loop(
        ($$INSERT INTO test_nested_loop_outer DEFAULT VALUES
           RETURNING outer_iteration$$ |=> 'outer_row')
        ~> df.loop(
                        $$INSERT INTO test_nested_loop_inner (outer_iteration, inner_iteration)
                            SELECT $outer_row.outer_iteration, COUNT(*) + 1
                            FROM test_nested_loop_inner
                            WHERE outer_iteration = $outer_row.outer_iteration$$,
                        $$SELECT COUNT(*) < 2
                            FROM test_nested_loop_inner
                            WHERE outer_iteration = $outer_row.outer_iteration$$
        )
        ~> (
            'SELECT COUNT(*) >= 3 FROM test_nested_loop_outer'
                ?> df.break('done')
                !> df.sleep(1)
        )
    ),
    'test-nested-loops'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    execution_order TEXT[];
    pending_count INT;
BEGIN
    SELECT i.instance_id INTO instance_id FROM _nested_loop_instance i;
    SELECT df.await_instance(instance_id, 90) INTO final_status;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [nested-loops]: expected completed, got %', final_status;
    END IF;

    SELECT array_agg(format('%s.%s', outer_iteration, inner_iteration) ORDER BY sequence_no)
    INTO execution_order
    FROM test_nested_loop_inner;

    IF execution_order IS DISTINCT FROM ARRAY['1.1', '1.2', '2.1', '2.2', '3.1', '3.2'] THEN
        RAISE EXCEPTION 'TEST FAILED [nested-loops]: unexpected execution order %', execution_order;
    END IF;

    SELECT count(*) INTO pending_count
    FROM df.instance_nodes(instance_id)
    WHERE inferred_status IN ('pending', 'running');

    IF pending_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED [nested-loops]: % node(s) remain pending/running after completion', pending_count;
    END IF;
END $$;

DROP TABLE _nested_loop_instance;
DROP TABLE test_nested_loop_inner;
DROP TABLE test_nested_loop_outer;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
