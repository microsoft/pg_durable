-- Test: Multi-database support
--
-- Validates that df.start() can target a specific database on the cluster
-- using the optional `database` parameter.
--
-- Must run as superuser because it creates/drops a database.
--
-- Tests:
-- 1. df.start() with database => works and executes SQL in the target database
-- 2. df.start() with database => 'nonexistent' raises an immediate error
-- 3. df.start() without database parameter (regression) still works
-- 4. Multi-node sequence graph targeting another database
-- 5. Database dropped after df.start() — deferred connection failure

CREATE EXTENSION IF NOT EXISTS dblink;

-- ============================================================================
-- Test 1: Execute durable function in a different database
-- ============================================================================

DROP DATABASE IF EXISTS _test_multi_db;
CREATE DATABASE _test_multi_db;
GRANT CONNECT ON DATABASE _test_multi_db TO df_e2e_user;

-- Create a test table in the target database and grant access to df_e2e_user
SELECT dblink_exec(
    format('host=localhost dbname=_test_multi_db port=%s user=postgres', current_setting('port')),
    'CREATE TABLE test_multi (id INT, value TEXT)'
);
SELECT dblink_exec(
    format('host=localhost dbname=_test_multi_db port=%s user=postgres', current_setting('port')),
    'GRANT ALL ON test_multi TO df_e2e_user'
);

-- Submit durable function as df_e2e_user targeting _test_multi_db
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

-- Verify the row exists in _test_multi_db
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

-- Verify the database column is set on the instance and nodes
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

-- ============================================================================
-- Test 2: Invalid database raises immediate error
-- ============================================================================

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
        -- Should not reach here
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

-- ============================================================================
-- Test 3: Regression - df.start() without database still works
-- ============================================================================

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

-- ============================================================================
-- Test 4: Multi-node sequence graph targeting another database
-- ============================================================================

-- Insert a second row and update it in sequence, all in the target database
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

    -- Verify all nodes in the graph have the database field set
    SELECT COUNT(*), COUNT(database) INTO node_count, nodes_with_db
    FROM df.nodes WHERE instance_id = inst_id;

    IF node_count != nodes_with_db THEN
        RAISE EXCEPTION 'TEST FAILED [multi-node seq]: only %/% nodes have database set', nodes_with_db, node_count;
    END IF;

    RAISE NOTICE 'PASSED: multi-node sequence completed (% nodes, all with database)', node_count;
END $$;

-- Verify the rows in _test_multi_db
DO $$
DECLARE
    connstr TEXT;
    row_val TEXT;
    row_cnt INT;
BEGIN
    connstr := format(
        'host=localhost dbname=_test_multi_db port=%s user=postgres',
        current_setting('port')
    );

    -- id=10 should have been updated to 'step2'
    SELECT val INTO row_val
    FROM dblink(connstr, 'SELECT value FROM test_multi WHERE id = 10')
         AS t(val TEXT);
    IF row_val != 'step2' THEN
        RAISE EXCEPTION 'TEST FAILED [multi-node seq verify]: id=10 expected step2, got %', row_val;
    END IF;

    -- id=11 should exist with 'step3'
    SELECT val INTO row_val
    FROM dblink(connstr, 'SELECT value FROM test_multi WHERE id = 11')
         AS t(val TEXT);
    IF row_val != 'step3' THEN
        RAISE EXCEPTION 'TEST FAILED [multi-node seq verify]: id=11 expected step3, got %', row_val;
    END IF;

    RAISE NOTICE 'PASSED: multi-node sequence results verified in target database';
END $$;

DROP TABLE _test_state3;

-- ============================================================================
-- Test 5: Database dropped after df.start() — deferred connection failure
-- ============================================================================

-- Create a temporary database, start a loop targeting it, then drop it
-- to verify the worker produces a clean 'failed' status.

DROP DATABASE IF EXISTS _test_drop_db;
CREATE DATABASE _test_drop_db;
GRANT CONNECT ON DATABASE _test_drop_db TO df_e2e_user;

-- Create a table in the target database so the first iteration can succeed
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

-- Give the first iteration time to start
SELECT pg_sleep(3);

-- Drop the database (terminate existing connections first)
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = '_test_drop_db' AND pid != pg_backend_pid();
DROP DATABASE IF EXISTS _test_drop_db;

-- Wait for the instance to fail (loop should fail on next iteration)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state4;

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [drop-db]: expected failed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED: deferred connection failure produced clean failed status';
END $$;

DROP TABLE _test_state4;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP DATABASE IF EXISTS _test_multi_db;

SELECT 'TEST PASSED' AS result;
