-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 29_database_validation, 34_multi_database
-- Tests: control and satellite installation, local APIs and transaction boundaries,
--        df.start() with explicit database parameter, invalid database rejection,
--        multi-node sequence in another database, dropped database failure handling
-- Database administration runs as postgres; normal workflows use df_e2e_user.

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

DROP DATABASE IF EXISTS _test_satellite_db WITH (FORCE);
CREATE DATABASE _test_satellite_db;

DO $$
DECLARE
    connstr TEXT := format('host=localhost dbname=_test_satellite_db port=%s user=postgres', current_setting('port'));
    installed BOOLEAN := false;
    schema_count INT;
BEGIN
    BEGIN
        PERFORM dblink_exec(connstr, 'CREATE EXTENSION pg_durable');
        installed := true;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT ILIKE '%control%' THEN
            RAISE EXCEPTION 'TEST FAILED [control absent]: unexpected install error: %', SQLERRM;
        END IF;
    END;
    IF installed THEN
        RAISE EXCEPTION 'TEST FAILED: satellite installed without a control installation';
    END IF;
    SELECT total INTO schema_count FROM dblink(connstr,
        'SELECT count(*) FROM pg_namespace WHERE nspname IN (''df'', ''_duroxide'', ''duroxide'')'
    ) AS remote(total INT);
    IF schema_count IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'TEST FAILED: rejected installation left schemas behind';
    END IF;
END $$;

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
SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state
SELECT df.start('SELECT 42 as answer', 'test-correct-db');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;

    SELECT df.await_instance(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Workflow should complete in correct database, got status: %', status;
    END IF;
    
    RAISE NOTICE 'PASSED: Workflow executed successfully in correct database';
END $$;

DROP TABLE _test_state;
RESET SESSION AUTHORIZATION;

-- Test 3: A satellite owns local metadata and uses the control runtime.
CREATE TEMP TABLE _control_epoch AS SELECT epoch_id FROM df._worker_epoch;
DROP TABLE IF EXISTS public.test_satellite_log;
CREATE TABLE public.test_satellite_log (
    marker TEXT PRIMARY KEY,
    value INT DEFAULT 0,
    db_name TEXT DEFAULT current_database(),
    role_name TEXT DEFAULT current_user
);
GRANT SELECT, INSERT, UPDATE ON public.test_satellite_log TO df_e2e_user;
SELECT df.grant_usage('df_e2e_user', include_http => true);

SELECT dblink_connect('satellite', format(
    'host=localhost dbname=_test_satellite_db port=%s user=postgres', current_setting('port')
));
SELECT dblink_exec('satellite', 'CREATE EXTENSION pg_durable');
SELECT dblink_exec('satellite', $remote$
    DO $check$
    BEGIN
        IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('_duroxide', 'duroxide')) THEN
            RAISE EXCEPTION 'TEST FAILED: satellite created a provider schema';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_class AS relation
            JOIN pg_extension AS extension ON extension.extname = 'pg_durable'
            JOIN pg_depend AS dependency ON dependency.objid = relation.oid
                AND dependency.classid = 'pg_class'::regclass
                AND dependency.refclassid = 'pg_extension'::regclass
                AND dependency.refobjid = extension.oid AND dependency.deptype = 'e'
            WHERE relation.oid = 'df._installation'::regclass
                AND relation.relowner = extension.extowner
        ) THEN
            RAISE EXCEPTION 'TEST FAILED: installation identity is not extension-owned';
        END IF;
        PERFORM df.grant_usage('df_e2e_user');
    END $check$;
    CREATE TABLE public.test_satellite_log (
        marker TEXT PRIMARY KEY,
        value INT DEFAULT 0,
        db_name TEXT DEFAULT current_database(),
        role_name TEXT DEFAULT current_user
    );
    GRANT SELECT, INSERT, UPDATE ON public.test_satellite_log TO df_e2e_user;
    SET SESSION AUTHORIZATION df_e2e_user;
    CREATE TEMP TABLE _satellite_state (name TEXT PRIMARY KEY, instance_id TEXT);
$remote$);

