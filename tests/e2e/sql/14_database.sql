-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 29_database_validation, 34_multi_database
-- Tests: CREATE EXTENSION rejected in wrong database, workflows execute in correct database,
--        df.start() with explicit database parameter, invalid database rejection,
--        multi-node sequence in another database, dropped database failure handling
-- Runs as postgres throughout (creates/drops databases)

-- === Test: 29_database_validation ===

CREATE EXTENSION IF NOT EXISTS dblink;

-- Verify we're running in the correct database
DO $$
DECLARE
    current_db TEXT;
    target_db TEXT;
BEGIN
    SELECT current_database() INTO current_db;
    SELECT df.target_database() INTO target_db;
    
    IF current_db != target_db THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: This test must run in database "%" (currently in "%")', target_db, current_db;
    END IF;
    
    RAISE NOTICE 'Test running in correct database: %', current_db;
END $$;

-- Test 1: CREATE EXTENSION should succeed in the correct database
SELECT public._e2e_drop_extension_safe();
CREATE EXTENSION pg_durable;

SELECT df.grant_usage('df_e2e_user');

SELECT public._e2e_wait_for_worker_ready();

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_durable') THEN
        RAISE EXCEPTION 'TEST FAILED: Extension should exist in correct database';
    END IF;
    RAISE NOTICE 'PASSED: CREATE EXTENSION succeeded in correct database';
END $$;

-- Test 2: Verify workflows can execute (BGW is connected to this database)
CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state
SELECT df.start('SELECT 42 as answer', 'test-correct-db');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Workflow should complete in correct database, got status: %', status;
    END IF;
    
    RAISE NOTICE 'PASSED: Workflow executed successfully in correct database';
END $$;

DROP TABLE _test_state;

-- Test 3: CREATE EXTENSION must fail in a wrong database
DROP DATABASE IF EXISTS _test_wrong_db;
CREATE DATABASE _test_wrong_db;

DO $$
DECLARE
    connstr TEXT;
    err_msg TEXT;
BEGIN
    connstr := format(
        'host=localhost dbname=_test_wrong_db port=%s user=postgres',
        current_setting('port')
    );

    BEGIN
        PERFORM dblink_exec(connstr, 'CREATE EXTENSION pg_durable;');
        RAISE EXCEPTION 'TEST FAILED: CREATE EXTENSION should have been rejected in wrong database';
    EXCEPTION WHEN OTHERS THEN
        err_msg := SQLERRM;
    END;

    IF err_msg NOT ILIKE '%must be created in database%' THEN
        RAISE EXCEPTION 'TEST FAILED: Expected "must be created in database" in error, got: %', err_msg;
    END IF;
    IF err_msg NOT ILIKE '%_test_wrong_db%' THEN
        RAISE EXCEPTION 'TEST FAILED: Expected wrong db name in error, got: %', err_msg;
    END IF;

    RAISE NOTICE 'PASSED: CREATE EXTENSION correctly rejected in wrong database';
    RAISE NOTICE 'Error was: %', err_msg;
END $$;

DROP DATABASE IF EXISTS _test_wrong_db;

-- === Test: 34_multi_database ===

-- Test 1: Execute durable function in a different database
DROP DATABASE IF EXISTS _test_multi_db;
CREATE DATABASE _test_multi_db;
GRANT CONNECT ON DATABASE _test_multi_db TO df_e2e_user;

SELECT dblink_exec(
    format('host=localhost dbname=_test_multi_db port=%s user=postgres', current_setting('port')),
    'CREATE TABLE test_multi (id INT, value TEXT)'
);
SELECT dblink_exec(
    format('host=localhost dbname=_test_multi_db port=%s user=postgres', current_setting('port')),
    'GRANT ALL ON test_multi TO df_e2e_user'
);

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_multi VALUES (1, ''hello from multi-db'')',
    'test-multi-db',
    '_test_multi_db'
);

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [multi-db]: status = %', status;
    END IF;

    RAISE NOTICE 'PASSED: durable function completed in target database';
END $$;

DO $$
DECLARE
    connstr TEXT;
    row_value TEXT;
BEGIN
    connstr := format(
        'host=localhost dbname=_test_multi_db port=%s user=postgres',
        current_setting('port')
    );

    SELECT val INTO row_value
    FROM dblink(connstr, 'SELECT value FROM test_multi WHERE id = 1')
         AS t(val TEXT);

    IF row_value IS NULL OR row_value != 'hello from multi-db' THEN
        RAISE EXCEPTION 'TEST FAILED [multi-db verify]: expected ''hello from multi-db'', got %', row_value;
    END IF;

    RAISE NOTICE 'PASSED: verified row exists in target database: %', row_value;
END $$;

DO $$
DECLARE
    inst_id TEXT;
    inst_db TEXT;
    node_db TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;

    SELECT database INTO inst_db FROM df.instances WHERE id = inst_id;
    IF inst_db != '_test_multi_db' THEN
        RAISE EXCEPTION 'TEST FAILED [instance.database]: expected _test_multi_db, got %', inst_db;
    END IF;

    SELECT database INTO node_db FROM df.nodes WHERE instance_id = inst_id LIMIT 1;
    IF node_db != '_test_multi_db' THEN
        RAISE EXCEPTION 'TEST FAILED [node.database]: expected _test_multi_db, got %', node_db;
    END IF;

    RAISE NOTICE 'PASSED: database column correctly set on instance and nodes';
END $$;

