-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: df.nodes composite primary key (instance_id, id) — issue #129
-- Verifies two things:
--   1. Schema contract: df.nodes uses a composite PRIMARY KEY (instance_id, id)
--      instead of a global single-column key, and the legacy
--      nodes_instance_node_key UNIQUE constraint is gone (promoted to the PK).
--   2. Regression: a multi-node workflow still completes end-to-end, every node
--      row is updated to 'completed' under instance_id scoping, and df.result()
--      returns the root result. This exercises the instance_id-scoped node-status
--      updates and df.result() lookup that accompany the composite key.

SET SESSION AUTHORIZATION df_e2e_user;

-- === Part 1: schema contract — composite primary key ===
DO $$
DECLARE
    pk_def        TEXT;
    legacy_unique BOOLEAN;
BEGIN
    SELECT pg_get_constraintdef(c.oid) INTO pk_def
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace ns ON ns.oid = t.relnamespace
    WHERE ns.nspname = 'df' AND t.relname = 'nodes' AND c.contype = 'p';

    IF pk_def IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: df.nodes has no primary key';
    END IF;

    -- pg_get_constraintdef reports key columns in constraint order.
    IF pk_def NOT LIKE 'PRIMARY KEY (instance_id, id)%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected composite PK (instance_id, id), got: %', pk_def;
    END IF;

    -- The composite UNIQUE was promoted to the PK, so it must no longer exist.
    SELECT EXISTS(
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace ns ON ns.oid = t.relnamespace
        WHERE ns.nspname = 'df'
          AND t.relname = 'nodes'
          AND c.conname = 'nodes_instance_node_key'
    ) INTO legacy_unique;

    IF legacy_unique THEN
        RAISE EXCEPTION 'TEST FAILED: legacy nodes_instance_node_key UNIQUE still present';
    END IF;

    RAISE NOTICE 'PASSED: df.nodes composite primary key (instance_id, id)';
END $$;

-- === Part 2: regression — multi-node workflow under instance_id scoping ===
CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    'SELECT 21 AS num' |=> 'a'
    ~> 'SELECT ($a::int * 2) AS doubled',
    'test-composite-pk-regression'
);

DO $$
DECLARE
    inst_id        TEXT;
    status         TEXT;
    node_total     INT;
    node_completed INT;
    bad_instance   INT;
    result_text    TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing composite-PK regression: %', inst_id;

    SELECT df.await_instance(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;

    -- Every node of this instance must have been updated to 'completed'. If the
    -- instance_id-scoped UPDATE in update_node_status were wrong, some node would
    -- linger in 'pending'/'running'.
    SELECT count(*),
           count(*) FILTER (WHERE n.status = 'completed'),
           count(*) FILTER (WHERE n.instance_id IS DISTINCT FROM inst_id)
      INTO node_total, node_completed, bad_instance
    FROM df.nodes n
    WHERE n.instance_id = inst_id;

    IF node_total < 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected a multi-node graph, got % node(s)', node_total;
    END IF;

    IF node_completed <> node_total THEN
        RAISE EXCEPTION 'TEST FAILED: % of % nodes completed', node_completed, node_total;
    END IF;

    IF bad_instance <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: % node(s) have a mismatched instance_id', bad_instance;
    END IF;

    -- df.result() is scoped by instance_id; it must return the root node's
    -- result. The root SQL ('SELECT ($a::int * 2) AS doubled') returns a row
    -- set, so df.result wraps it as {"rows": [{"doubled": 42}], "row_count": 1}.
    -- Assert the exact nested field/value rather than a loose substring so a
    -- regression that surfaced a different node's result (or lost scoping)
    -- cannot pass on an incidental '42' appearing somewhere in the payload.
    SELECT df.result(inst_id) INTO result_text;
    IF result_text IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: df.result() returned NULL';
    END IF;
    IF (result_text::jsonb #>> '{rows,0,doubled}') IS NULL
       OR (result_text::jsonb #>> '{rows,0,doubled}')::int <> 42
       OR (result_text::jsonb ->> 'row_count')::int <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: expected root result rows[0].doubled = 42 (row_count 1), got %', result_text;
    END IF;

    RAISE NOTICE 'PASSED: composite-PK regression (% nodes completed)', node_total;
END $$;

DROP TABLE _test_state;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
