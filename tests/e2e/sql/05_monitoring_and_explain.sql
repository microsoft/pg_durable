-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 09_monitoring, 10_explain, 31_explain_plain_sql
-- Tests: list_instances, instance_info, status, result, df.explain() on live and dry-run,
--        df.explain() on plain SQL auto-wrap
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 09_monitoring ===

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start('SELECT 123', 'test-monitoring-label');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    found BOOLEAN;
    info_status TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;

    SELECT df.await_instance(inst_id) INTO status;
    
    -- Test list_instances
    SELECT EXISTS (
        SELECT 1 FROM df.list_instances() 
        WHERE list_instances.instance_id = inst_id
    ) INTO found;
    
    IF NOT found THEN
        RAISE EXCEPTION 'TEST FAILED: instance not found in list_instances()';
    END IF;
    
    -- Test instance_info
    SELECT i.status INTO info_status FROM df.instance_info(inst_id) i;
    IF info_status IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: instance_info returned NULL status';
    END IF;
    
    -- Test status
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed, got %', status;
    END IF;
    
    -- Test result
    SELECT r INTO result FROM df.result(inst_id) r;
    IF result NOT LIKE '%123%' THEN
        RAISE EXCEPTION 'TEST FAILED: result should contain 123, got %', result;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: monitoring';
END $$;

DROP TABLE _test_state;

-- === Test: 10_explain ===

-- Test dry-run explain (use $body$ to avoid conflict with inner $$)
DO $body$
DECLARE
    explain_output TEXT;
BEGIN
    SELECT df.explain($$ 'SELECT 1' ~> 'SELECT 2' $$) INTO explain_output;
    
    IF explain_output IS NULL OR explain_output = '' THEN
        RAISE EXCEPTION 'TEST FAILED: explain returned empty output';
    END IF;
    
    IF explain_output NOT LIKE '%SQL%' THEN
        RAISE EXCEPTION 'TEST FAILED: explain should contain SQL nodes, got: %', explain_output;
    END IF;
    
    RAISE NOTICE 'Dry-run explain passed';
END $body$;

-- Test dry-run explain renders RACE branches for both operator and function forms
DO $body$
DECLARE
    explain_output TEXT;
BEGIN
    SELECT df.explain($$ 'SELECT ''winner''' | df.sleep(30) $$) INTO explain_output;

    IF explain_output NOT LIKE '%RACE%'
        OR explain_output NOT LIKE '%branch 1:%'
        OR explain_output NOT LIKE '%branch 2:%'
        OR explain_output NOT LIKE '%SELECT ''winner''%'
        OR explain_output NOT LIKE '%SLEEP 30s%' THEN
        RAISE EXCEPTION 'TEST FAILED: operator RACE explain should show both branches, got: %', explain_output;
    END IF;

    SELECT df.explain($$ df.race('SELECT ''winner''', df.sleep(30)) $$) INTO explain_output;

    IF explain_output NOT LIKE '%RACE%'
        OR explain_output NOT LIKE '%branch 1:%'
        OR explain_output NOT LIKE '%branch 2:%'
        OR explain_output NOT LIKE '%SELECT ''winner''%'
        OR explain_output NOT LIKE '%SLEEP 30s%' THEN
        RAISE EXCEPTION 'TEST FAILED: df.race() explain should show both branches, got: %', explain_output;
    END IF;

    RAISE NOTICE 'Dry-run RACE explain passed';
END $body$;

-- Test live instance explain
CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start('SELECT 1' ~> 'SELECT 2', 'test-explain');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    explain_output TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;

    SELECT df.await_instance(inst_id) INTO status;
    
    SELECT df.explain(inst_id) INTO explain_output;
    
    IF explain_output IS NULL OR explain_output = '' THEN
        RAISE EXCEPTION 'TEST FAILED: explain returned empty output for live instance';
    END IF;
    
    IF explain_output NOT LIKE '%ompleted%' AND explain_output NOT LIKE '%✓%' THEN
        RAISE EXCEPTION 'TEST FAILED: explain should show completion status, got: %', explain_output;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: explain';
END $$;

