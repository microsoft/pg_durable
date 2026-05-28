-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.signal propagation into wait_for_signal inside df.race branch
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_signal_race_log;
CREATE TABLE test_signal_race_log (
    id SERIAL PRIMARY KEY,
    branch TEXT NOT NULL,
    data JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TEMP TABLE _test_signal_race_state (instance_id TEXT);

INSERT INTO _test_signal_race_state
SELECT df.start(
    df.race(
        df.seq(
            df.wait_for_signal('approve', 12) |=> 'sig',
            'INSERT INTO test_signal_race_log (branch, data) VALUES (''signal'', $sig::jsonb)'
        ),
        df.seq(
            df.sleep(8),
            'INSERT INTO test_signal_race_log (branch, data) VALUES (''sleep'', ''{}''::jsonb)'
        )
    ),
    'test-signal-in-race'
);

SELECT pg_sleep(2);

DO $$
DECLARE
    v_instance_id TEXT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test_signal_race_state;
    PERFORM df.signal(v_instance_id, 'approve', '{"approved": true}');
END $$;

DO $$
DECLARE
    v_instance_id TEXT;
    v_status TEXT;
BEGIN
    SELECT instance_id INTO v_instance_id FROM _test_signal_race_state;
    SELECT df.wait_for_completion(v_instance_id, 25) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [signal-in-race]: expected completed, got %', v_status;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM test_signal_race_log
        WHERE branch = 'signal'
          AND (data->>'timed_out')::boolean = false
          AND (data->'data'->>'approved')::boolean = true
    ) THEN
        RAISE EXCEPTION 'TEST FAILED [signal-in-race]: signal branch did not receive approve event';
    END IF;

    IF EXISTS (SELECT 1 FROM test_signal_race_log WHERE branch = 'sleep') THEN
        RAISE EXCEPTION 'TEST FAILED [signal-in-race]: sleep branch unexpectedly won race';
    END IF;

    RAISE NOTICE 'TEST PASSED: signal_in_race';
END $$;

DROP TABLE _test_signal_race_state;
DROP TABLE test_signal_race_log;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
