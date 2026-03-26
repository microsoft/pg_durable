-- E2E Test: http-allow-all feature disables all domain restrictions.
--
-- This test runs in the "http-allow-all" phase, which builds pg_durable with the
-- http-allow-all Cargo feature.  Domains that are normally blocked by the Azure
-- allow-list (e.g. example.com) must be reachable (or at least not rejected by
-- the allow-list — network/DNS failure is fine).

-- ============================================================================
-- Test 1: Non-Azure domain passes allow-list when http-allow-all is set
-- ============================================================================

CREATE TEMP TABLE _test_allowall1 (instance_id TEXT);

INSERT INTO _test_allowall1 SELECT df.start(
    df.http('https://example.com/', 'GET'),
    'test-http-allow-all-non-azure'
);

DO $$
DECLARE
    inst_id TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_allowall1;
    RAISE NOTICE 'Testing non-Azure domain allowed under http-allow-all: %', inst_id;

    PERFORM df.wait_for_completion(inst_id);

    -- Must NOT fail due to allow-list; network/DNS failure is acceptable
    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result ILIKE '%not in the allowed%' THEN
        RAISE EXCEPTION 'TEST FAILED: allow-list should be bypassed under http-allow-all, got: %', node_result;
    END IF;

    IF node_result ILIKE '%bare IP%' THEN
        RAISE EXCEPTION 'TEST FAILED: IP check should be bypassed under http-allow-all, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: http_allow_all_non_azure';
END $$;

DROP TABLE _test_allowall1;

-- ============================================================================
-- Test 2: Bare public IP passes allow-list when http-allow-all is set
-- (network connection may fail, but not the allow-list check)
-- ============================================================================

CREATE TEMP TABLE _test_allowall2 (instance_id TEXT);

INSERT INTO _test_allowall2 SELECT df.start(
    df.http('https://8.8.8.8/', 'GET'),
    'test-http-allow-all-bare-ip'
);

DO $$
DECLARE
    inst_id TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_allowall2;
    RAISE NOTICE 'Testing bare public IP allowed under http-allow-all: %', inst_id;

    PERFORM df.wait_for_completion(inst_id);

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    -- Under http-allow-all the allow-list is entirely bypassed — no "bare IP" rejection
    IF node_result ILIKE '%bare IP%' THEN
        RAISE EXCEPTION 'TEST FAILED: bare IP check should be bypassed under http-allow-all, got: %', node_result;
    END IF;

    IF node_result ILIKE '%not in the allowed%' THEN
        RAISE EXCEPTION 'TEST FAILED: allow-list should be bypassed under http-allow-all, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: http_allow_all_bare_ip';
END $$;

DROP TABLE _test_allowall2;

SELECT 'TEST PASSED' AS result;
