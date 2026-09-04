-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_loop_continue_attempts;
CREATE TABLE test_loop_continue_attempts (
    id SERIAL PRIMARY KEY,
    scenario TEXT NOT NULL
);

CREATE TEMP TABLE _loop_continue_instances (
    scenario TEXT PRIMARY KEY,
    instance_id TEXT NOT NULL
);

INSERT INTO _loop_continue_instances
SELECT 'continue',
       df.start(
           df.loop(
               $$INSERT INTO test_loop_continue_attempts(scenario)
                   VALUES ('continue')$$
               ~> df.if(
                   $$SELECT count(*) = 1
                       FROM test_loop_continue_attempts
                       WHERE scenario = 'continue'$$,
                   'SELECT 1 / 0',
                   df.break('"completed-after-failure"')
               ),
               continue_on_failure => true
           ),
           'test-loop-continue-on-failure'
       );

INSERT INTO _loop_continue_instances
SELECT 'fail-fast',
       df.start(
           df.loop('SELECT 1 / 0', continue_on_failure => false),
           'test-loop-explicit-fail-fast'
       );

DO $$
DECLARE
    continued_status TEXT;
    failed_status TEXT;
    attempts INT;
    continued_explain TEXT;
BEGIN
    SELECT df.await_instance(instance_id, 30)
    INTO continued_status
    FROM _loop_continue_instances
    WHERE scenario = 'continue';

    SELECT df.await_instance(instance_id, 30)
    INTO failed_status
    FROM _loop_continue_instances
    WHERE scenario = 'fail-fast';

    SELECT count(*) INTO attempts
    FROM test_loop_continue_attempts
    WHERE scenario = 'continue';

    SELECT df.explain(instance_id) INTO continued_explain
    FROM _loop_continue_instances
    WHERE scenario = 'continue';

    IF continued_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION
            'TEST FAILED [continue]: expected completed, got %',
            continued_status;
    END IF;
    IF failed_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION
            'TEST FAILED [fail-fast]: expected failed, got %',
            failed_status;
    END IF;
    IF attempts <> 2 THEN
        RAISE EXCEPTION
            'TEST FAILED [continue]: expected exactly two isolated iterations, got %',
            attempts;
    END IF;
    IF continued_explain NOT LIKE '%LOOP (infinite, continue on failure)%' THEN
        RAISE EXCEPTION
            'TEST FAILED [continue]: df.explain() omitted loop policy: %',
            continued_explain;
    END IF;
END $$;

DROP TABLE _loop_continue_instances;
DROP TABLE test_loop_continue_attempts;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
