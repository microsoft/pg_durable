-- From: 21_signals
-- Tests: basic signal send/receive, signal timeout, signal payload handling
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 21_signals ===

DROP TABLE IF EXISTS signal_test_log;
CREATE TABLE signal_test_log (
    id SERIAL PRIMARY KEY,
    msg TEXT,
    data JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Test 1: Basic Signal Send/Receive
CREATE TEMP TABLE _test_signal_basic (instance_id TEXT);

INSERT INTO _test_signal_basic SELECT df.start(
    'SELECT 1' |=> 'start'
    ~> (df.wait_for_signal('go') |=> 'sig')
    ~> 'INSERT INTO signal_test_log (msg, data) 
        VALUES (''received'', $sig::jsonb)',
    'test-signal-basic'
);

-- Wait a moment for workflow to start and reach wait state
SELECT pg_sleep(2);

-- Verify the workflow is NOT complete yet (waiting for signal)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_basic;
    SELECT s INTO status FROM df.status(inst_id) s;
    
    IF lower(status) = 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: workflow should be waiting for signal, not completed';
    END IF;
    
    RAISE NOTICE 'Verified workflow is waiting (status: %)', status;
END $$;

-- Send the signal
DO $$
DECLARE
    inst_id TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_basic;
    PERFORM df.signal(inst_id, 'go', '{"value": 42}');
    RAISE NOTICE 'Sent signal to %', inst_id;
END $$;

-- Wait for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_basic;
    RAISE NOTICE 'Testing basic signal: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 10) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: basic signal status = %', status;
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM signal_test_log 
        WHERE msg = 'received' 
        AND (data->>'timed_out')::boolean = false
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: signal data not logged correctly';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM signal_test_log 
        WHERE msg = 'received' 
        AND (data->'data'->>'value')::int = 42
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: signal value 42 not received';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: signal_basic';
END $$;

DROP TABLE _test_signal_basic;
DELETE FROM signal_test_log;

-- Test 2: Signal Timeout
CREATE TEMP TABLE _test_signal_timeout (instance_id TEXT);

INSERT INTO _test_signal_timeout SELECT df.start(
    df.wait_for_signal('never_arrives', 2) |=> 'sig'
    ~> 'INSERT INTO signal_test_log (msg, data) 
        VALUES (''timeout_result'', $sig::jsonb)',
    'test-signal-timeout'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_timeout;
    RAISE NOTICE 'Testing signal timeout: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 10) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: signal timeout status = %', status;
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM signal_test_log 
        WHERE msg = 'timeout_result' 
        AND (data->>'timed_out')::boolean = true
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: timeout not recorded correctly';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: signal_timeout';
END $$;

DROP TABLE _test_signal_timeout;
DELETE FROM signal_test_log;

-- Test 3: Signal with Data
CREATE TEMP TABLE _test_signal_data (instance_id TEXT);

INSERT INTO _test_signal_data SELECT df.start(
    df.wait_for_signal('approval') |=> 'sig'
    ~> 'INSERT INTO signal_test_log (msg, data) 
        VALUES (
            ''approval_received'', 
            jsonb_build_object(
                ''approved'', ($sig::jsonb->''data''->>''approved'')::boolean,
                ''approver'', $sig::jsonb->''data''->>''approver''
            )
        )',
    'test-signal-data'
);

SELECT pg_sleep(1);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_data;
    
    PERFORM df.signal(inst_id, 'approval', '{"approved": true, "approver": "jane@acme.com"}');
    RAISE NOTICE 'Testing signal with data: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 10) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: signal data status = %', status;
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM signal_test_log 
        WHERE msg = 'approval_received' 
        AND (data->>'approved')::boolean = true
        AND data->>'approver' = 'jane@acme.com'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: signal data not extracted correctly';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: signal_data';
END $$;

DROP TABLE _test_signal_data;

-- Test 4: Signal with Plain Text Data
CREATE TEMP TABLE _test_signal_text (instance_id TEXT);

INSERT INTO _test_signal_text SELECT df.start(
    df.wait_for_signal('plain_text') |=> 'sig'
    ~> 'INSERT INTO signal_test_log (msg, data)
        VALUES (
            ''plain_text_received'',
            jsonb_build_object(
                ''timed_out'', ($sig::jsonb->>''timed_out'')::boolean,
                ''data_type'', jsonb_typeof($sig::jsonb->''data''),
                ''data_text'', $sig::jsonb->>''data''
            )
        )',
    'test-signal-text'
);

SELECT pg_sleep(1);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_text;

    PERFORM df.signal(inst_id, 'plain_text', 'approve');
    RAISE NOTICE 'Testing signal with plain text data: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 10) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: signal plain text status = %', status;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM signal_test_log
        WHERE msg = 'plain_text_received'
        AND (data->>'timed_out')::boolean = false
        AND data->>'data_type' = 'string'
        AND data->>'data_text' = 'approve'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: plain text signal data not preserved';
    END IF;

    RAISE NOTICE 'TEST PASSED: signal_plain_text_data';
END $$;

DROP TABLE _test_signal_text;
DROP TABLE signal_test_log;

RESET SESSION AUTHORIZATION;
SELECT 'ALL SIGNAL TESTS PASSED' AS result;
