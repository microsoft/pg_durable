-- Merged from: 22_cross_connection, 23_transactions
-- Tests: df.signal() and df.cancel() from a different backend connection (dblink),
--        transaction semantics — committed txn executes, rolled-back txn does not
-- Runs as postgres throughout (uses dblink with postgres user)

-- === Test: 22_cross_connection ===

DROP TABLE IF EXISTS cross_conn_log;
CREATE TABLE cross_conn_log (
    id SERIAL PRIMARY KEY,
    msg TEXT,
    data JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Connection string for dblink (same database, different connection)
CREATE TEMP TABLE _dblink_conn AS 
SELECT format('host=localhost dbname=postgres port=%s user=postgres', current_setting('port')) AS connstr;

-- Test 1: Signal from Different Connection
CREATE TEMP TABLE _test_cross_signal (instance_id TEXT);

INSERT INTO _test_cross_signal SELECT df.start(
    'SELECT ''started''' |=> 'msg'
    ~> (df.wait_for_signal('external_trigger') |=> 'sig')
    ~> 'INSERT INTO cross_conn_log (msg, data) 
        VALUES (''signal_received'', $sig::jsonb)',
    'cross-conn-signal'
);

-- Wait for workflow to reach signal wait state
SELECT pg_sleep(2);

-- Verify workflow is waiting (not completed)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_signal;
    SELECT s INTO status FROM df.status(inst_id) s;
    
    IF lower(status) = 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: workflow should be waiting, not completed';
    END IF;
    
    RAISE NOTICE 'Workflow % is waiting (status: %)', inst_id, status;
END $$;

-- Signal from DIFFERENT connection using dblink
DO $$
DECLARE
    inst_id TEXT;
    connstr TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_signal;
    SELECT c.connstr INTO connstr FROM _dblink_conn c;
    
    SELECT * INTO result FROM dblink(
        connstr,
        format('SELECT df.signal(%L, ''external_trigger'', ''{"source": "other_connection", "value": 123}'')', inst_id)
    ) AS t(result TEXT);
    
    RAISE NOTICE 'Signal sent from other connection: %', result;
END $$;

-- Wait for completion and verify
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_signal;

    SELECT df.wait_for_completion(inst_id, 10) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: cross-connection signal status = %', status;
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM cross_conn_log 
        WHERE msg = 'signal_received'
        AND (data->'data'->>'source') = 'other_connection'
        AND (data->'data'->>'value')::int = 123
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: signal data from other connection not received correctly';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: cross_connection_signal';
END $$;

DROP TABLE _test_cross_signal;
DELETE FROM cross_conn_log;

-- Test 2: Cancel from Different Connection
CREATE TEMP TABLE _test_cross_cancel (instance_id TEXT);

INSERT INTO _test_cross_cancel SELECT df.start(
    @> (
        'INSERT INTO cross_conn_log (msg) VALUES (''loop_iteration'')'
        ~> df.sleep(1)
    ),
    'cross-conn-cancel'
);

-- Wait for at least one loop iteration to be committed
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    iteration_count INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_cancel;
    LOOP
        SELECT COUNT(*) INTO iteration_count FROM cross_conn_log WHERE msg = 'loop_iteration';
        EXIT WHEN iteration_count >= 1 OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    SELECT s INTO status FROM df.status(inst_id) s;
    
    IF iteration_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: loop should have at least 1 iteration after 10s, got %', iteration_count;
    END IF;
    
    RAISE NOTICE 'Workflow % is running (status: %, iterations: %)', inst_id, status, iteration_count;
END $$;

-- Cancel from DIFFERENT connection using dblink
DO $$
DECLARE
    inst_id TEXT;
    connstr TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_cancel;
    SELECT c.connstr INTO connstr FROM _dblink_conn c;
    
    SELECT * INTO result FROM dblink(
        connstr,
        format('SELECT df.cancel(%L, ''Canceled from external system'')', inst_id)
    ) AS t(result TEXT);
    
    RAISE NOTICE 'Cancel sent from other connection: %', result;
END $$;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_cancel;

    SELECT df.wait_for_completion(inst_id, 10) INTO status;

    IF lower(status) != 'cancelled' THEN
        RAISE EXCEPTION 'TEST FAILED: cross-connection cancel status = % (expected cancelled)', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: cross_connection_cancel';
END $$;

DROP TABLE _test_cross_cancel;

-- Test 3: Monitor from Different Connection
CREATE TEMP TABLE _test_cross_monitor (instance_id TEXT);

INSERT INTO _test_cross_monitor SELECT df.start(
    'SELECT 1' ~> df.sleep(1) ~> 'SELECT 2',
    'cross-conn-monitor'
);

DO $$
DECLARE
    inst_id TEXT;
    connstr TEXT;
    remote_status TEXT;
    local_status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_monitor;
    SELECT c.connstr INTO connstr FROM _dblink_conn c;
    
    SELECT * INTO remote_status FROM dblink(
        connstr,
        format('SELECT df.status(%L)', inst_id)
    ) AS t(status TEXT);
    
    SELECT s INTO local_status FROM df.status(inst_id) s;
    
    RAISE NOTICE 'Status from other connection: %, from this connection: %', remote_status, local_status;
    
    IF remote_status IS NULL OR local_status IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: could not get status from both connections';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: cross_connection_monitor';
END $$;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_monitor;
    SELECT df.wait_for_completion(inst_id, 10) INTO status;
END $$;

DROP TABLE _test_cross_monitor;
DROP TABLE cross_conn_log;

-- === Test: 23_transactions ===

DROP TABLE IF EXISTS txn_test_log;
CREATE TABLE txn_test_log (
    id SERIAL PRIMARY KEY,
    msg TEXT,
    instance_id TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Test 1: DF Started Within DO Block (Same Transaction) - Should Work via Retry
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    RAISE NOTICE 'Test 1: DF started within same transaction (tests retry logic)';
    
    inst_id := df.start(
        'INSERT INTO txn_test_log (msg, instance_id) VALUES (''same_txn_df_ran'', ''{sys_instance_id}'')',
        'txn-test-same-txn'
    );
    
    RAISE NOTICE 'Started DF: %. Worker will retry until this txn commits...', inst_id;
    
    PERFORM pg_sleep(0.5);
    
    RAISE NOTICE 'Transaction about to commit after 500ms delay...';
    
    INSERT INTO txn_test_log (msg, instance_id) VALUES ('test1_instance_id', inst_id);
END $$;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM txn_test_log WHERE msg = 'test1_instance_id';
    RAISE NOTICE 'Test 1: Waiting for DF: %', inst_id;
    
    SELECT df.wait_for_completion(inst_id, 10) INTO status;
    
    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: same-txn DF status = % (retry logic should have waited for commit)', status;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM txn_test_log WHERE msg = 'same_txn_df_ran') THEN
        RAISE EXCEPTION 'TEST FAILED: same-txn DF did not execute';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: same_transaction_with_retry';
END $$;

DELETE FROM txn_test_log;

-- Test 2: Rolled Back Transaction - DF Should NOT Execute
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    RAISE NOTICE 'Test 2: Rolled back transaction (via savepoint)';
    
    BEGIN
        inst_id := df.start(
            'INSERT INTO txn_test_log (msg) VALUES (''rollback_df_should_not_run'')',
            'txn-test-rollback'
        );
        
        RAISE NOTICE 'Started DF that will be rolled back: %', inst_id;
        
        INSERT INTO txn_test_log (msg, instance_id) VALUES ('rollback_test_id', inst_id);
        
        RAISE EXCEPTION 'Simulated rollback';
        
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Transaction rolled back (exception caught)';
    END;
    
    RAISE NOTICE 'After rollback, checking if DF data persisted...';
END $$;

DO $$
DECLARE
    rollback_id TEXT;
    node_count INT;
    instance_count INT;
BEGIN
    SELECT instance_id INTO rollback_id FROM txn_test_log WHERE msg = 'rollback_test_id';
    
    IF rollback_id IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: rollback_test_id should have been rolled back but found: %', rollback_id;
    END IF;
    
    SELECT COUNT(*) INTO instance_count FROM df.instances WHERE label = 'txn-test-rollback';
    
    IF instance_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: rolled back DF should not exist in df.instances';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: rollback_transaction_no_instance';
END $$;

SELECT pg_sleep(2);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM txn_test_log WHERE msg = 'rollback_df_should_not_run') THEN
        RAISE EXCEPTION 'TEST FAILED: rolled back DF should not have executed';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: rollback_transaction_no_execution';
END $$;

-- Test 3: Explicit Transaction with Rollback (using dblink)
DO $$
DECLARE
    connstr TEXT := format('host=localhost dbname=postgres port=%s user=postgres', current_setting('port'));
    result TEXT;
    instance_count INT;
BEGIN
    RAISE NOTICE 'Test 3: Explicit transaction rollback via separate connection';
    
    BEGIN
        SELECT * INTO result FROM dblink(
            connstr,
            $dblink$
                BEGIN;
                SELECT df.start(
                    'INSERT INTO txn_test_log (msg) VALUES (''explicit_rollback_should_not_run'')',
                    'txn-test-explicit-rollback'
                );
                ROLLBACK;
            $dblink$
        ) AS t(result TEXT);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'dblink completed (exception: %)', SQLERRM;
    END;
    
    PERFORM pg_sleep(2);
    
    SELECT COUNT(*) INTO instance_count FROM df.instances WHERE label = 'txn-test-explicit-rollback';
    
    IF instance_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: explicitly rolled back DF should not exist';
    END IF;
    
    IF EXISTS (SELECT 1 FROM txn_test_log WHERE msg = 'explicit_rollback_should_not_run') THEN
        RAISE EXCEPTION 'TEST FAILED: explicitly rolled back DF should not have executed';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: explicit_rollback_transaction';
END $$;

DROP TABLE txn_test_log;

SELECT 'ALL CROSS-CONNECTION AND TRANSACTION TESTS PASSED' AS result;
