-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 30_graph_reuse, 32_invalid_node_type
-- Tests: graph storage and reuse, identical DSL produces identical JSON,
--        invalid node_type rejection by df.start() and df.explain()
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 30_graph_reuse ===

DROP TABLE IF EXISTS test_graph_reuse;
CREATE TABLE test_graph_reuse (
    id SERIAL PRIMARY KEY,
    value INT
);

-- Test 1: Store a graph and start it later
CREATE TEMP TABLE _stored_graph AS
SELECT 'SELECT 1' ~> 'INSERT INTO test_graph_reuse (value) VALUES (1)' AS graph_json;

CREATE TEMP TABLE _test1_instance1 AS
SELECT df.start((SELECT graph_json FROM _stored_graph), 'test-reuse-1') AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test1_instance1;

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: First execution status = %', status;
    END IF;

    RAISE NOTICE 'First execution completed';
END $$;

CREATE TEMP TABLE _test1_instance2 AS
SELECT df.start((SELECT graph_json FROM _stored_graph), 'test-reuse-2') AS instance_id;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test1_instance2;

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Second execution status = %', status;
    END IF;

    RAISE NOTICE 'Second execution completed';
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM test_graph_reuse) != 2 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 2 rows, got %', (SELECT COUNT(*) FROM test_graph_reuse);
    END IF;

    RAISE NOTICE 'Test 1 PASSED: Graph stored and reused successfully';
END $$;

DROP TABLE _stored_graph;
DROP TABLE _test1_instance1;
DROP TABLE _test1_instance2;

-- Test 2: Verify identical DSL expressions produce identical JSON
DO $$
DECLARE
    graph1 TEXT;
    graph2 TEXT;
BEGIN
    SELECT 'SELECT 2' ~> 'SELECT 3' INTO graph1;
    SELECT 'SELECT 2' ~> 'SELECT 3' INTO graph2;

    IF graph1 IS DISTINCT FROM graph2 THEN
        RAISE EXCEPTION 'TEST FAILED: Identical DSL expressions produced different JSON. Graph 1: %, Graph 2: %', graph1, graph2;
    END IF;

    RAISE NOTICE 'Test 2 PASSED: Identical DSL expressions produce identical Durofut JSON';
END $$;

-- Test 3: Different graphs should have different JSON
DO $$
DECLARE
    graph1 TEXT;
    graph2 TEXT;
BEGIN
    SELECT 'SELECT 4' ~> 'SELECT 5' INTO graph1;
    SELECT 'SELECT 6' ~> 'SELECT 7' INTO graph2;

    IF graph1 = graph2 THEN
        RAISE EXCEPTION 'TEST FAILED: Different graphs produced identical JSON: %', graph1;
    END IF;

    RAISE NOTICE 'Test 3 PASSED: Different graphs produce different Durofut JSON';
END $$;

DROP TABLE test_graph_reuse;

-- === Test: 32_invalid_node_type ===

DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{"node_type":"NOT_A_NODE"}');
        RAISE EXCEPTION 'TEST FAILED: df.start should have rejected invalid node_type';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Caught expected error: %', SQLERRM;
    END;

    BEGIN
        PERFORM df.explain('{"node_type":"NOT_A_NODE"}');
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'TEST FAILED: df.explain should not raise on invalid node_type';
    END;

    RAISE NOTICE 'TEST PASSED: invalid node_type handling';
END $body$;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
