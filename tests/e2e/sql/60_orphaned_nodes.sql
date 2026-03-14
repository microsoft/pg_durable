-- Test: Orphaned nodes — no FK constraint between df.instances and df.nodes (E1)
-- Demonstrates: Deleting an instance row leaves its nodes in df.nodes because
--               there is no cascading FK constraint.  df.result() and df.status()
--               return NULL / unknown for the deleted instance; no crash.
--
-- Findings documented:
--   - df.nodes rows survive after the parent df.instances row is deleted.
--   - No FK cascade means orphaned nodes can accumulate indefinitely.
--   - Functions that reference a deleted instance return gracefully (NULL).
--
-- Expected: Node count is unchanged after the instance row is deleted;
--           df.status() returns NULL (or unknown), no exception thrown.
--
-- Requires superuser to DELETE directly from df.instances (bypasses RLS).

-- ─── Start a quick instance and let it complete ────────────────────────────

CREATE TEMP TABLE _orphan_state (instance_id TEXT, node_count BIGINT);

INSERT INTO _orphan_state (instance_id)
SELECT df.start(
    'SELECT 1' ~> 'SELECT 2' ~> 'SELECT 3',
    'test-orphan-nodes-e1'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _orphan_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [E1]: instance did not complete (status=%)', status;
    END IF;

    RAISE NOTICE 'Instance % completed; counting nodes before delete', inst_id;
END $$;

-- ─── Count nodes that belong to this instance ──────────────────────────────

UPDATE _orphan_state
SET node_count = (
    SELECT COUNT(*) FROM df.nodes n
    JOIN _orphan_state s ON n.instance_id = s.instance_id
);

DO $$
DECLARE
    nc BIGINT;
BEGIN
    SELECT node_count INTO nc FROM _orphan_state;
    IF nc = 0 THEN
        RAISE EXCEPTION 'TEST FAILED [E1]: expected nodes to exist for completed instance, found 0';
    END IF;
    RAISE NOTICE 'Found % node(s) for the completed instance', nc;
END $$;

-- ─── Delete the instance row directly (superuser, bypasses RLS) ───────────

DO $$
DECLARE
    inst_id TEXT;
    deleted INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _orphan_state;
    DELETE FROM df.instances WHERE id = inst_id;
    GET DIAGNOSTICS deleted = ROW_COUNT;

    IF deleted = 0 THEN
        RAISE EXCEPTION 'TEST FAILED [E1]: failed to delete instance row for %', inst_id;
    END IF;

    RAISE NOTICE 'Deleted instance row for % (% row(s) affected)', inst_id, deleted;
END $$;

-- ─── Verify nodes are still present (orphaned) ────────────────────────────

DO $$
DECLARE
    inst_id      TEXT;
    expected_nc  BIGINT;
    actual_nc    BIGINT;
BEGIN
    SELECT instance_id, node_count INTO inst_id, expected_nc FROM _orphan_state;

    SELECT COUNT(*) INTO actual_nc FROM df.nodes WHERE instance_id = inst_id;

    IF actual_nc != expected_nc THEN
        RAISE EXCEPTION 'TEST FAILED [E1]: expected % orphaned node(s), found % (FK cascade may have run)',
            expected_nc, actual_nc;
    END IF;

    RAISE NOTICE 'PASSED [E1-a]: % node(s) remain after instance row deleted (no FK cascade)', actual_nc;
END $$;

-- ─── Verify df.status() returns gracefully for deleted instance ───────────

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _orphan_state;
    SELECT s INTO status FROM df.status(inst_id) s;
    -- status should be NULL or 'unknown' — not an exception
    RAISE NOTICE 'PASSED [E1-b]: df.status() returned % for deleted instance (no crash)', status;
END $$;

-- ─── Clean up orphaned nodes (manual, since no cascade) ───────────────────

DO $$
DECLARE
    inst_id  TEXT;
    deleted  INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _orphan_state;
    DELETE FROM df.nodes WHERE instance_id = inst_id;
    GET DIAGNOSTICS deleted = ROW_COUNT;
    RAISE NOTICE 'Cleaned up % orphaned node(s)', deleted;
END $$;

DROP TABLE _orphan_state;

SELECT 'TEST PASSED' AS result;
