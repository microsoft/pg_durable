-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: terminal history event payloads carry the correct identifiers
--
-- Regression test for #169: the terminal `OrchestrationFailed` event was
-- persisted with `instance_id = ""` and `execution_id = 0` inside its
-- `<duroxide-schema>.history` `event_data` payload, even though the history row
-- columns held the correct identifiers. Consumers that correlate events by
-- payload alone therefore lost the link back to the instance.
--
-- Root cause was upstream in duroxide (microsoft/duroxide#35, fixed by the
-- `duroxide` 0.1.30 bump). The bug affected every `OrchestrationFailed`
-- terminal event, so this test exercises both terminal paths:
--   1. Cancellation  — df.cancel() on a running instance
--   2. Plain failure — a workflow that errors mid-execution
--
-- For each, it asserts the terminal `OrchestrationFailed` event payload's
-- instance_id/execution_id match the history row, and (as a broader sweep)
-- that no history event for the instance carries mismatched identifiers.

-- ---------------------------------------------------------------------------
-- Helper: wait for the terminal event to be persisted, then assert its payload
-- identifiers match the history row identifiers. Reads the duroxide provider
-- schema (superuser only), so it is created and invoked as the bootstrap role.
-- The schema name is resolved via df.duroxide_schema() so the test works on both
-- fresh ('_duroxide') and legacy ('duroxide') installs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION df_e2e_assert_terminal_payload_ids(
    p_instance_id TEXT,
    p_scenario    TEXT
) RETURNS VOID LANGUAGE plpgsql AS $fn$
DECLARE
    v_schema         TEXT := df.duroxide_schema();
    v_terminal_count INT  := 0;
    v_bad            INT  := 0;
    v_attempts       INT  := 0;
BEGIN
    -- The engine writes the terminal event asynchronously, after df.status()
    -- already reports a terminal state. Poll until it lands so an early read
    -- cannot pass trivially against an absent event.
    LOOP
        EXECUTE format(
            'SELECT count(*) FROM %I.history h '
            'WHERE h.instance_id = $1 '
            '  AND h.event_data::jsonb->>''type'' = ''OrchestrationFailed''',
            v_schema
        ) INTO v_terminal_count USING p_instance_id;
        EXIT WHEN v_terminal_count >= 1 OR v_attempts > 300;
        PERFORM pg_sleep(0.1);
        v_attempts := v_attempts + 1;
    END LOOP;

    IF v_terminal_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [%]: no terminal OrchestrationFailed event was persisted for instance %',
            p_scenario, p_instance_id;
    END IF;

    -- Core #169 assertion: the terminal event payload must carry the real
    -- identifiers (non-empty instance_id, numeric non-zero execution_id, both
    -- matching the owning history row).
    EXECUTE format(
        'SELECT count(*) FROM %I.history h '
        'WHERE h.instance_id = $1 '
        '  AND h.event_data::jsonb->>''type'' = ''OrchestrationFailed'' '
        '  AND ( COALESCE(h.event_data::jsonb->>''instance_id'', '''') <> h.instance_id '
        '     OR COALESCE(h.event_data::jsonb->>''execution_id'', '''') !~ ''^[0-9]+$'' '
        '     OR (h.event_data::jsonb->>''execution_id'')::bigint = 0 '
        '     OR (h.event_data::jsonb->>''execution_id'')::bigint <> h.execution_id )',
        v_schema
    ) INTO v_bad USING p_instance_id;

    IF v_bad > 0 THEN
        RAISE EXCEPTION 'TEST FAILED [%]: % terminal OrchestrationFailed event(s) have empty/zero/mismatched instance_id or execution_id in payload (regression of #169) for instance %',
            p_scenario, v_bad, p_instance_id;
    END IF;

    -- Broader sweep: any history event that carries identifier fields must
    -- agree with its row identifiers.
    EXECUTE format(
        'SELECT count(*) FROM %I.history h '
        'WHERE h.instance_id = $1 '
        '  AND ( (h.event_data::jsonb ? ''instance_id'' '
        '         AND COALESCE(h.event_data::jsonb->>''instance_id'', '''') <> h.instance_id) '
        '     OR (h.event_data::jsonb ? ''execution_id'' '
        '         AND ( COALESCE(h.event_data::jsonb->>''execution_id'', '''') !~ ''^[0-9]+$'' '
        '            OR (h.event_data::jsonb->>''execution_id'')::bigint <> h.execution_id )) )',
        v_schema
    ) INTO v_bad USING p_instance_id;

    IF v_bad > 0 THEN
        RAISE EXCEPTION 'TEST FAILED [%]: % history event(s) have payload identifiers that do not match row identifiers for instance %',
            p_scenario, v_bad, p_instance_id;
    END IF;

    RAISE NOTICE 'PASSED [%]: terminal and history event payload identifiers match row identifiers',
        p_scenario;
END $fn$;

-- ===========================================================================
-- Scenario 1: Cancellation of a running instance
-- ===========================================================================

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _t_cancel (instance_id TEXT);
INSERT INTO _t_cancel SELECT df.start(
    df.sleep(300),   -- long enough to reliably observe the running state
    'terminal-payload-cancel'
);

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_cancel;

    -- Wait until it is genuinely running before cancelling.
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'running' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) <> 'running' THEN
        RAISE EXCEPTION 'Scenario 1 setup failed: instance did not reach running state (status=%)', status;
    END IF;

    PERFORM df.cancel(inst_id, 'terminal-payload-regression');

    attempts := 0;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('cancelled', 'failed') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) NOT IN ('cancelled', 'failed') THEN
        RAISE EXCEPTION 'Scenario 1 setup failed: instance did not reach a terminal state (status=%)', status;
    END IF;
END $$;

-- ===========================================================================
-- Scenario 2: Plain failure mid-execution
-- ===========================================================================

CREATE TEMP TABLE _t_fail (instance_id TEXT);
INSERT INTO _t_fail SELECT df.start(
    'SELECT 1/0',   -- division by zero forces an OrchestrationFailed terminal event
    'terminal-payload-fail'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_fail;

    SELECT df.await_instance(inst_id, 30) INTO status;

    IF lower(status) <> 'failed' THEN
        RAISE EXCEPTION 'Scenario 2 setup failed: expected failed, got %', status;
    END IF;
END $$;

-- ===========================================================================
-- Assertions (read the provider schema as the bootstrap superuser role)
-- ===========================================================================

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    v_cancel_id TEXT;
    v_fail_id   TEXT;
BEGIN
    SELECT instance_id INTO v_cancel_id FROM _t_cancel;
    SELECT instance_id INTO v_fail_id   FROM _t_fail;

    PERFORM df_e2e_assert_terminal_payload_ids(v_cancel_id, 'cancellation');
    PERFORM df_e2e_assert_terminal_payload_ids(v_fail_id,   'plain_failure');
END $$;

-- Cleanup
DROP TABLE _t_cancel;
DROP TABLE _t_fail;
DROP FUNCTION IF EXISTS df_e2e_assert_terminal_payload_ids(TEXT, TEXT);

SELECT 'TEST PASSED: terminal event payload identifiers' AS result;
