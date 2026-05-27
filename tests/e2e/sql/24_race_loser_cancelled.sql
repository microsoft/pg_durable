-- Tests: df.instance_nodes marks losing-branch nodes as 'cancelled' after race completes
--
-- Repro for: df.instance_nodes leaves race-loser nodes running or pending after
-- race completion.
--
-- Setup: a race where one branch completes instantly and the other waits with a
-- long sleep.  After the race completes, every losing-branch node must have
-- status = 'cancelled' in df.nodes; none should remain 'running' or 'pending'.

SET SESSION AUTHORIZATION df_e2e_user;

-- === Scenario 1: fast SQL wins, long sleep loses ===

CREATE TEMP TABLE _race_loser_cancelled_state (instance_id TEXT);

INSERT INTO _race_loser_cancelled_state
SELECT df.start(
    df.race(
        'SELECT ''fast'' AS winner',
        df.sleep(60)
    ),
    'test-race-loser-cancelled'
);

DO $$
DECLARE
    inst_id TEXT;
    v_status TEXT;
    ghost_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _race_loser_cancelled_state;
    RAISE NOTICE 'Testing race loser cancellation for instance: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 30) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [race-loser-cancelled]: expected completed, got %', v_status;
    END IF;

    -- Allow a short settle window for the cancel activity to write through
    PERFORM pg_sleep(2);

    -- No node in the instance should remain 'running' or 'pending' after the
    -- race has been decided.
    SELECT COUNT(*) INTO ghost_count
    FROM df.instance_nodes(inst_id)
    WHERE status IN ('running', 'pending');

    IF ghost_count > 0 THEN
        RAISE EXCEPTION
            'TEST FAILED [race-loser-cancelled]: % node(s) still running/pending after race completed',
            ghost_count;
    END IF;

    -- Verify the losing branch root node (the sleep) is specifically 'cancelled'
    IF NOT EXISTS (
        SELECT 1
        FROM df.instance_nodes(inst_id)
        WHERE node_type = 'SLEEP' AND status = 'cancelled'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED [race-loser-cancelled]: SLEEP node not marked as cancelled';
    END IF;

    RAISE NOTICE 'TEST PASSED: race_loser_cancelled (scenario 1)';
END $$;

DROP TABLE _race_loser_cancelled_state;

-- === Scenario 2: losing branch is a multi-node sequence (THEN + SQL) ===

CREATE TEMP TABLE _race_loser_seq_state (instance_id TEXT);

INSERT INTO _race_loser_seq_state
SELECT df.start(
    df.race(
        'SELECT ''fast'' AS winner',
        df.seq(
            df.sleep(60),
            'SELECT ''slow-follow-up'''
        )
    ),
    'test-race-loser-seq'
);

DO $$
DECLARE
    inst_id TEXT;
    v_status TEXT;
    ghost_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _race_loser_seq_state;
    RAISE NOTICE 'Testing race loser cancellation (multi-node) for instance: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 30) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [race-loser-seq]: expected completed, got %', v_status;
    END IF;

    PERFORM pg_sleep(2);

    SELECT COUNT(*) INTO ghost_count
    FROM df.instance_nodes(inst_id)
    WHERE status IN ('running', 'pending');

    IF ghost_count > 0 THEN
        RAISE EXCEPTION
            'TEST FAILED [race-loser-seq]: % node(s) still running/pending after race completed',
            ghost_count;
    END IF;

    RAISE NOTICE 'TEST PASSED: race_loser_cancelled (scenario 2: multi-node loser)';
END $$;

DROP TABLE _race_loser_seq_state;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED: race loser nodes cancelled' AS result;
