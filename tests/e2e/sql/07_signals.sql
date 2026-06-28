-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

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

-- Send the signal, retrying until the workflow consumes it. The leading
-- 'SELECT 1' activity runs before df.wait_for_signal, and duroxide drops any
-- event raised before the subscription is registered ("no pending subscription
-- slot", duroxide #154). A single fire-once signal races that registration and
-- is flaky under load, so re-raise until the instance leaves 'running'.
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_basic;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled');
        EXIT WHEN attempts > 100;
        PERFORM df.signal(inst_id, 'go', '{"value": 42}');
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
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

    SELECT df.await_instance(inst_id, 10) INTO status;

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

    SELECT df.await_instance(inst_id, 10) INTO status;

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

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_data;
    RAISE NOTICE 'Testing signal with data: %', inst_id;

    -- Retry the signal until consumed; see Test 1 / duroxide #154.
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled');
        EXIT WHEN attempts > 100;
        PERFORM df.signal(inst_id, 'approval', '{"approved": true, "approver": "jane@acme.com"}');
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    SELECT df.await_instance(inst_id, 10) INTO status;

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

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_text;
    RAISE NOTICE 'Testing signal with plain text data: %', inst_id;

    -- Retry the signal until consumed; see Test 1 / duroxide #154.
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled');
        EXIT WHEN attempts > 100;
        PERFORM df.signal(inst_id, 'plain_text', 'approve');
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    SELECT df.await_instance(inst_id, 10) INTO status;

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
DELETE FROM signal_test_log;

-- Test 5: |=> applied after a THEN composite still captures the final result
CREATE TEMP TABLE _test_signal_then_named (instance_id TEXT);

INSERT INTO _test_signal_then_named SELECT df.start(
    'INSERT INTO signal_test_log (msg) VALUES (''waiting-for-decision'')'
    ~> df.wait_for_signal('test_approval_then', 60) |=> 'decision'
    ~> df.if(
        'SELECT ($decision::jsonb->''data''->>''approved'')::boolean',
        $$INSERT INTO signal_test_log (msg, data) VALUES ('approved-after-then', $decision::jsonb)$$,
        $$INSERT INTO signal_test_log (msg, data) VALUES ('rejected-after-then', $decision::jsonb)$$
    ),
    'test-signal-then-named'
);

-- Retry the signal until the workflow consumes it. This workflow runs a leading
-- INSERT activity *before* df.wait_for_signal, and duroxide only registers the
-- signal subscription a few hundred ms after that INSERT commits. An event
-- raised before the subscription exists is dropped ("no pending subscription
-- slot", duroxide #154), so a single fire-once signal (after a fixed pg_sleep
-- or even after observing the leading INSERT's row) races the subscription and
-- is flaky under CI load. Re-raising until the instance leaves 'running'
-- guarantees at least one signal lands after the subscription is registered;
-- extra events raised earlier are harmlessly dropped.
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_then_named;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled');
        EXIT WHEN attempts > 100;
        PERFORM df.signal(inst_id, 'test_approval_then', '{"approved": true}');
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
END $$;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_then_named;
    SELECT df.await_instance(inst_id, 10) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: composite THEN capture status = %', status;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM signal_test_log
        WHERE msg = 'approved-after-then'
          AND (data->'data'->>'approved')::boolean = true
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: THEN composite capture did not substitute $decision';
    END IF;

    RAISE NOTICE 'TEST PASSED: composite THEN capture';
END $$;

DROP TABLE _test_signal_then_named;
DROP TABLE signal_test_log;

RESET SESSION AUTHORIZATION;
SELECT 'ALL SIGNAL TESTS PASSED' AS result;