DO $$
DECLARE
    satellite_id UUID;
    control_id UUID;
BEGIN
    SELECT id INTO STRICT control_id FROM df._installation WHERE singleton;
    SELECT id INTO STRICT satellite_id FROM dblink('satellite',
        'SELECT id FROM df._installation WHERE singleton') AS remote(id UUID);
    IF satellite_id IS NULL OR satellite_id = control_id THEN
        RAISE EXCEPTION 'TEST FAILED: installations must have distinct non-null identities';
    END IF;
END $$;

SELECT dblink_exec('satellite', $remote$
    DO $check$ BEGIN PERFORM df.setvar('satellite_value', '42'); END $check$;
$remote$);

SELECT dblink_exec('satellite', $remote$
    DO $check$
    BEGIN
        IF (SELECT count(*) FROM df._installation) <> 1 OR
            has_table_privilege(current_user, 'df._installation', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
            RAISE EXCEPTION 'TEST FAILED: installation identity must be a read-only singleton';
        END IF;
        IF has_function_privilege(current_user, 'df.http(text,text,text,jsonb,integer)', 'EXECUTE') THEN
            RAISE EXCEPTION 'TEST FAILED: control HTTP grant leaked into satellite';
        END IF;
    END $check$;
    INSERT INTO _satellite_state SELECT 'native', df.start(
        'INSERT INTO public.test_satellite_log (marker, value) VALUES (''native'', {satellite_value})'
        ~> 'SELECT current_database()', 'test-satellite-native'
    );
$remote$);

SELECT dblink_exec('satellite', $remote$
    DO $check$
    DECLARE
        inst_id TEXT := (SELECT instance_id FROM _satellite_state WHERE name = 'native');
        status TEXT;
    BEGIN
        status := df.await_instance(inst_id, 30);
        IF status IS DISTINCT FROM 'completed' OR df.status(inst_id) IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [satellite native]: status = %', status;
        END IF;
        IF inst_id !~ '^[0-9a-f]{8}$' OR
            COALESCE(position('_test_satellite_db' IN df.result(inst_id)), 0) = 0 OR
            COALESCE(length(df.explain(inst_id)), 0) = 0 THEN
            RAISE EXCEPTION 'TEST FAILED: satellite public ID/result/explain';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM df.instance_info(inst_id) AS info
            WHERE info.instance_id = inst_id AND lower(info.status) = 'completed') OR
            NOT EXISTS (SELECT 1 FROM df.list_instances() AS info
            WHERE info.instance_id = inst_id AND lower(info.status) = 'completed') THEN
            RAISE EXCEPTION 'TEST FAILED: satellite info/list did not resolve local instance';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.test_satellite_log
            WHERE marker = 'native' AND value = 42 AND db_name = '_test_satellite_db'
                AND role_name = 'df_e2e_user') THEN
            RAISE EXCEPTION 'TEST FAILED: default target, captured vars, or execution role misrouted';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = inst_id AND node_type = 'SQL') OR
            EXISTS (SELECT 1 FROM df.nodes AS node WHERE node.instance_id = inst_id
                AND node.node_type = 'SQL' AND node.status IS DISTINCT FROM 'completed') THEN
            RAISE EXCEPTION 'TEST FAILED: satellite node statuses not updated';
        END IF;
    END $check$;
$remote$);

-- Keep the returned ID outside the transaction being rolled back.
SELECT dblink_exec('satellite', 'BEGIN');
CREATE TEMP TABLE _satellite_rolled_back AS
SELECT instance_id FROM dblink('satellite', $remote$
    SELECT df.start(
        'INSERT INTO public.test_satellite_log (marker) VALUES (''rolled-back'')',
        'test-satellite-rolled-back'
    )
$remote$) AS remote(instance_id TEXT);
SELECT dblink_exec('satellite', 'ROLLBACK');

SELECT dblink_exec('satellite', $remote$
    BEGIN;
    INSERT INTO public.test_satellite_log (marker) VALUES ('caller-new');
$remote$);
SELECT * FROM dblink('satellite', $remote$
    SELECT df.start(
        'INSERT INTO public.test_satellite_log (marker) VALUES (''independent'')',
        'test-satellite-independent', transaction_mode => 'new'
    )
$remote$) AS remote(instance_id TEXT);
SELECT dblink_exec('satellite', 'ROLLBACK');

