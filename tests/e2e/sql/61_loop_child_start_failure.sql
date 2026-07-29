-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- A non-root loop child that fails before its first status stamp must still leave
-- the LOOP node terminal. Removing the submitting role after the parent loads the
-- graph makes the child's graph reload fail deterministically.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loop_child_start_user') THEN
        DROP OWNED BY loop_child_start_user;
        DROP ROLE loop_child_start_user;
    END IF;
END $$;
CREATE ROLE loop_child_start_user LOGIN;
SELECT df.grant_usage('loop_child_start_user');

DROP TABLE IF EXISTS test_loop_child_start_log;
CREATE TABLE test_loop_child_start_log (marker INT);
GRANT INSERT ON test_loop_child_start_log TO loop_child_start_user;

CREATE TEMP TABLE _loop_child_start_instance (instance_id TEXT);
GRANT INSERT ON _loop_child_start_instance TO loop_child_start_user;

SET SESSION AUTHORIZATION loop_child_start_user;
INSERT INTO _loop_child_start_instance
SELECT df.start(
    'INSERT INTO test_loop_child_start_log VALUES (1)'
    ~> df.sleep(3)
    ~> df.loop('SELECT 1', 'SELECT false'),
    'test-loop-child-start-failure'
);
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    attempts INT := 0;
BEGIN
    WHILE NOT EXISTS (SELECT 1 FROM test_loop_child_start_log) LOOP
        IF attempts >= 100 THEN
            RAISE EXCEPTION 'TEST FAILED [loop-child-start]: prefix did not execute';
        END IF;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
END $$;

DROP OWNED BY loop_child_start_user;
DROP ROLE loop_child_start_user;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    loop_status TEXT;
    loop_inferred_status TEXT;
BEGIN
    SELECT i.instance_id INTO instance_id FROM _loop_child_start_instance i;
    SELECT df.await_instance(instance_id, 30) INTO final_status;

    IF final_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-child-start]: expected failed instance, got %', final_status;
    END IF;

    SELECT n.status, n.inferred_status
    INTO loop_status, loop_inferred_status
    FROM df.instance_nodes(instance_id) n
    WHERE n.node_type = 'LOOP';

    IF loop_status IS DISTINCT FROM 'failed' OR loop_inferred_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-child-start]: expected failed LOOP node, got physical %, inferred %',
            loop_status, loop_inferred_status;
    END IF;

    IF df.explain(instance_id) LIKE '%LOOP%pending%' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-child-start]: df.explain() left LOOP node pending: %',
            df.explain(instance_id);
    END IF;
END $$;

DROP TABLE _loop_child_start_instance;
DROP TABLE test_loop_child_start_log;
SELECT 'TEST PASSED' AS result;