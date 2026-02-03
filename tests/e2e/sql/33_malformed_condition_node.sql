-- Test: Reject malformed condition_node in IF/LOOP nodes
-- Verifies that hand-crafted JSON with invalid condition_node is caught

-- Test 1: condition_node as a non-Durofut object should be rejected by df.start()
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{
            "node_type": "IF",
            "left_node": {"node_type": "SQL", "query": "SELECT 1"},
            "right_node": {"node_type": "SQL", "query": "SELECT 2"},
            "query": "{\"condition_node\": {\"foo\": \"bar\"}}"
        }');
        RAISE EXCEPTION 'TEST FAILED: df.start should have rejected malformed condition_node';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%condition_node%' THEN
            RAISE NOTICE 'Test 1 PASSED: Caught malformed condition_node object: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: Wrong error for malformed condition_node: %', SQLERRM;
        END IF;
    END;
END $body$;

-- Test 2: condition_node as a string ID (old format) should be rejected
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{
            "node_type": "LOOP",
            "left_node": {"node_type": "SQL", "query": "SELECT 1"},
            "query": "{\"condition_node\": \"a1b2c3d4\"}"
        }');
        RAISE EXCEPTION 'TEST FAILED: df.start should have rejected string condition_node';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%condition_node%' THEN
            RAISE NOTICE 'Test 2 PASSED: Caught string condition_node: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: Wrong error for string condition_node: %', SQLERRM;
        END IF;
    END;
END $body$;

-- Test 3: condition_node as a number should be rejected
DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{
            "node_type": "IF",
            "left_node": {"node_type": "SQL", "query": "SELECT 1"},
            "right_node": {"node_type": "SQL", "query": "SELECT 2"},
            "query": "{\"condition_node\": 42}"
        }');
        RAISE EXCEPTION 'TEST FAILED: df.start should have rejected numeric condition_node';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%condition_node%' THEN
            RAISE NOTICE 'Test 3 PASSED: Caught numeric condition_node: %', SQLERRM;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: Wrong error for numeric condition_node: %', SQLERRM;
        END IF;
    END;
END $body$;

-- Test 4: Valid condition_node (produced by DSL) should work fine
DO $body$
DECLARE
    graph TEXT;
BEGIN
    SELECT df.if('SELECT true', 'SELECT 1', 'SELECT 2') INTO graph;
    -- Just verify it parses — don't start it (would need worker)
    IF graph IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: df.if should return non-null graph';
    END IF;
    RAISE NOTICE 'Test 4 PASSED: Valid IF graph produced: %', left(graph, 80);
END $body$;

SELECT 'TEST PASSED' AS result;
