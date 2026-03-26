-- E2E Test: SSRF Protection for df.http()
-- Tests that HTTP requests to private/reserved IP ranges are blocked.
-- Spec: docs/spec-ssrf-protection.md

-- ============================================================================
-- Test 1: Block cloud metadata endpoint (link-local 169.254.169.254)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf1 (instance_id TEXT);

INSERT INTO _test_ssrf1 SELECT df.start(
    df.http('http://169.254.169.254/latest/meta-data/', 'GET'),
    'test-ssrf-metadata'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf1;
    RAISE NOTICE 'Testing SSRF block (metadata endpoint): %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: SSRF metadata request should have failed, got status = %', status;
    END IF;

    -- Verify the error mentions bare IP (allow-list blocks all IPs first)
    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%bare IP%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "bare IP" in error, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_block_metadata';
END $$;

DROP TABLE _test_ssrf1;

-- ============================================================================
-- Test 2: Block localhost (127.0.0.1)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf2 (instance_id TEXT);

INSERT INTO _test_ssrf2 SELECT df.start(
    df.http('http://127.0.0.1:9999/probe', 'GET'),
    'test-ssrf-localhost'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf2;
    RAISE NOTICE 'Testing SSRF block (localhost): %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: SSRF localhost request should have failed, got status = %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%bare IP%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "bare IP" in error, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_block_localhost';
END $$;

DROP TABLE _test_ssrf2;

-- ============================================================================
-- Test 3: Block unsupported URL scheme (file://) — DSL time and execution time
--
-- df.http() validates the scheme at DSL construction time, so the error is
-- raised before df.start() is ever called.  Test 12 (below) covers the
-- execution-time path via a hand-crafted raw JSON bypass.
-- ============================================================================

DO $$
DECLARE
    caught BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM df.http('file:///etc/passwd', 'GET');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%unsupported URL scheme%' THEN
            caught := true;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected error for file:// scheme: %', SQLERRM;
        END IF;
    END;

    IF NOT caught THEN
        RAISE EXCEPTION 'TEST FAILED: df.http() should raise at DSL time for file:// scheme';
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_block_file_scheme';
END $$;

-- ============================================================================
-- Test 4: Non-Azure domain is blocked by allow-list (example.com)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf4 (instance_id TEXT);

INSERT INTO _test_ssrf4 SELECT df.start(
    df.http('https://example.com/path', 'GET'),
    'test-ssrf-non-azure'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf4;
    RAISE NOTICE 'Testing non-Azure domain blocked: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: non-Azure domain should be blocked, got status = %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%not in the allowed%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "not in the allowed" in error, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_non_azure_blocked';
END $$;

DROP TABLE _test_ssrf4;

-- ============================================================================
-- Test 5: Azure Blob domain passes allow-list (DNS/network may fail, not allow-list)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf5 (instance_id TEXT);

INSERT INTO _test_ssrf5 SELECT df.start(
    df.http('https://testaccount.blob.core.windows.net/container', 'GET'),
    'test-ssrf-azure-blob-allowed'
);

DO $$
DECLARE
    inst_id TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf5;
    RAISE NOTICE 'Testing Azure Blob domain passes allow-list: %', inst_id;

    PERFORM df.wait_for_completion(inst_id);

    -- May fail at DNS/network level, but must NOT fail due to allow-list
    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result ILIKE '%not in the allowed%' THEN
        RAISE EXCEPTION 'TEST FAILED: Azure Blob domain should pass allow-list, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_azure_blob_allowed';
END $$;

DROP TABLE _test_ssrf5;

-- ============================================================================
-- Test 6: Bare public IP address is blocked
-- ============================================================================

CREATE TEMP TABLE _test_ssrf6 (instance_id TEXT);

INSERT INTO _test_ssrf6 SELECT df.start(
    df.http('https://8.8.8.8/path', 'GET'),
    'test-ssrf-bare-public-ip'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf6;
    RAISE NOTICE 'Testing bare public IP blocked: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: bare IP should be blocked, got status = %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%bare IP%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "bare IP" in error, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_bare_ip_blocked';
END $$;

DROP TABLE _test_ssrf6;

-- ============================================================================
-- Test 7: management.azure.com is intentionally absent from allow-list
-- (Azure control-plane — must not be callable from workflows)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf7 (instance_id TEXT);

INSERT INTO _test_ssrf7 SELECT df.start(
    df.http('https://mysubscription.management.azure.com/subscriptions', 'GET'),
    'test-ssrf-mgmt-azure-blocked'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf7;
    RAISE NOTICE 'Testing management.azure.com blocked: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: management.azure.com should be blocked, got status = %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%not in the allowed%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "not in the allowed" in error, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_mgmt_azure_blocked';
END $$;

DROP TABLE _test_ssrf7;

-- ============================================================================
-- Test 8: Redirects are not followed (response returned as-is, no bypass)
-- httpbingo.org/status/302 always returns 302 with a Location header.
-- With Policy::none() the client returns that response directly; if redirects
-- were followed we would get a 2xx from the final destination instead.
-- ============================================================================

CREATE TEMP TABLE _test_ssrf8 (instance_id TEXT);

INSERT INTO _test_ssrf8 SELECT df.start(
    df.http('https://httpbin.org/status/302', 'GET') |=> 'response'
    ~> 'SELECT ($response::jsonb->>''status'')::int AS status_code',
    'test-ssrf-redirect-blocked'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_result TEXT;
    http_status INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf8;
    RAISE NOTICE 'Testing redirect not followed: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: redirect request should complete (return 3xx), got status = %', status;
    END IF;

    -- The HTTP node result must contain a 3xx status (redirect not followed)
    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    SELECT (node_result::jsonb->>'status')::int INTO http_status;

    IF http_status IS NULL OR http_status NOT BETWEEN 300 AND 399 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 3xx status (redirect not followed), got HTTP %', http_status;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_redirect_not_followed (got HTTP %)', http_status;
END $$;

DROP TABLE _test_ssrf8;

-- ============================================================================
-- Test 9: All Azure domain suffixes pass the allow-list
-- (DNS/network failures are acceptable; allow-list rejections are not)
--
-- Mirrors AZURE_DOMAIN_SUFFIXES in src/ssrf.rs exactly (20 entries).
-- df.start() calls must be top-level committed statements so the BGW can see the
-- inserted nodes. Using INSERT...SELECT from unnest() commits all 20 starts at once.
-- ============================================================================

CREATE TEMP TABLE _test_ssrf9 (instance_id TEXT, suffix TEXT);

INSERT INTO _test_ssrf9
SELECT
    df.start(
        df.http('https://pg-durable-test-nonexistent' || suffix || '/test', 'GET', NULL, NULL, 5),
        'test-ssrf-suffix-' || suffix
    ),
    suffix
FROM unnest(ARRAY[
    '.blob.core.windows.net',
    '.blob.storage.azure.net',
    '.queue.core.windows.net',
    '.table.core.windows.net',
    '.file.core.windows.net',
    '.azurewebsites.net',
    '.azure-api.net',
    '.documents.azure.com',
    '.servicebus.windows.net',
    '.openai.azure.com',
    '.cognitiveservices.azure.com',
    '.vault.azure.net',
    '.redis.cache.windows.net',
    '.database.windows.net',
    '.kusto.windows.net',
    '.azurefd.net',
    '.azureedge.net',
    '.azure-devices.net',
    '.trafficmanager.net',
    '.cloudapp.azure.com'
]) AS suffix;

DO $$
DECLARE
    rec RECORD;
    node_result TEXT;
BEGIN
    FOR rec IN SELECT instance_id, suffix FROM _test_ssrf9 LOOP
        PERFORM df.wait_for_completion(rec.instance_id, 60);

        SELECT result::text INTO node_result
        FROM df.nodes
        WHERE instance_id = rec.instance_id AND node_type = 'HTTP';

        IF node_result ILIKE '%not in the allowed%' THEN
            RAISE EXCEPTION 'TEST FAILED: suffix % should pass allow-list, got: %', rec.suffix, node_result;
        END IF;

        RAISE NOTICE 'TEST PASSED: ssrf_azure_suffix_allowed %', rec.suffix;
    END LOOP;
END $$;

DROP TABLE _test_ssrf9;

-- ============================================================================
-- Test 10: Allow legitimate test-domain HTTPS (sanity check)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf10 (instance_id TEXT);

INSERT INTO _test_ssrf10 SELECT df.start(
    df.http('https://httpbingo.org/get', 'GET'),
    'test-ssrf-allow-public'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf10;
    RAISE NOTICE 'Testing allowed test domain (httpbingo.org): %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: httpbingo.org should be allowed (test domains feature), got status = %', status;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_allow_test_domain';
END $$;

DROP TABLE _test_ssrf10;

-- ============================================================================
-- Test 11: Crafting an HTTP node with a bad scheme via raw JSON to df.start()
-- bypasses the DSL check but is still blocked at execution time.
-- (DSL-time scheme rejection is already covered by Test 3 above.)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf11 (instance_id TEXT);

INSERT INTO _test_ssrf11
SELECT df.start(
    '{"node_type":"HTTP","query":"{\"url\":\"file:///etc/passwd\",\"method\":\"GET\",\"body\":null,\"headers\":null,\"timeout_seconds\":5}"}',
    'test-ssrf-scheme-bypass'
);

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf11;
    RAISE NOTICE 'Testing scheme-bypass block (file:// via raw JSON): %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected status = failed, got %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%unsupported URL scheme%' THEN
        RAISE EXCEPTION
            'TEST FAILED: expected "unsupported URL scheme" in node result, got: %',
            node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_scheme_execution_time_rejection';
END $$;

DROP TABLE _test_ssrf11;

SELECT 'TEST PASSED' AS result;
