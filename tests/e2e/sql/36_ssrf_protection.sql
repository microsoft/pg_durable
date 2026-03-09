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

    -- Verify the error mentions restricted range
    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%restricted%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "restricted" in error, got: %', node_result;
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

    IF node_result IS NULL OR node_result NOT ILIKE '%restricted%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "restricted" in error, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_block_localhost';
END $$;

DROP TABLE _test_ssrf2;

-- ============================================================================
-- Test 3: Block unsupported URL scheme (file://)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf3 (instance_id TEXT);

INSERT INTO _test_ssrf3 SELECT df.start(
    df.http('file:///etc/passwd', 'GET'),
    'test-ssrf-file-scheme'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf3;
    RAISE NOTICE 'Testing SSRF block (file:// scheme): %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: file:// request should have failed, got status = %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%unsupported URL scheme%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "unsupported URL scheme" in error, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_block_file_scheme';
END $$;

DROP TABLE _test_ssrf3;

-- ============================================================================
-- Test 4: Allow legitimate external HTTPS (sanity check)
-- ============================================================================

CREATE TEMP TABLE _test_ssrf4 (instance_id TEXT);

INSERT INTO _test_ssrf4 SELECT df.start(
    df.http('https://httpbingo.org/get', 'GET'),
    'test-ssrf-allow-public'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf4;
    RAISE NOTICE 'Testing SSRF allows public HTTPS: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: public HTTPS should succeed, got status = %', status;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_allow_public';
END $$;

DROP TABLE _test_ssrf4;

SELECT 'TEST PASSED' AS result;