SELECT dblink_exec('satellite', $remote$
    DO $check$
    DECLARE
        inst_id TEXT := (SELECT id FROM df.instances WHERE label = 'test-satellite-independent');
    BEGIN
        PERFORM df.await_instance(inst_id, 30);
        IF inst_id IS NULL OR df.status(inst_id) IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: satellite independent start did not survive rollback';
        END IF;
        IF EXISTS (SELECT 1 FROM public.test_satellite_log WHERE marker IN ('caller-new', 'rolled-back')) OR
            NOT EXISTS (SELECT 1 FROM public.test_satellite_log WHERE marker = 'independent') OR
            EXISTS (SELECT 1 FROM df.instances WHERE label = 'test-satellite-rolled-back') THEN
            RAISE EXCEPTION 'TEST FAILED: satellite transaction boundary';
        END IF;
    END $check$;
$remote$);

SELECT dblink_exec('satellite', $remote$
    INSERT INTO _satellite_state SELECT 'children', df.start(
        'INSERT INTO public.test_satellite_log (marker) VALUES (''loop'')'
        ~> ('INSERT INTO public.test_satellite_log (marker) VALUES (''left'')'
            & 'INSERT INTO public.test_satellite_log (marker) VALUES (''right'')')
        ~> df.loop(
            'UPDATE public.test_satellite_log SET value = value + 1 WHERE marker = ''loop''',
            'SELECT value < 2 FROM public.test_satellite_log WHERE marker = ''loop''',
            continue_on_failure => true
        ), 'test-satellite-children'
    );
    INSERT INTO _satellite_state SELECT 'signal', df.start(
        (df.wait_for_signal('go', 30) |=> 'payload')
        ~> 'INSERT INTO public.test_satellite_log (marker, value) VALUES (''signal'', ($payload::jsonb->''data''->>''value'')::int)',
        'test-satellite-signal'
    );
    INSERT INTO _satellite_state SELECT 'cancel', df.start(
        df.wait_for_signal('never', 60)
        ~> 'INSERT INTO public.test_satellite_log (marker) VALUES (''cancelled'')',
        'test-satellite-cancel'
    );
    INSERT INTO _satellite_state SELECT 'http', df.start(
        '{"node_type":"HTTP","query":"{\"url\":\"https://api.github.com/\",\"method\":\"GET\",\"body\":null,\"headers\":null,\"timeout_seconds\":5}"}',
        'test-satellite-http-denied'
    );
$remote$);

SELECT dblink_exec('satellite', $remote$
    DO $check$
    DECLARE
        inst_id TEXT := (SELECT instance_id FROM _satellite_state WHERE name = 'signal');
        status TEXT;
    BEGIN
        FOR attempt IN 1..200 LOOP
            status := df.status(inst_id);
            EXIT WHEN status IN ('completed', 'failed', 'cancelled');
            PERFORM df.signal(inst_id, 'go', '{"value":73}');
            PERFORM pg_sleep(0.1);
        END LOOP;
        PERFORM df.await_instance(inst_id, 10);
        IF df.status(inst_id) IS DISTINCT FROM 'completed' OR
            NOT EXISTS (SELECT 1 FROM public.test_satellite_log WHERE marker = 'signal' AND value = 73) THEN
            RAISE EXCEPTION 'TEST FAILED: satellite signal not delivered';
        END IF;
    END $check$;
$remote$);
SELECT * FROM dblink('satellite', $remote$
    SELECT df.cancel(instance_id, 'satellite test cancellation')
    FROM _satellite_state WHERE name = 'cancel'
$remote$) AS remote(result TEXT);

