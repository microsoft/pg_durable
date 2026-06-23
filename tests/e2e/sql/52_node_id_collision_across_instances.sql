-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: cross-instance node-ID collision — issue #129
-- Node IDs are random 8-hex and only unique *per instance* (df.nodes uses the
-- composite PK (instance_id, id)). This test forces the collision that the
-- composite key and the instance_id-scoped node-status updates exist to handle:
-- two different instances each own a df.nodes row carrying the SAME node id.
-- It asserts that
--   1. both same-id rows coexist (composite PK, not a global single-column key);
--   2. (instance_id, id) addresses exactly one row — the contract that
--      update_node_status now depends on (instance_id is required there);
--   3. df.result() is instance-scoped and returns only the querying instance's
--      own node result, never the colliding sibling's;
--   4. an instance-scoped UPDATE (mirroring update_node_status) affects exactly
--      one row.
--
-- Runs as the privileged harness role (no SET SESSION AUTHORIZATION): it writes
-- runtime-owned columns (status, result, root_node) and a deterministic shared
-- node id directly, which an ordinary RLS user cannot do. submitted_by is set to
-- current_user so the rows are owned by (and visible to) this role regardless of
-- RLS. This is a schema/scoping regression test, not an RLS test (see 15_rls).

DO $$
DECLARE
    role_a       regrole := current_user::regrole;
    shared_rows  INT;
    direct_a     TEXT;
    res_a        TEXT;
    res_b        TEXT;
    updated_rows INT;
BEGIN
    -- Two instances whose root node is the SAME node id 'cccc0051'.
    INSERT INTO df.instances (id, root_node, status, submitted_by)
    VALUES ('aaaa0051', 'cccc0051', 'completed', role_a),
           ('bbbb0051', 'cccc0051', 'completed', role_a);

    -- Same node id under two different instances, with distinct results.
    INSERT INTO df.nodes (id, instance_id, node_type, query, status, result, submitted_by)
    VALUES ('cccc0051', 'aaaa0051', 'SQL', 'SELECT 1', 'completed', '{"v": 111}'::jsonb, role_a),
           ('cccc0051', 'bbbb0051', 'SQL', 'SELECT 1', 'completed', '{"v": 222}'::jsonb, role_a);

    -- 1. Composite PK lets both same-id rows coexist (a global single-column key
    --    would have rejected the second insert).
    SELECT count(*) INTO shared_rows FROM df.nodes WHERE id = 'cccc0051';
    IF shared_rows <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 2 df.nodes rows sharing id cccc0051, got %', shared_rows;
    END IF;

    -- 2. (instance_id, id) addresses exactly one row — the invariant
    --    update_node_status relies on. Deterministic regardless of row order.
    SELECT result::text INTO direct_a
    FROM df.nodes WHERE instance_id = 'aaaa0051' AND id = 'cccc0051';
    IF (direct_a::jsonb ->> 'v')::int <> 111 THEN
        RAISE EXCEPTION 'TEST FAILED: (aaaa0051, cccc0051) addressed wrong row: %', direct_a;
    END IF;

    -- 3. df.result() is instance-scoped: each instance sees ONLY its own node's
    --    result, never the colliding sibling's. If the instance_id scoping in
    --    df.result were lost, the shared node id would match both rows.
    SELECT df.result('aaaa0051') INTO res_a;
    SELECT df.result('bbbb0051') INTO res_b;
    IF res_a IS NULL OR (res_a::jsonb ->> 'v')::int <> 111 THEN
        RAISE EXCEPTION 'TEST FAILED: df.result(aaaa0051) = % (expected v=111)', res_a;
    END IF;
    IF res_b IS NULL OR (res_b::jsonb ->> 'v')::int <> 222 THEN
        RAISE EXCEPTION 'TEST FAILED: df.result(bbbb0051) = % (expected v=222)', res_b;
    END IF;

    -- 4. An instance-scoped UPDATE (the shape update_node_status issues) must
    --    touch exactly one of the two colliding rows.
    UPDATE df.nodes
       SET status = 'completed', updated_at = now()
     WHERE id = 'cccc0051' AND instance_id = 'aaaa0051';
    GET DIAGNOSTICS updated_rows = ROW_COUNT;
    IF updated_rows <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: instance-scoped UPDATE affected % row(s), expected 1', updated_rows;
    END IF;

    -- Cleanup (delete nodes before instances; same-instance FKs are deferred).
    DELETE FROM df.nodes WHERE id = 'cccc0051';
    DELETE FROM df.instances WHERE id IN ('aaaa0051', 'bbbb0051');

    RAISE NOTICE 'PASSED: cross-instance node-ID collision resolved by instance_id scoping';
END $$;

SELECT 'TEST PASSED' AS result;
