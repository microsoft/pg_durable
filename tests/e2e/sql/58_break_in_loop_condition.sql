-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Regression: df.break() in a while-condition must have identical root and non-root semantics.
SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _break_condition_instances (
    position TEXT PRIMARY KEY,
    instance_id TEXT NOT NULL
);

INSERT INTO _break_condition_instances
SELECT 'root', df.start(
    df.loop(
        'SELECT ''body''',
        'SELECT 1' ~> df.break('condition-done')
    ),
    'test-root-break-in-condition'
);

INSERT INTO _break_condition_instances
SELECT 'non-root', df.start(
    'SELECT ''prefix''' ~> df.loop(
        'SELECT ''body''',
        'SELECT 1' ~> df.break('condition-done')
    ),
    'test-nonroot-break-in-condition'
);

DO $$
DECLARE
    rec RECORD;
    final_status TEXT;
    final_result TEXT;
    loop_result TEXT;
BEGIN
    FOR rec IN SELECT position, instance_id FROM _break_condition_instances ORDER BY position LOOP
        SELECT df.await_instance(rec.instance_id, 30) INTO final_status;
        SELECT df.result(rec.instance_id) INTO final_result;

        IF final_status IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [% break in condition]: expected completed, got %',
                rec.position, final_status;
        END IF;

        IF final_result IS DISTINCT FROM '"condition-done"' THEN
            RAISE EXCEPTION 'TEST FAILED [% break in condition]: expected result %, got %',
                rec.position, '"condition-done"', final_result;
        END IF;

        SELECT result INTO loop_result
        FROM df.nodes
        WHERE instance_id = rec.instance_id AND node_type = 'LOOP';

        IF loop_result IS DISTINCT FROM '"condition-done"' THEN
            RAISE EXCEPTION 'TEST FAILED [% break in condition]: expected loop-node result %, got %',
                rec.position, '"condition-done"', loop_result;
        END IF;
    END LOOP;
END $$;

DROP TABLE _break_condition_instances;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
