-- E2E Test: Cross-Connection Operations
-- Tests that df.signal() and df.cancel() work when called from a different
-- PostgreSQL connection (different backend process) than the one that started the DF.

-- ============================================================================
-- Setup
-- ============================================================================

DROP TABLE IF EXISTS cross_conn_log;
CREATE TABLE cross_conn_log (
    id SERIAL PRIMARY KEY,
    msg TEXT,
    data JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Connection string for dblink (same database, different connection)
-- This simulates an external system or different user session
-- Use host=localhost to force TCP connection instead of socket
CREATE TEMP TABLE _dblink_conn AS 
SELECT format('host=localhost dbname=postgres port=%s user=postgres', current_setting('port')) AS connstr;

-- ============================================================================
-- Test 1: Signal from Different Connection
-- ============================================================================

CREATE TEMP TABLE _test_cross_signal (instance_id TEXT);

-- Start workflow in THIS connection
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
    
    -- This executes df.signal() in a completely separate backend process
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
    
    -- Verify the signal data was received correctly
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

-- ============================================================================
-- Test 2: Cancel from Different Connection
-- ============================================================================

CREATE TEMP TABLE _test_cross_cancel (instance_id TEXT);

-- Start a long-running workflow in THIS connection
INSERT INTO _test_cross_cancel SELECT df.start(
    @> (
        'INSERT INTO cross_conn_log (msg) VALUES (''loop_iteration'')'
        ~> df.sleep(1)
    ),
    'cross-conn-cancel'
);

-- Wait for at least one loop iteration to be committed (poll instead of fixed sleep)
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
    
    -- This executes df.cancel() in a completely separate backend process
    SELECT * INTO result FROM dblink(
        connstr,
        format('SELECT df.cancel(%L, ''Canceled from external system'')', inst_id)
    ) AS t(result TEXT);
    
    RAISE NOTICE 'Cancel sent from other connection: %', result;
END $$;

-- Wait for cancellation and verify
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_cancel;

    -- Wait for cancellation (may show as 'failed' or 'cancelled')
    SELECT df.wait_for_completion(inst_id, 10) INTO status;

    -- Canceled workflows end up as 'failed' or 'canceled'/'cancelled'
    IF status NOT IN ('canceled', 'cancelled', 'failed') THEN
        RAISE EXCEPTION 'TEST FAILED: cross-connection cancel status = % (expected canceled/cancelled/failed)', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: cross_connection_cancel';
END $$;

DROP TABLE _test_cross_cancel;

-- ============================================================================
-- Test 3: Monitor from Different Connection
-- ============================================================================

CREATE TEMP TABLE _test_cross_monitor (instance_id TEXT);

-- Start workflow in THIS connection
INSERT INTO _test_cross_monitor SELECT df.start(
    'SELECT 1' ~> df.sleep(1) ~> 'SELECT 2',
    'cross-conn-monitor'
);

-- Query status from DIFFERENT connection using dblink
DO $$
DECLARE
    inst_id TEXT;
    connstr TEXT;
    remote_status TEXT;
    local_status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_monitor;
    SELECT c.connstr INTO connstr FROM _dblink_conn c;
    
    -- Get status from the other connection
    SELECT * INTO remote_status FROM dblink(
        connstr,
        format('SELECT df.status(%L)', inst_id)
    ) AS t(status TEXT);
    
    -- Get status from this connection
    SELECT s INTO local_status FROM df.status(inst_id) s;
    
    RAISE NOTICE 'Status from other connection: %, from this connection: %', remote_status, local_status;
    
    IF remote_status IS NULL OR local_status IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: could not get status from both connections';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: cross_connection_monitor';
END $$;

-- Wait for completion before cleanup
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cross_monitor;
    SELECT df.wait_for_completion(inst_id, 10) INTO status;
END $$;

DROP TABLE _test_cross_monitor;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP TABLE cross_conn_log;

SELECT 'ALL CROSS-CONNECTION TESTS PASSED' AS result;

