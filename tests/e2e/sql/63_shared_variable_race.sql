-- Test: Shared variable race between sessions (F4)
-- Demonstrates: df.vars is a per-owner table — if two sessions with the same
--               PostgreSQL role write the same variable key, the second write
--               overwrites the first.  A df.start() call that happens AFTER
--               the overwrite will capture the overwritten value, not the
--               original one intended by the first session.
--
-- Method: Sequential dblink calls simulate the interleaving that can happen
--         with concurrent sessions:
--   1. This session: setvar('race_key', 'first')
--   2. Second "session" (dblink): setvar('race_key', 'overwritten') — overwrites
--   3. This session: df.start() — captures 'overwritten', not 'first'
--
-- Findings documented:
--   - Variables are captured as a snapshot at df.start() time from df.vars.
--   - Concurrent sessions sharing the same role share the same df.vars namespace
--     (owner = current_user::regrole), so overwrites are possible.
--   - Workaround: use unique variable names per workflow (e.g., UUID-prefixed).
--
-- A second sub-test validates normal (non-racy) snapshot semantics: variables
-- set before df.start() are correctly captured, and later changes do NOT
-- affect already-started instances.
--
-- Requires superuser (uses dblink with postgres credentials).

CREATE EXTENSION IF NOT EXISTS dblink;

-- ─── Build a dblink connection string ─────────────────────────────────────

CREATE TEMP TABLE _race_conn AS
SELECT format(
    'host=localhost dbname=%s port=%s user=postgres',
    current_database(),
    current_setting('port')
) AS connstr;

-- ─── Sub-test 1: Snapshot semantics — post-start changes do NOT affect ─────
-- a running instance.

DO $$
BEGIN
    -- Set variable before starting the instance
    PERFORM df.setvar('race_snapshot_key', 'original_value');
END $$;

CREATE TEMP TABLE _snap_state (instance_id TEXT);

INSERT INTO _snap_state
SELECT df.start(
    -- Workflow reads the captured variable via substitution
    df.sql('SELECT $race_snapshot_key AS captured'),
    'race-snapshot-test'
);

-- After start, change the variable — should not affect the already-started instance
DO $$
BEGIN
    PERFORM df.setvar('race_snapshot_key', 'changed_after_start');
END $$;

-- Wait for the instance to complete
DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _snap_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [F4-1]: snapshot instance did not complete (status=%)', status;
    END IF;
END $$;

-- Verify the instance captured the ORIGINAL value, not the post-start change
DO $$
DECLARE
    inst_id TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _snap_state;
    SELECT r INTO result FROM df.result(inst_id) r;

    IF result NOT LIKE '%original_value%' THEN
        RAISE EXCEPTION 'TEST FAILED [F4-1]: expected "original_value" in result, got %. Variables are NOT snapshotted at start time.',
            result;
    END IF;

    RAISE NOTICE 'PASSED [F4-1]: instance captured original value (%) at start time; post-start change was ignored', result;
END $$;

DROP TABLE _snap_state;

-- ─── Sub-test 2: Cross-session overwrite race ─────────────────────────────
-- Session A sets the variable, then another session (simulated via dblink)
-- overwrites it, and then Session A starts its workflow.
-- The workflow captures the overwritten value, not session A's original.

DO $$
BEGIN
    -- Session A sets the variable
    PERFORM df.setvar('race_shared_key', 'session_A_value');
    RAISE NOTICE 'Session A set race_shared_key = session_A_value';
END $$;

-- "Session B" overwrites the variable via dblink
DO $$
DECLARE
    connstr TEXT;
BEGIN
    SELECT c.connstr INTO connstr FROM _race_conn c;

    PERFORM dblink_exec(
        connstr,
        'SELECT df.setvar(''race_shared_key'', ''session_B_overwrote'')'
    );

    RAISE NOTICE 'Session B (dblink) overwrote race_shared_key = session_B_overwrote';
END $$;

-- Session A now calls df.start() — it will capture the OVERWRITTEN value
CREATE TEMP TABLE _race_state (instance_id TEXT);

INSERT INTO _race_state
SELECT df.start(
    df.sql('SELECT $race_shared_key AS captured_race_value'),
    'race-cross-session'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _race_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [F4-2]: cross-session race instance did not complete (status=%)', status;
    END IF;
END $$;

DO $$
DECLARE
    inst_id TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _race_state;
    SELECT r INTO result FROM df.result(inst_id) r;

    -- The instance should have captured session_B's overwrite (not session_A's value)
    IF result NOT LIKE '%session_B_overwrote%' THEN
        RAISE EXCEPTION 'TEST FAILED [F4-2]: expected "session_B_overwrote" in result, got %. Cross-session race behavior changed.',
            result;
    END IF;

    RAISE NOTICE 'PASSED [F4-2]: instance captured the overwritten value (%), demonstrating cross-session race risk', result;
    RAISE NOTICE 'NOTE [F4-2]: Session A intended "session_A_value" but got "session_B_overwrote" — last-writer-wins.';
    RAISE NOTICE 'NOTE [F4-2]: Use unique per-workflow variable names (e.g. UUID-prefixed) to avoid cross-session races.';
END $$;

-- ─── Cleanup ──────────────────────────────────────────────────────────────

DO $$
BEGIN
    PERFORM df.clearvars();
END $$;

DROP TABLE _race_state;
DROP TABLE _race_conn;

SELECT 'TEST PASSED' AS result;