DROP TABLE _test_state;

-- Test live RACE explain shows the skipped losing branch
CREATE TEMP TABLE _test_race_explain_state (instance_id TEXT);

INSERT INTO _test_race_explain_state
SELECT df.start(df.race('SELECT ''winner''', df.sleep(10)), 'test-race-explain');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    explain_output TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_race_explain_state;

    SELECT df.await_instance(inst_id, 20) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed RACE instance, got %', status;
    END IF;

    SELECT df.explain(inst_id) INTO explain_output;

    IF explain_output NOT LIKE '%RACE%'
        OR explain_output NOT LIKE '%branch 1:%'
        OR explain_output NOT LIKE '%branch 2:%'
        OR explain_output NOT LIKE '%SELECT ''winner''%'
        OR explain_output NOT LIKE '%SLEEP 10s%' THEN
        RAISE EXCEPTION 'TEST FAILED: live RACE explain should show both branches, got: %', explain_output;
    END IF;

    IF explain_output NOT LIKE '%⊘%' THEN
        RAISE EXCEPTION 'TEST FAILED: live RACE explain should show skipped marker for losing branch, got: %', explain_output;
    END IF;

    RAISE NOTICE 'TEST PASSED: live race explain';
END $$;

DROP TABLE _test_race_explain_state;

-- === Test: 31_explain_plain_sql ===

DO $body$
DECLARE
    explain_output TEXT;
BEGIN
    SELECT df.explain('SELECT 1') INTO explain_output;

    IF explain_output IS NULL OR explain_output = '' THEN
        RAISE EXCEPTION 'TEST FAILED: explain returned empty output';
    END IF;

    IF explain_output NOT LIKE '%SQL:%' OR explain_output NOT LIKE '%SELECT 1%' THEN
        RAISE EXCEPTION 'TEST FAILED: explain should show SQL: SELECT 1, got: %', explain_output;
    END IF;

    RAISE NOTICE 'TEST PASSED: explain plain SQL';
END $body$;

-- === Test: multi-instance list ordering + list/instance_info equivalence ===
-- Exercises the batched instance-info reassembly in df.list_instances(): start
-- several same-user instances with distinct outputs, then assert (a) they appear
-- newest-first (created_at DESC) in list_instances(), and (b) function_name,
-- execution_count, and output for each agree with df.instance_info() (the
-- per-instance path), proving the batch lookup reassembles the right metadata
-- against the right id.

CREATE TEMP TABLE _multi_state (n INT, instance_id TEXT);

-- Start three instances in separate statements (separate transactions) with a
-- short gap so created_at (DEFAULT now(), the transaction timestamp) is strictly
-- increasing and the created_at DESC order is deterministic.
INSERT INTO _multi_state SELECT 1, df.start('SELECT 1001', 'sf3-a');
SELECT pg_sleep(0.05);
INSERT INTO _multi_state SELECT 2, df.start('SELECT 1002', 'sf3-b');
SELECT pg_sleep(0.05);
INSERT INTO _multi_state SELECT 3, df.start('SELECT 1003', 'sf3-c');

DO $multi$
DECLARE
    ids TEXT[];
    expected_order TEXT[];
    listed_order TEXT[];
    rec RECORD;
    li RECORD;
    ii RECORD;
    settled INT;
    attempts INT := 0;