DROP TABLE _test_state;

-- Test 2: Invalid database raises immediate error
SET SESSION AUTHORIZATION df_e2e_user;

DO $$
DECLARE
    err_msg TEXT;
BEGIN
    BEGIN
        PERFORM df.start(
            'SELECT 1',
            'test-bad-db',
            'nonexistent_database_abc'
        );
        RAISE EXCEPTION 'TEST FAILED: df.start() should have errored for nonexistent database';
    EXCEPTION WHEN OTHERS THEN
        err_msg := SQLERRM;
    END;

    IF err_msg NOT ILIKE '%nonexistent_database_abc%' THEN
        RAISE EXCEPTION 'TEST FAILED [invalid db]: expected error about nonexistent_database_abc, got: %', err_msg;
    END IF;
    IF err_msg NOT ILIKE '%does not exist%' THEN
        RAISE EXCEPTION 'TEST FAILED [invalid db]: expected "does not exist" in error, got: %', err_msg;
    END IF;

    RAISE NOTICE 'PASSED: invalid database correctly rejected: %', err_msg;
END $$;

RESET SESSION AUTHORIZATION;

-- Test 3: Regression - df.start() without database still works
SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _test_state2 (instance_id TEXT);

INSERT INTO _test_state2 SELECT df.start(
    'SELECT 99 as answer',
    'test-no-db'
);

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    inst_db TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state2;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [regression]: status = %', status;
    END IF;

    SELECT database INTO inst_db FROM df.instances WHERE id = inst_id;
    IF inst_db IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED [regression]: database should be NULL, got %', inst_db;
    END IF;

    RAISE NOTICE 'PASSED: regression test - df.start() without database works';
END $$;

DROP TABLE _test_state2;

-- Test 4: Multi-node sequence graph targeting another database
SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _test_state3 (instance_id TEXT);
INSERT INTO _test_state3 SELECT df.start(
    'INSERT INTO test_multi VALUES (10, ''step1'')'
    ~> 'UPDATE test_multi SET value = ''step2'' WHERE id = 10'
    ~> 'INSERT INTO test_multi VALUES (11, ''step3'')',
    'test-multi-db-seq',
    '_test_multi_db'
);

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_count INT;
    nodes_with_db INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state3;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [multi-node seq]: status = %', status;
    END IF;

    SELECT COUNT(*), COUNT(database) INTO node_count, nodes_with_db
    FROM df.nodes WHERE instance_id = inst_id;

    IF node_count != nodes_with_db THEN
        RAISE EXCEPTION 'TEST FAILED [multi-node seq]: only %/% nodes have database set', nodes_with_db, node_count;
    END IF;

    RAISE NOTICE 'PASSED: multi-node sequence completed (% nodes, all with database)', node_count;
END $$;

DO $$
DECLARE
    connstr TEXT;
    row_val TEXT;
BEGIN
    connstr := format(
        'host=localhost dbname=_test_multi_db port=%s user=postgres',
        current_setting('port')
    );

    SELECT val INTO row_val
    FROM dblink(connstr, 'SELECT value FROM test_multi WHERE id = 10')
         AS t(val TEXT);
    IF row_val != 'step2' THEN
        RAISE EXCEPTION 'TEST FAILED [multi-node seq verify]: id=10 expected step2, got %', row_val;
    END IF;

    SELECT val INTO row_val
    FROM dblink(connstr, 'SELECT value FROM test_multi WHERE id = 11')
         AS t(val TEXT);
    IF row_val != 'step3' THEN
        RAISE EXCEPTION 'TEST FAILED [multi-node seq verify]: id=11 expected step3, got %', row_val;
    END IF;

    RAISE NOTICE 'PASSED: multi-node sequence results verified in target database';
END $$;

DROP TABLE _test_state3;

-- Test 5: Database dropped after df.start() — deferred connection failure
DROP DATABASE IF EXISTS _test_drop_db;
CREATE DATABASE _test_drop_db;
GRANT CONNECT ON DATABASE _test_drop_db TO df_e2e_user;

SELECT dblink_exec(
    format('host=localhost dbname=_test_drop_db port=%s user=postgres', current_setting('port')),
    'CREATE TABLE drop_test (id SERIAL, ts TIMESTAMP DEFAULT now())'
);
SELECT dblink_exec(
    format('host=localhost dbname=_test_drop_db port=%s user=postgres', current_setting('port')),
    'GRANT ALL ON drop_test TO df_e2e_user'
);
SELECT dblink_exec(
    format('host=localhost dbname=_test_drop_db port=%s user=postgres', current_setting('port')),
    'GRANT USAGE, SELECT ON SEQUENCE drop_test_id_seq TO df_e2e_user'
);

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _test_state4 (instance_id TEXT);
INSERT INTO _test_state4 SELECT df.start(
    df.loop(
        'INSERT INTO drop_test (id) VALUES (DEFAULT)' ~> df.sleep(2)
    ),
    'test-drop-db-loop',
    '_test_drop_db'
);

RESET SESSION AUTHORIZATION;

SELECT pg_sleep(3);

SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = '_test_drop_db' AND pid != pg_backend_pid();
DROP DATABASE IF EXISTS _test_drop_db;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state4;

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [drop-db]: expected failed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED: deferred connection failure produced clean failed status';
END $$;

DROP TABLE _test_state4;

-- Cleanup
DROP DATABASE IF EXISTS _test_multi_db;

SELECT 'TEST PASSED' AS result;
