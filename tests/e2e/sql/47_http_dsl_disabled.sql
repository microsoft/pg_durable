-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- E2E Test: Explicitly disabled HTTP is blocked at DSL and execution time.
--
-- This test runs in the "http-disabled" phase with http_security = 'disabled'.
-- df.http() must raise immediately, before df.start() is called.
-- The requested hostname is explicitly allowed by the GUC: a configured list
-- must not enable HTTP when the security mode is disabled.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_settings
        WHERE name = 'pg_durable.http_security'
          AND setting = 'disabled' AND boot_val = 'restricted'
          AND context = 'postmaster' AND vartype = 'enum'
          AND source = 'configuration file' AND NOT pending_restart
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP must be explicitly disabled at startup';
    END IF;
    IF current_setting('pg_durable.http_allowed_domains') IS DISTINCT FROM 'example.com' THEN
        RAISE EXCEPTION 'TEST FAILED: http-disabled phase requires the example.com allowlist';
    END IF;
END $$;

SET SESSION AUTHORIZATION df_e2e_user;

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

    caught := false;
    BEGIN
        PERFORM df.http_multipart('https://example.com/path', parts => '[{"name":"file","data_b64":"aA=="}]');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%df.http_multipart() is disabled%' THEN
            caught := true;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'TEST FAILED: multipart should be disabled'; END IF;

    caught := false;
    BEGIN
        PERFORM df.http(df.endpoint('missing_server', '/path'), 'GET');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%df.http() is disabled%' THEN
            caught := true;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'TEST FAILED: typed HTTP should be disabled'; END IF;
    caught := false;
    BEGIN
        PERFORM df.http_multipart(df.endpoint('missing_server', '/path'), parts => '[{"name":"file","data_b64":"aA=="}]');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%df.http_multipart() is disabled%' THEN
            caught := true;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT caught THEN RAISE EXCEPTION 'TEST FAILED: typed multipart should be disabled'; END IF;

    RAISE NOTICE 'TEST PASSED: http_dsl_disabled_raises';
END $$;

-- ============================================================================
-- Test 2: Crafting an HTTP node by passing raw JSON to df.start() bypasses the
-- DSL-time guard but is still blocked at execution time.
--
-- df.start() accepts a serialized Durofut JSON string directly, so a caller
-- can construct an HTTP node without ever touching df.http().  The execution-
-- time defence in both HTTP activities must catch this.
-- ============================================================================

CREATE TEMP TABLE _test_http_bypass (instance_id TEXT, node_type TEXT);

-- Pass a hand-crafted HTTP node JSON straight to df.start().
-- df.start() accepts raw Durofut JSON, so this bypasses the df.http() guard.
INSERT INTO _test_http_bypass
SELECT df.start(
    jsonb_build_object(
        'node_type', node_type,
        'query', jsonb_build_object(
            'url', 'https://example.com/path', 'method', 'POST',
            'parts', '[{"name":"field","data_b64":"dmFsdWU="}]'::jsonb,
            'timeout_seconds', 5
        )::text
    )::text,
    'test-http-bypass-' || node_type
), node_type
FROM (VALUES ('HTTP'), ('HTTP_MULTIPART')) AS node_types(node_type);

DO $$
DECLARE
    test_case   RECORD;
    status      TEXT;
    node_result TEXT;
BEGIN
    FOR test_case IN SELECT * FROM _test_http_bypass ORDER BY node_type LOOP
        SELECT df.await_instance(test_case.instance_id, 30) INTO status;
        SELECT result::text INTO node_result
        FROM df.nodes
        WHERE instance_id = test_case.instance_id AND node_type = test_case.node_type;

        IF status IS DISTINCT FROM 'failed'
           OR node_result IS NULL
           OR node_result NOT ILIKE '%outbound HTTP requests are disabled%' THEN
            RAISE EXCEPTION 'TEST FAILED: disabled % request: status = %, result = %',
                test_case.node_type, status, node_result;
        END IF;
    END LOOP;

    RAISE NOTICE 'TEST PASSED: http_execution_blocked_by_startup_policy';
END $$;

DROP TABLE _test_http_bypass;
RESET SESSION AUTHORIZATION;

SELECT 'TEST PASSED' AS result;