BEGIN
    -- Await all three to completion.
    FOR rec IN SELECT instance_id FROM _multi_state LOOP
        PERFORM df.await_instance(rec.instance_id);
    END LOOP;

    SELECT array_agg(instance_id ORDER BY n) INTO ids FROM _multi_state;
    -- created_at DESC => most recently started first => reverse of start order.
    SELECT array_agg(instance_id ORDER BY n DESC) INTO expected_order FROM _multi_state;

    -- await_instance() returns when df.instances.status is terminal, but
    -- duroxide's execution output can become visible a moment later. Both
    -- monitoring paths (list_instances and instance_info) observe the same
    -- eventual state, so wait until output has materialized for all three before
    -- comparing snapshots, otherwise we would race the completion boundary.
    LOOP
        SELECT count(*) INTO settled
        FROM df.list_instances()
        WHERE list_instances.instance_id = ANY(ids) AND output IS NOT NULL;
        EXIT WHEN settled = 3 OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF settled <> 3 THEN
        RAISE EXCEPTION 'TEST FAILED: only % of 3 instances have materialized output in list_instances()', settled;
    END IF;

    -- (a) Order of our three ids within list_instances() output. WITH ORDINALITY
    -- numbers rows in the exact order the function emits them (the just-created
    -- instances are newest, so they sort first under created_at DESC).
    SELECT array_agg(instance_id ORDER BY ord) INTO listed_order
    FROM df.list_instances()
        WITH ORDINALITY AS t(instance_id, label, function_name, status, execution_count, output, ord)
    WHERE t.instance_id = ANY(ids);

    IF listed_order IS DISTINCT FROM expected_order THEN
        RAISE EXCEPTION 'TEST FAILED: list_instances order % != expected created_at DESC order %',
            listed_order, expected_order;
    END IF;

    -- (b) Per-instance equivalence between list_instances() and instance_info().
    -- list_instances.execution_count maps to instance_info.current_execution_id.
    -- Distinct outputs (1001/1002/1003) prove the batch reassembly maps each
    -- instance's metadata back to the right id rather than scrambling rows.
    FOR li IN
        SELECT instance_id, function_name, execution_count, output
        FROM df.list_instances()
        WHERE list_instances.instance_id = ANY(ids)
    LOOP
        SELECT function_name, current_execution_id, output
        INTO ii
        FROM df.instance_info(li.instance_id);

        IF ii.function_name IS DISTINCT FROM li.function_name THEN
            RAISE EXCEPTION 'TEST FAILED: function_name mismatch for %: list=% info=%',
                li.instance_id, li.function_name, ii.function_name;
        END IF;
        IF ii.current_execution_id IS DISTINCT FROM li.execution_count THEN
            RAISE EXCEPTION 'TEST FAILED: execution_count mismatch for %: list=% info=%',
                li.instance_id, li.execution_count, ii.current_execution_id;
        END IF;
        IF ii.output IS DISTINCT FROM li.output THEN
            RAISE EXCEPTION 'TEST FAILED: output mismatch for %: list=% info=%',
                li.instance_id, li.output, ii.output;
        END IF;
    END LOOP;

    RAISE NOTICE 'TEST PASSED: multi-instance ordering + list/instance_info equivalence';
END $multi$;

DROP TABLE _multi_state;

