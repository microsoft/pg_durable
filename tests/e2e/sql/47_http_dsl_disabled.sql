-- E2E Test: df.http() raises an error at DSL call time when no http Cargo feature
-- is compiled in.
--
-- This test runs in the "http-disabled" phase, which builds pg_durable without any
-- http-allow-* features.  df.http() must raise immediately at SQL call time (before
-- df.start() is ever called), not just at execution time.

-- ============================================================================
-- Test 1: df.http() raises at DSL construction time when HTTP is disabled
-- ============================================================================

DO $$
DECLARE
    caught BOOLEAN := false;
BEGIN
    BEGIN
        -- This call should raise an error immediately — no df.start() needed.
        PERFORM df.http('https://example.com/path', 'GET');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%df.http() is disabled%' THEN
            caught := true;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected error message: %', SQLERRM;
        END IF;
    END;

    IF NOT caught THEN
        RAISE EXCEPTION 'TEST FAILED: df.http() should raise at DSL time when HTTP is disabled';
    END IF;

    RAISE NOTICE 'TEST PASSED: http_dsl_disabled_raises';
END $$;

-- ============================================================================
-- Test 2: Crafting an HTTP node by passing raw JSON to df.start() bypasses the
-- DSL-time guard but is still blocked at execution time.
--
-- df.start() accepts a serialized Durofut JSON string directly, so a caller
-- can construct an HTTP node without ever touching df.http().  The execution-
-- time defence in execute_http (validate_url_allowlist) must catch this.
-- ============================================================================

CREATE TEMP TABLE _test_http_bypass (instance_id TEXT);

-- Pass a hand-crafted HTTP node JSON straight to df.start().
-- df.start() accepts raw Durofut JSON, so this bypasses the df.http() guard.
INSERT INTO _test_http_bypass
SELECT df.start(
    '{"node_type":"HTTP","query":"{\"url\":\"https://example.com/path\",\"method\":\"GET\",\"body\":null,\"headers\":null,\"timeout_seconds\":5}"}',
    'test-http-bypass-attempt'
);

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_bypass;

    -- Wait up to 30 s; the request must fail (not complete or time out).
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected status = failed, got %', status;
    END IF;

    -- The node result should contain the execution-time block message.
    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%outbound HTTP requests are disabled%' THEN
        RAISE EXCEPTION
            'TEST FAILED: expected "outbound HTTP requests are disabled" in node result, got: %',
            node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: http_execution_blocked_without_feature';
END $$;

DROP TABLE _test_http_bypass;

SELECT 'TEST PASSED' AS result;
