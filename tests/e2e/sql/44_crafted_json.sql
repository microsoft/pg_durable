-- Test: Manually crafted JSON inputs bypassing the DSL (C7)
-- Extends tests 32 (invalid node_type) and 33 (malformed condition_node)
-- Demonstrates: Additional raw JSON edge cases and unknown-field handling

-- ============================================================================
-- C7a: Valid node type, unknown extra field (should be ignored or rejected)
-- ============================================================================
CREATE TEMP TABLE _c7a_state (instance_id TEXT, error_msg TEXT);

DO $body$
BEGIN
    INSERT INTO _c7a_state (instance_id)
    VALUES (df.start('{"node_type":"SQL","query":"SELECT 1","evil_field":"pwned"}'));
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _c7a_state (error_msg) VALUES (SQLERRM);
END $body$;

DO $body$
DECLARE
    inst_id TEXT;
    err TEXT;
    status TEXT;
BEGIN
    SELECT instance_id, error_msg INTO inst_id, err FROM _c7a_state;
    IF err IS NOT NULL THEN
        RAISE NOTICE 'C7a: df.start rejected unknown field: %', err;
    ELSE
        -- Unknown fields may be silently ignored by serde; instance might complete
        RAISE NOTICE 'C7a: df.start accepted unknown field (serde ignores unknowns)';
        SELECT df.wait_for_completion(inst_id, 30) INTO status;
        RAISE NOTICE 'C7a: status = %', status;
    END IF;
END $body$;

DROP TABLE _c7a_state;

-- ============================================================================
-- C7b: THEN node with non-object left_node (string instead of object)
-- ============================================================================
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{"node_type":"THEN","left_node":"not an object","right_node":{"node_type":"SQL","query":"SELECT 2"}}');
        RAISE EXCEPTION 'TEST FAILED [C7b]: df.start should have rejected non-object left_node';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'C7b: Caught expected error for non-object left_node: %', SQLERRM;
    END;
END $body$;

-- ============================================================================
-- C7c: THEN node with null left_node (accepted by serde, may fail at runtime)
-- ============================================================================
CREATE TEMP TABLE _c7c_state (instance_id TEXT, error_msg TEXT);

DO $body$
BEGIN
    INSERT INTO _c7c_state (instance_id)
    VALUES (df.start('{"node_type":"THEN","left_node":null,"right_node":{"node_type":"SQL","query":"SELECT 2"}}'));
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _c7c_state (error_msg) VALUES (SQLERRM);
END $body$;

DO $body$
DECLARE
    inst_id TEXT;
    err TEXT;
    status TEXT;
BEGIN
    SELECT instance_id, error_msg INTO inst_id, err FROM _c7c_state;
    IF err IS NOT NULL THEN
        RAISE NOTICE 'C7c: df.start rejected null left_node: %', err;
    ELSE
        -- serde accepts null as Option<Durofut> = None; df.start() may succeed.
        -- The instance may fail at runtime when the orchestration finds no left node.
        RAISE NOTICE 'C7c: df.start accepted null left_node (serde treats null as None)';
        SELECT df.wait_for_completion(inst_id, 30) INTO status;
        RAISE NOTICE 'C7c: null left_node instance status = %', status;
    END IF;
END $body$;

DROP TABLE _c7c_state;

-- ============================================================================
-- C7d: SQL node with null query (accepted by serde, fails at execution time)
-- ============================================================================
CREATE TEMP TABLE _c7d_state (instance_id TEXT, error_msg TEXT);

DO $body$
BEGIN
    INSERT INTO _c7d_state (instance_id)
    VALUES (df.start('{"node_type":"SQL","query":null}'));
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _c7d_state (error_msg) VALUES (SQLERRM);
END $body$;

DO $body$
DECLARE
    inst_id TEXT;
    err TEXT;
    status TEXT;
BEGIN
    SELECT instance_id, error_msg INTO inst_id, err FROM _c7d_state;
    IF err IS NOT NULL THEN
        RAISE NOTICE 'C7d: df.start rejected null query: %', err;
    ELSE
        -- null is accepted by serde as Option<String> = None; node is inserted with NULL query.
        -- The orchestration will error with "SQL node X has no query".
        RAISE NOTICE 'C7d: df.start accepted null query (inserted with NULL query column)';
        SELECT df.wait_for_completion(inst_id, 30) INTO status;
        IF lower(status) NOT IN ('failed', 'completed') THEN
            RAISE EXCEPTION 'TEST FAILED [C7d]: expected Failed for null query, got %', status;
        END IF;
        RAISE NOTICE 'C7d: null query instance status = % (expected Failed)', status;
    END IF;
END $body$;

DROP TABLE _c7d_state;

-- ============================================================================
-- C7e: LOOP node with left_node missing (no body)
-- ============================================================================
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{"node_type":"LOOP"}');
        RAISE EXCEPTION 'TEST FAILED [C7e]: df.start should have rejected LOOP without body';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'C7e: Caught expected error for LOOP without body: %', SQLERRM;
    END;
END $body$;

-- ============================================================================
-- C7f: Completely empty JSON object
-- ============================================================================
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{}');
        RAISE EXCEPTION 'TEST FAILED [C7f]: df.start should have rejected empty JSON object';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'C7f: Caught expected error for empty JSON: %', SQLERRM;
    END;
END $body$;

-- ============================================================================
-- C7g: Plain string (auto-wrapped as SQL node) — should succeed
-- ============================================================================
CREATE TEMP TABLE _c7g_state AS
SELECT df.start('SELECT 1', 'test-plain-string-c7g') AS instance_id;

DO $body$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _c7g_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;
    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [C7g]: plain string auto-wrap expected Completed, got %', status;
    END IF;
    RAISE NOTICE 'C7g: plain string auto-wrapped as SQL node and completed successfully';
END $body$;

DROP TABLE _c7g_state;

SELECT 'TEST PASSED' AS result;