-- === Test: PR4 — label_filter, timestamps, and keyset pagination (issues #87/#146) ===
-- Start five instances that all share one label ('pr4-page') so the label filter
-- scopes df.list_instances() to exactly this set, independent of any other
-- instances this role created earlier in the suite. That makes the keyset
-- pagination assertion self-contained and deterministic. The five are created in
-- two batches: the first three share one transaction timestamp and the last two
-- share a later one, so created_at has ties within each batch -- exercising BOTH
-- branches of the keyset predicate (created_at < cursor, and created_at = cursor
-- AND id > cursor_id).
CREATE TEMP TABLE _page_state (instance_id TEXT);
INSERT INTO _page_state SELECT df.start('SELECT ' || g, 'pr4-page') FROM generate_series(2001, 2003) g;
SELECT pg_sleep(0.05);
INSERT INTO _page_state SELECT df.start('SELECT ' || g, 'pr4-page') FROM generate_series(2004, 2005) g;

DO $page$
DECLARE
    rec RECORD;
    total INT;
    labeled INT;
    with_created INT;
    with_completed INT;
    single_page_cursors INT;
    ref_ids TEXT[];
    paged_ids TEXT[];
    page_ids TEXT[];
    page_cursor TEXT;
    page_n INT;
    cur TEXT;
    pages INT := 0;
    settled INT;
    attempts INT := 0;
    combo_status TEXT;
    combo INT;
    combo_none INT;
BEGIN
    FOR rec IN SELECT instance_id FROM _page_state LOOP
        PERFORM df.await_instance(rec.instance_id);
    END LOOP;

    -- Wait until every instance's output has materialized (same completion-boundary
    -- race the SF-3 block documents).
    LOOP
        SELECT count(*) INTO settled
        FROM df.list_instances(NULL, 100, 'pr4-page')
        WHERE output IS NOT NULL;
        EXIT WHEN settled = 5 OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF settled <> 5 THEN
        RAISE EXCEPTION 'TEST FAILED: only % of 5 pr4-page instances settled', settled;
    END IF;

    -- (a) label_filter returns exactly our five, all carrying that label, and the
    -- timestamps sourced from df.instances are populated (created_at always;
    -- completed_at because every instance completed successfully).
    SELECT count(*),
           count(*) FILTER (WHERE label = 'pr4-page'),
           count(*) FILTER (WHERE created_at IS NOT NULL),
           count(*) FILTER (WHERE completed_at IS NOT NULL)
    INTO total, labeled, with_created, with_completed
    FROM df.list_instances(NULL, 100, 'pr4-page');

    IF total <> 5 OR labeled <> 5 THEN
        RAISE EXCEPTION 'TEST FAILED: label_filter returned % rows (% labeled), expected 5/5', total, labeled;
    END IF;
    IF with_created <> 5 THEN
        RAISE EXCEPTION 'TEST FAILED: % of 5 rows have created_at, expected 5', with_created;
    END IF;
    IF with_completed <> 5 THEN
        RAISE EXCEPTION 'TEST FAILED: % of 5 completed rows have completed_at, expected 5', with_completed;
    END IF;

    -- (a2) status_filter composes with label_filter. The label-only calls above
    -- never push a status placeholder, so this is the only assertion that
    -- exercises the two-filter dynamic placeholder numbering (status = $1 AND
    -- label = $2). Read the actual stored status of our set (uniform: all five
    -- completed) rather than hard-coding the literal, then assert the combined
    -- filter returns exactly those five and that a non-matching status returns none.
    SELECT status INTO combo_status FROM df.list_instances(NULL, 1, 'pr4-page');
    SELECT count(*) INTO combo FROM df.list_instances(combo_status, 100, 'pr4-page');
    IF combo <> 5 THEN
        RAISE EXCEPTION 'TEST FAILED: status+label filter returned % rows for status %, expected 5', combo, combo_status;
    END IF;
    SELECT count(*) INTO combo_none
    FROM df.list_instances('definitely-not-a-status', 100, 'pr4-page');
    IF combo_none <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: status+label filter with non-matching status returned % rows, expected 0', combo_none;
    END IF;

    -- (b) A single page large enough to hold the whole set must report no further
    -- page: next_cursor is NULL on every row.
    SELECT count(*) FILTER (WHERE next_cursor IS NOT NULL) INTO single_page_cursors
    FROM df.list_instances(NULL, 100, 'pr4-page');
    IF single_page_cursors <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: single full page exposed % non-null next_cursor', single_page_cursors;
    END IF;

    -- Authoritative order (created_at DESC, id ASC) from one unpaginated call.
    SELECT array_agg(instance_id ORDER BY ord) INTO ref_ids
    FROM df.list_instances(NULL, 100, 'pr4-page')
        WITH ORDINALITY AS t(instance_id, label, function_name, status, execution_count, output, created_at, completed_at, next_cursor, ord);

    -- (c) Walk the same set two-at-a-time via next_cursor and rebuild the id list.
    -- A correct keyset traversal must reproduce the unpaginated order exactly with
    -- no duplicates and no gaps.
    cur := NULL;
    paged_ids := '{}';
    LOOP
        SELECT array_agg(instance_id ORDER BY ord), max(next_cursor), count(*)
        INTO page_ids, page_cursor, page_n
        FROM df.list_instances(NULL, 2, 'pr4-page', cur)
            WITH ORDINALITY AS t(instance_id, label, function_name, status, execution_count, output, created_at, completed_at, next_cursor, ord);

        EXIT WHEN page_n = 0;
        paged_ids := paged_ids || page_ids;
        pages := pages + 1;

        -- A non-final page (cursor present) must be full and advance; the final
        -- page carries a NULL cursor and ends the walk.
        IF page_cursor IS NOT NULL AND page_n <> 2 THEN
            RAISE EXCEPTION 'TEST FAILED: non-final page had % rows, expected 2', page_n;
        END IF;
        EXIT WHEN page_cursor IS NULL;
        cur := page_cursor;
        EXIT WHEN pages > 50;
    END LOOP;

    IF paged_ids IS DISTINCT FROM ref_ids THEN
        RAISE EXCEPTION 'TEST FAILED: paginated order % != unpaginated order %', paged_ids, ref_ids;
    END IF;
    IF pages <> 3 THEN
        RAISE EXCEPTION 'TEST FAILED: 5 rows at limit 2 produced % pages, expected 3', pages;
    END IF;

    -- (d) A malformed cursor is a client error, not a silent restart.
    BEGIN
        PERFORM instance_id FROM df.list_instances(NULL, 2, 'pr4-page', 'zz');
        RAISE EXCEPTION 'TEST FAILED: invalid after_cursor did not raise';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%TEST FAILED%' THEN
            RAISE;
        END IF;
        -- expected: df.list_instances: invalid after_cursor
    END;

    -- (d2) A structurally valid cursor (correct hex + recognized version) that
    -- carries a non-timestamp payload must ALSO be rejected. Without up-front
    -- validation this would fail the ::timestamptz cast deep in the query and be
    -- swallowed as an empty page -- silently ending a client's pagination instead
    -- of surfacing the bad token. The payload below decodes cleanly to
    -- ('not-a-timestamp', 'abc') under version v1.
    BEGIN
        PERFORM instance_id FROM df.list_instances(
            NULL, 2, 'pr4-page',
            encode(convert_to('v1|not-a-timestamp|abc', 'UTF8'), 'hex'));
        RAISE EXCEPTION 'TEST FAILED: malformed-timestamp after_cursor did not raise';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%TEST FAILED%' THEN
            RAISE;
        END IF;
        -- expected: df.list_instances: invalid after_cursor
    END;

    RAISE NOTICE 'TEST PASSED: label_filter + timestamps + keyset pagination';
