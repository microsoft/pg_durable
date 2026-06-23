-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.list_instances() timestamp columns and df.list_instances_paginated()
--
-- Verifies:
--   1. df.list_instances() returns created_at / completed_at, non-null for
--      completed instances.
--   2. df.list_instances_paginated() pages through every visible instance with
--      a small page size, in the same (created_at DESC, id DESC) order as
--      df.list_instances(), with no gaps or duplicates.
--   3. total_count matches the number of visible instances and next_cursor is
--      NULL only on the final page.
--
-- The test is robust to instances created by earlier E2E tests (df_e2e_user is
-- shared across the run): it compares pagination output against the full
-- df.list_instances() result rather than asserting absolute counts.

SET SESSION AUTHORIZATION df_e2e_user;

-- ===========================================================================
-- Setup: start a handful of instances and wait for completion.
-- ===========================================================================

DROP TABLE IF EXISTS _paginate_known;
CREATE TEMP TABLE _paginate_known (instance_id TEXT);

-- Start the instances as a committed top-level statement so the background
-- worker can see them (df.start + await in the same transaction would deadlock:
-- the worker runs in a separate session and only sees committed rows).
INSERT INTO _paginate_known(instance_id)
SELECT df.start('SELECT ' || g, 'paginate-test-' || g)
FROM generate_series(1, 5) g;

DO $$
DECLARE
    r      RECORD;
    status TEXT;
BEGIN
    FOR r IN SELECT instance_id FROM _paginate_known LOOP
        status := df.await_instance(r.instance_id, 30);
        IF lower(status) != 'completed' THEN
            RAISE EXCEPTION 'Setup failed: instance % expected completed, got %', r.instance_id, status;
        END IF;
    END LOOP;
END $$;

-- ===========================================================================
-- 1. df.list_instances() exposes created_at / completed_at.
-- ===========================================================================

DO $$
DECLARE
    missing INT;
BEGIN
    SELECT count(*) INTO missing
    FROM df.list_instances(NULL, 10000) l
    JOIN _paginate_known k ON k.instance_id = l.instance_id
    WHERE l.created_at IS NULL OR l.completed_at IS NULL;

    IF missing > 0 THEN
        RAISE EXCEPTION 'FAILED: % completed instances have NULL created_at/completed_at', missing;
    END IF;

    RAISE NOTICE 'PASSED: created_at/completed_at populated for completed instances';
END $$;

-- ===========================================================================
-- 2 & 3. Page through every instance and compare against df.list_instances().
-- ===========================================================================

-- Expected order: df.list_instances() already orders by (created_at DESC, id DESC).
DROP TABLE IF EXISTS _expected_order;
CREATE TEMP TABLE _expected_order AS
SELECT row_number() OVER () AS seq, instance_id
FROM df.list_instances(NULL, 10000);

DROP TABLE IF EXISTS _collected;
CREATE TEMP TABLE _collected (seq INT, instance_id TEXT);

DO $$
DECLARE
    v_cursor     TEXT := NULL;
    v_next       TEXT;
    v_total      BIGINT;
    v_seq        INT := 0;
    v_page_rows  INT;
    v_iterations INT := 0;
    rec          RECORD;
    v_expected   BIGINT;
BEGIN
    SELECT count(*) INTO v_expected FROM _expected_order;

    LOOP
        v_iterations := v_iterations + 1;
        IF v_iterations > 1000 THEN
            RAISE EXCEPTION 'FAILED: pagination did not terminate (possible cursor bug)';
        END IF;

        v_page_rows := 0;
        v_next := NULL;
        FOR rec IN
            SELECT * FROM df.list_instances_paginated(NULL, 2, v_cursor)
        LOOP
            v_seq := v_seq + 1;
            v_page_rows := v_page_rows + 1;
            INSERT INTO _collected(seq, instance_id) VALUES (v_seq, rec.instance_id);
            v_next := rec.next_cursor;
            v_total := rec.total_count;
        END LOOP;

        -- Empty page ends pagination (e.g. zero visible instances).
        EXIT WHEN v_page_rows = 0;

        -- total_count must reflect all visible instances on every page.
        IF v_total != v_expected THEN
            RAISE EXCEPTION 'FAILED: total_count % does not match visible instance count %',
                v_total, v_expected;
        END IF;

        -- next_cursor is NULL only on the final page.
        EXIT WHEN v_next IS NULL;
        v_cursor := v_next;
    END LOOP;

    RAISE NOTICE 'PASSED: paginated through % instances in % pages', v_seq, v_iterations;
END $$;

-- The paginated sequence must exactly match df.list_instances() order.
DO $$
DECLARE
    mismatches    INT;
    collected_cnt INT;
    expected_cnt  INT;
    dup_cnt       INT;
    known_missing INT;
BEGIN
    SELECT count(*) INTO collected_cnt FROM _collected;
    SELECT count(*) INTO expected_cnt FROM _expected_order;

    IF collected_cnt != expected_cnt THEN
        RAISE EXCEPTION 'FAILED: paginated row count % != df.list_instances() count %',
            collected_cnt, expected_cnt;
    END IF;

    -- No duplicate instance_ids across pages.
    SELECT count(*) INTO dup_cnt FROM (
        SELECT instance_id FROM _collected GROUP BY instance_id HAVING count(*) > 1
    ) d;
    IF dup_cnt > 0 THEN
        RAISE EXCEPTION 'FAILED: % instance_id(s) appeared on more than one page', dup_cnt;
    END IF;

    -- Same order, position by position.
    SELECT count(*) INTO mismatches
    FROM _collected c
    JOIN _expected_order e ON e.seq = c.seq
    WHERE c.instance_id != e.instance_id;
    IF mismatches > 0 THEN
        RAISE EXCEPTION 'FAILED: % positions differ between paginated and list order', mismatches;
    END IF;

    -- All known instances appear in the paginated output.
    SELECT count(*) INTO known_missing
    FROM _paginate_known k
    WHERE NOT EXISTS (SELECT 1 FROM _collected c WHERE c.instance_id = k.instance_id);
    IF known_missing > 0 THEN
        RAISE EXCEPTION 'FAILED: % known instances missing from paginated output', known_missing;
    END IF;

    RAISE NOTICE 'PASSED: paginated output matches df.list_instances() exactly';
END $$;

-- ===========================================================================
-- Cleanup
-- ===========================================================================

DROP TABLE _collected;
DROP TABLE _expected_order;
DROP TABLE _paginate_known;

SELECT 'TEST PASSED: list_instances_paginated' AS result;
