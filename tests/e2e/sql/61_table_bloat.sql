-- Test: Table bloat measurement (E4 / E5)
-- Demonstrates: Completed instances leave rows in df.nodes and df.instances
--               indefinitely — there is no automatic GC or cleanup mechanism.
--
-- Findings documented:
--   - Rows in df.nodes accumulate proportionally to total nodes across all
--     completed/failed/canceled instances (no pruning).
--   - Rows in df.instances likewise persist forever.
--   - Duroxide internal tables (_orchestration_history, etc.) also grow.
--   - Operators must plan for periodic manual cleanup or implement GC.
--
-- Expected: After running N instances the row counts increase by exactly N
--           (or more, for multi-node graphs); they do not shrink on their own.

-- ─── Baseline: capture current row counts ─────────────────────────────────

CREATE TEMP TABLE _bloat_baseline AS
SELECT
    (SELECT COUNT(*) FROM df.instances)     AS inst_before,
    (SELECT COUNT(*) FROM df.nodes)         AS nodes_before;

-- ─── Run a batch of instances with multiple nodes each ────────────────────

DO $$
DECLARE
    i INT;
BEGIN
    FOR i IN 1..10 LOOP
        -- Each graph has 3 nodes (seq of 3 SQL steps)
        PERFORM df.start(
            'SELECT ' || i || ' AS step1'
            ~> ('SELECT ' || i || ' * 2 AS step2')
            ~> ('SELECT ' || i || ' * 3 AS step3'),
            'bloat-test-e4-e5-' || i
        );
    END LOOP;
    RAISE NOTICE 'Started 10 instances (3-step seq each; ≥10 node rows expected)';
END $$;

-- ─── Wait for all instances to complete ───────────────────────────────────

DO $$
DECLARE
    completed INT;
    tries     INT := 0;
BEGIN
    LOOP
        SELECT COUNT(*) INTO completed
        FROM df.instances
        WHERE label LIKE 'bloat-test-e4-e5-%'
          AND lower(status) IN ('completed', 'failed', 'canceled', 'cancelled');

        EXIT WHEN completed >= 10 OR tries > 600;
        PERFORM pg_sleep(0.1);
        tries := tries + 1;
    END LOOP;

    IF completed < 10 THEN
        RAISE EXCEPTION 'TEST FAILED [E4/E5]: only %/10 instances completed within 60s', completed;
    END IF;

    RAISE NOTICE 'All 10 instances completed';
END $$;

-- ─── Measure growth and verify no automatic GC ran ────────────────────────

DO $$
DECLARE
    inst_before  BIGINT;
    nodes_before BIGINT;
    inst_after   BIGINT;
    nodes_after  BIGINT;
    inst_delta   BIGINT;
    nodes_delta  BIGINT;
BEGIN
    SELECT b.inst_before, b.nodes_before
    INTO inst_before, nodes_before
    FROM _bloat_baseline b;

    SELECT COUNT(*) INTO inst_after  FROM df.instances;
    SELECT COUNT(*) INTO nodes_after FROM df.nodes;

    inst_delta  := inst_after  - inst_before;
    nodes_delta := nodes_after - nodes_before;

    RAISE NOTICE 'df.instances: before=%, after=%, delta=%',
        inst_before, inst_after, inst_delta;
    RAISE NOTICE 'df.nodes:     before=%, after=%, delta=%',
        nodes_before, nodes_after, nodes_delta;

    -- Verify instances grew by exactly 10
    IF inst_delta != 10 THEN
        RAISE EXCEPTION 'TEST FAILED [E4]: expected 10 new instance rows, got %', inst_delta;
    END IF;

    -- Verify nodes grew by at least 10 (≥1 node per instance); exact count
    -- depends on graph depth (a 3-step seq generates 5 nodes: 3 SQL + 2 THEN)
    IF nodes_delta < 10 THEN
        RAISE EXCEPTION 'TEST FAILED [E5]: expected at least 10 new node rows, got %', nodes_delta;
    END IF;

    RAISE NOTICE 'PASSED [E4/E5]: % new instance rows, % new node rows (no automatic GC)',
        inst_delta, nodes_delta;
END $$;

-- ─── Report duroxide internal table sizes ─────────────────────────────────

DO $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT
            schemaname || '.' || tablename AS full_name,
            pg_size_pretty(pg_total_relation_size(
                quote_ident(schemaname) || '.' || quote_ident(tablename)
            )) AS total_size
        FROM pg_tables
        WHERE schemaname IN ('df', 'duroxide', '_duroxide')
        ORDER BY pg_total_relation_size(
            quote_ident(schemaname) || '.' || quote_ident(tablename)
        ) DESC
    LOOP
        RAISE NOTICE 'Table bloat: %  %', rec.full_name, rec.total_size;
    END LOOP;

    RAISE NOTICE 'PASSED [E4/E5-b]: duroxide table sizes reported above (no GC exists)';
END $$;

-- ─── Cleanup ──────────────────────────────────────────────────────────────

DROP TABLE _bloat_baseline;

SELECT 'TEST PASSED' AS result;