END $page$;

DROP TABLE _page_state;

-- === Test: PR4 — completed_at is NULL for a non-completed (failed) instance ===
-- df.instances.completed_at is set only on successful completion (it stays NULL
-- for failed/cancelled instances). The pr4-page block above covers the completed
-- case; this block covers the failed case so the timestamp column's contract is
-- asserted in both directions. 'SELECT 1/0' fails the SQL node -> the instance
-- ends 'failed'.
CREATE TEMP TABLE _fail_state (instance_id TEXT);
INSERT INTO _fail_state SELECT df.start('SELECT 1/0', 'pr4-fail');

DO $fail$
DECLARE
    fid TEXT;
    fstatus TEXT;
    seen INT;
    fcreated INT;
    fcompleted INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO fid FROM _fail_state;
    fstatus := df.await_instance(fid);
    IF fstatus <> 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: pr4-fail instance status = %, expected failed', fstatus;
    END IF;

    -- Wait until the failed instance is resolvable through list_instances (its
    -- duroxide info row is available). A failed instance has no output, so we
    -- cannot wait on output IS NOT NULL like the completed case does.
    LOOP
        SELECT count(*) INTO seen FROM df.list_instances(NULL, 100, 'pr4-fail');
        EXIT WHEN seen = 1 OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF seen <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: pr4-fail instance not listed (seen=%)', seen;
    END IF;

    SELECT count(*) FILTER (WHERE created_at IS NOT NULL),
           count(*) FILTER (WHERE completed_at IS NOT NULL)
    INTO fcreated, fcompleted
    FROM df.list_instances(NULL, 100, 'pr4-fail');

    IF fcreated <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: failed instance created_at not populated (count=%)', fcreated;
    END IF;
    IF fcompleted <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: failed instance has completed_at set (count=%), expected NULL', fcompleted;
    END IF;

    RAISE NOTICE 'TEST PASSED: completed_at is NULL for failed instance';
END $fail$;

DROP TABLE _fail_state;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