SELECT dblink_exec('satellite', $remote$
    DO $check$
    DECLARE
        inst_id TEXT;
        node_result TEXT;
    BEGIN
        SELECT instance_id INTO inst_id FROM _satellite_state WHERE name = 'cancel';
        IF df.await_instance(inst_id, 30) IS DISTINCT FROM 'cancelled' THEN
            RAISE EXCEPTION 'TEST FAILED: satellite cancellation';
        END IF;
        SELECT instance_id INTO inst_id FROM _satellite_state WHERE name = 'children';
        PERFORM df.await_instance(inst_id, 30);
        IF df.status(inst_id) IS DISTINCT FROM 'completed' OR
            (SELECT count(*) FROM public.test_satellite_log WHERE marker IN ('left', 'right')) <> 2 OR
            (SELECT value FROM public.test_satellite_log WHERE marker = 'loop') IS DISTINCT FROM 2 THEN
            RAISE EXCEPTION 'TEST FAILED: satellite parallel or loop children misrouted';
        END IF;
        SELECT instance_id INTO inst_id FROM _satellite_state WHERE name = 'http';
        IF df.await_instance(inst_id, 30) IS DISTINCT FROM 'failed' THEN
            RAISE EXCEPTION 'TEST FAILED: control HTTP permission authorized satellite request';
        END IF;
        SELECT result::text INTO node_result FROM df.nodes
            WHERE instance_id = inst_id AND node_type = 'HTTP';
        IF node_result IS NULL OR node_result NOT ILIKE '%does not have EXECUTE privilege%' THEN
            RAISE EXCEPTION 'TEST FAILED: expected origin HTTP privilege denial, got %', node_result;
        END IF;
        IF EXISTS (SELECT 1 FROM public.test_satellite_log
            WHERE marker IN ('rolled-back', 'cancelled') OR db_name <> '_test_satellite_db'
                OR role_name <> 'df_e2e_user') THEN
            RAISE EXCEPTION 'TEST FAILED: unexpected satellite side effect or execution identity';
        END IF;
    END $check$;
$remote$);

DO $$
DECLARE
    rollback_id TEXT := (SELECT instance_id FROM _satellite_rolled_back);
    row_count INT;
BEGIN
    SELECT total INTO row_count FROM dblink('satellite', format(
        'SELECT (SELECT count(*) FROM df.instances WHERE id = %L) + (SELECT count(*) FROM df.nodes WHERE instance_id = %L)',
        rollback_id, rollback_id
    )) AS remote(total INT);
    IF row_count IS DISTINCT FROM 0 OR
        EXISTS (SELECT 1 FROM df.instances WHERE label LIKE 'test-satellite-%') OR
        EXISTS (SELECT 1 FROM df.vars WHERE name = 'satellite_value') OR
        EXISTS (SELECT 1 FROM public.test_satellite_log) THEN
        RAISE EXCEPTION 'TEST FAILED: satellite metadata or writes leaked into control';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = df.duroxide_schema()) THEN
        RAISE EXCEPTION 'TEST FAILED: control provider schema missing';
    END IF;
END $$;

SELECT dblink_exec('satellite', 'RESET SESSION AUTHORIZATION; DROP EXTENSION pg_durable CASCADE');
SELECT dblink_disconnect('satellite');
DROP DATABASE _test_satellite_db WITH (FORCE);

SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _control_after_satellite AS
SELECT df.start('SELECT 84', 'test-control-after-satellite-drop') AS instance_id;
DO $$
BEGIN
    IF df.await_instance((SELECT instance_id FROM _control_after_satellite), 30) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: dropping satellite stopped control execution';
    END IF;
END $$;
DROP TABLE _control_after_satellite;
RESET SESSION AUTHORIZATION;

DO $$
BEGIN
    IF (SELECT epoch_id FROM df._worker_epoch) IS DISTINCT FROM (SELECT epoch_id FROM _control_epoch) THEN
        RAISE EXCEPTION 'TEST FAILED: dropping satellite restarted control runtime';
    END IF;
END $$;

REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM df_e2e_user;
REVOKE EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer) FROM df_e2e_user;
DROP TABLE public.test_satellite_log;
DROP TABLE _control_epoch, _satellite_rolled_back;

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

    SELECT df.await_instance(inst_id) INTO status;

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

    SELECT df.await_instance(inst_id) INTO status;

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

    SELECT df.await_instance(inst_id) INTO status;

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
