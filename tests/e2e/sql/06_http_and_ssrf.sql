-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Merged from: 18_http, 19_github_api, 36_ssrf_protection
-- Tests: HTTP GET/POST/headers/sequence/parallel/4xx/delay/vars,
--        GitHub API with loop and vars, SSRF protection for all blocked/allowed cases
-- Requires: pg_durable built with --features http (standard phase uses http-allow-test-domains)
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: 18_http ===

-- Test 1: Simple GET request
CREATE TEMP TABLE _test_http_get (instance_id TEXT);

INSERT INTO _test_http_get SELECT df.start(
    df.http('https://httpbingo.org/get', 'GET') |=> 'response'
    ~> 'SELECT ($response::jsonb->>''ok'')::boolean as success',
    'test-http-get'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_get;
    RAISE NOTICE 'Testing HTTP GET: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP GET status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_get';
END $$;

DROP TABLE _test_http_get;

-- Test 2: POST request with JSON body
CREATE TEMP TABLE _test_http_post (instance_id TEXT);

INSERT INTO _test_http_post SELECT df.start(
    df.http(
        'https://httpbingo.org/post',
        'POST',
        '{"message": "hello from pg_durable", "value": 42}'
    ) |=> 'response'
    ~> 'SELECT 
            ($response::jsonb->>''ok'')::boolean as ok,
            ($response::jsonb->>''status'')::int as status_code',
    'test-http-post'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_post;
    RAISE NOTICE 'Testing HTTP POST: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP POST status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_post';
END $$;

DROP TABLE _test_http_post;

-- Test 3: HTTP with custom headers
CREATE TEMP TABLE _test_http_headers (instance_id TEXT);

INSERT INTO _test_http_headers SELECT df.start(
    df.http(
        'https://httpbingo.org/headers',
        'GET',
        NULL,
        '{"X-Custom-Header": "pg_durable_test", "Accept": "application/json"}'::jsonb
    ) |=> 'response'
    ~> 'SELECT ($response::jsonb->>''ok'')::boolean as ok',
    'test-http-headers'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_headers;
    RAISE NOTICE 'Testing HTTP with headers: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP headers status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_headers';
END $$;

DROP TABLE _test_http_headers;

-- Test 4: HTTP in a sequence (fetch data, then use it)
CREATE TEMP TABLE _test_http_sequence (instance_id TEXT);

INSERT INTO _test_http_sequence SELECT df.start(
    (df.http('https://httpbingo.org/uuid', 'GET') |=> 'uuid_response')
    ~> (df.http(
        'https://httpbingo.org/post',
        'POST',
        '{"received_uuid": "will_be_substituted"}'
    ) |=> 'echo_response')
    ~> 'SELECT 
            ($uuid_response::jsonb->>''ok'')::boolean as uuid_ok,
            ($echo_response::jsonb->>''ok'')::boolean as echo_ok',
    'test-http-sequence'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_sequence;
    RAISE NOTICE 'Testing HTTP sequence: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP sequence status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_sequence';
END $$;

DROP TABLE _test_http_sequence;

-- Test 5: Parallel HTTP requests
CREATE TEMP TABLE _test_http_parallel (instance_id TEXT);

INSERT INTO _test_http_parallel SELECT df.start(
    df.join(
        df.http('https://httpbingo.org/get?branch=1', 'GET'),
        df.http('https://httpbingo.org/get?branch=2', 'GET')
    ) |=> 'parallel_results'
    ~> 'SELECT json_array_length($parallel_results::json) as result_count',
    'test-http-parallel'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_parallel;
    RAISE NOTICE 'Testing HTTP parallel: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP parallel status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_parallel';
END $$;

DROP TABLE _test_http_parallel;

-- Test 6: HTTP 4xx error handling (should NOT fail, returns response)
CREATE TEMP TABLE _test_http_404 (instance_id TEXT);

INSERT INTO _test_http_404 SELECT df.start(
    df.http('https://httpbingo.org/status/404', 'GET') |=> 'response'
    ~> df.if(
        'SELECT ($response::jsonb->>''status'')::int = 404',
        'SELECT ''handled_404_correctly''',
        'SELECT ''unexpected_status'''
    ),
    'test-http-404'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_404;
    RAISE NOTICE 'Testing HTTP 404 handling: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP 404 should complete (user handles), got status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_404_handling';
END $$;

DROP TABLE _test_http_404;

-- Test 7: HTTP delay (tests timeout handling)
CREATE TEMP TABLE _test_http_delay (instance_id TEXT);

INSERT INTO _test_http_delay SELECT df.start(
    df.http('https://httpbingo.org/delay/1', 'GET') |=> 'response'
    ~> 'SELECT ($response::jsonb->>''ok'')::boolean as ok',
    'test-http-delay'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_delay;
    RAISE NOTICE 'Testing HTTP delay: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP delay status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_delay';
END $$;

DROP TABLE _test_http_delay;

-- Test 8: HTTP with workflow variables
SELECT df.clearvars();
SELECT df.setvar('base_url', 'https://httpbingo.org');
SELECT df.setvar('test_endpoint', '/get');

CREATE TEMP TABLE _test_http_vars (instance_id TEXT);

INSERT INTO _test_http_vars SELECT df.start(
    df.http('{base_url}{test_endpoint}', 'GET') |=> 'response'
    ~> 'SELECT ($response::jsonb->>''ok'')::boolean as success',
    'test-http-vars'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_vars;
    RAISE NOTICE 'Testing HTTP with vars: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP vars status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_vars';
END $$;

DROP TABLE _test_http_vars;
SELECT df.clearvars();

-- === Test: 19_github_api ===

DROP TABLE IF EXISTS github_commits;
CREATE TABLE github_commits (
    id SERIAL PRIMARY KEY,
    sha TEXT UNIQUE,
    author TEXT,
    message TEXT,
    committed_at TIMESTAMPTZ,
    fetched_at TIMESTAMPTZ DEFAULT now()
);

SELECT df.clearvars();
SELECT df.setvar('github_url', 'https://api.github.com/repos/microsoft/duroxide/commits?per_page=5');

CREATE TEMP TABLE _test_github (instance_id TEXT);

INSERT INTO _test_github SELECT df.start(
    @> (
        (df.http(
            '{github_url}',
            'GET',
            NULL,
            '{"Accept": "application/vnd.github.v3+json", "User-Agent": "pg_durable-test"}'::jsonb
        ) |=> 'response')
        ~> 'INSERT INTO github_commits (sha, author, message, committed_at)
            SELECT 
                c->>''sha'',
                c->''commit''->''author''->>''name'',
                c->''commit''->>''message'',
                (c->''commit''->''author''->>''date'')::timestamptz
            FROM jsonb_array_elements(($response::jsonb->>''body'')::jsonb) AS c
            ON CONFLICT (sha) DO UPDATE SET
                fetched_at = now()
            RETURNING sha'
        ~> df.wait_for_schedule('*/30 * * * *')
    ),
    'github-commit-sync'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    commit_count INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_github;
    RAISE NOTICE 'Testing GitHub API with vars and loop: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        SELECT COUNT(*) INTO commit_count FROM github_commits;
        EXIT WHEN commit_count > 0 OR lower(status) = 'failed' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) = 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: GitHub API fetch status = %', status;
    END IF;
    
    SELECT COUNT(*) INTO commit_count FROM github_commits;
    RAISE NOTICE 'Fetched % commits from GitHub', commit_count;
    
    IF commit_count = 0 THEN
        RAISE EXCEPTION 'TEST FAILED: No commits fetched from GitHub API';
    END IF;
    
    PERFORM df.cancel(inst_id, 'Test completed - cancelling scheduled loop');
    RAISE NOTICE 'Cancelled scheduled loop after successful first iteration';
    
    RAISE NOTICE 'TEST PASSED: github_api_with_vars_and_loop';
END $$;

SELECT sha, author, committed_at, LEFT(message, 50) AS message FROM github_commits ORDER BY committed_at DESC;

DROP TABLE _test_github;
DROP TABLE github_commits;
SELECT df.clearvars();

-- === Test: 36_ssrf_protection ===

-- Test 1: Block cloud metadata endpoint (link-local 169.254.169.254)
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

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%bare IP%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected "bare IP" in error, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_block_metadata';
END $$;

DROP TABLE _test_ssrf1;

-- Test 2: Block localhost (127.0.0.1)
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

-- Test 3: Block unsupported URL scheme (file://) — DSL time and execution time
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

-- Test 4: Non-Azure domain is blocked by allow-list (example.com)
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

-- Test 5: Azure Blob domain passes allow-list (DNS/network may fail, not allow-list)
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

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result ILIKE '%not in the allowed%' THEN
        RAISE EXCEPTION 'TEST FAILED: Azure Blob domain should pass allow-list, got: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: ssrf_azure_blob_allowed';
END $$;

DROP TABLE _test_ssrf5;

-- Test 6: Bare public IP address is blocked
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

-- Test 7: management.azure.com is intentionally absent from allow-list
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

-- Test 8: Redirects are not followed
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

-- Test 9: All Azure domain suffixes pass the allow-list
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

-- Test 10: Allow legitimate test-domain HTTPS (sanity check)
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

-- Test 11: Crafting an HTTP node with a bad scheme via raw JSON — blocked at execution time
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

RESET SESSION AUTHORIZATION;

-- ============================================================================
-- === HTTP Permission Tests ===
-- (merged from 49_http_permissions)
--
-- These tests exercise the opt-in HTTP access model.  They require superuser
-- operations (CREATE/DROP ROLE, GRANT/REVOKE) so they run outside the
-- df_e2e_user session.
-- ============================================================================

-- --- Setup ---
DO $setup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename IN ('http_priv_alice', 'http_priv_bob')
        AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY http_priv_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE http_priv_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY http_priv_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE http_priv_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

CREATE ROLE http_priv_alice LOGIN;
GRANT TEMPORARY ON DATABASE postgres TO http_priv_alice;

CREATE ROLE http_priv_bob LOGIN;
GRANT TEMPORARY ON DATABASE postgres TO http_priv_bob;

-- Grant full df access including df.http() (opt-in via include_http => true)
SELECT df.grant_usage('http_priv_alice', include_http => true);

-- Permission Test 1: User with EXECUTE on df.http() can run HTTP nodes
SET SESSION AUTHORIZATION http_priv_alice;
CREATE TEMP TABLE _test_http_priv1 (instance_id TEXT);
INSERT INTO _test_http_priv1
SELECT df.start(
    df.http('https://api.github.com/', 'GET'),
    'test-http-grant-allowed'
);
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_priv1;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    -- The request may succeed or fail due to network/rate-limiting, but it
    -- must NOT fail with a privilege error.
    IF lower(status) NOT IN ('completed', 'failed') THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected status = %', status;
    END IF;

    DECLARE
        node_result TEXT;
    BEGIN
        SELECT result::text INTO node_result
        FROM df.nodes
        WHERE instance_id = inst_id AND node_type = 'HTTP';

        IF node_result ILIKE '%does not have EXECUTE privilege%' THEN
            RAISE EXCEPTION 'TEST FAILED: privilege check blocked a user who should have access: %', node_result;
        END IF;
    END;

    RAISE NOTICE 'TEST PASSED: http_grant_allowed';
END $$;

DROP TABLE _test_http_priv1;

-- Permission Test 2: After REVOKE, user is blocked at execution time even via raw JSON
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM http_priv_alice;

SET SESSION AUTHORIZATION http_priv_alice;
CREATE TEMP TABLE _test_http_priv2 (instance_id TEXT);
INSERT INTO _test_http_priv2
SELECT df.start(
    '{"node_type":"HTTP","query":"{\"url\":\"https://api.github.com/\",\"method\":\"GET\",\"body\":null,\"headers\":null,\"timeout_seconds\":5}"}',
    'test-http-grant-revoked'
);
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_priv2;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected status = failed after privilege revocation, got %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%does not have EXECUTE privilege%' THEN
        RAISE EXCEPTION
            'TEST FAILED: expected privilege-denied message in node result, got: %',
            node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: http_grant_revoked_blocks_execution';
END $$;

DROP TABLE _test_http_priv2;

-- Permission Test 3: Restore grant and confirm access works again
GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO http_priv_alice;

SET SESSION AUTHORIZATION http_priv_alice;
CREATE TEMP TABLE _test_http_priv3 (instance_id TEXT);
INSERT INTO _test_http_priv3
SELECT df.start(
    df.http('https://api.github.com/', 'GET'),
    'test-http-grant-restored'
);
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_priv3;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('completed', 'failed') THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected status = %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result ILIKE '%does not have EXECUTE privilege%' THEN
        RAISE EXCEPTION 'TEST FAILED: privilege check blocked a user whose grant was restored: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: http_grant_restored';
END $$;

DROP TABLE _test_http_priv3;

-- Permission Test 4: grant_usage default (include_http => false) blocks HTTP at execution
SELECT df.grant_usage('http_priv_bob');

SET SESSION AUTHORIZATION http_priv_bob;
CREATE TEMP TABLE _test_http_priv4 (instance_id TEXT);
INSERT INTO _test_http_priv4
SELECT df.start(
    '{"node_type":"HTTP","query":"{\"url\":\"https://api.github.com/\",\"method\":\"GET\",\"body\":null,\"headers\":null,\"timeout_seconds\":5}"}',
    'test-http-no-grant'
);
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_priv4;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected status = failed for role without HTTP grant, got %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result IS NULL OR node_result NOT ILIKE '%does not have EXECUTE privilege%' THEN
        RAISE EXCEPTION
            'TEST FAILED: expected privilege-denied message in node result, got: %',
            node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: http_no_grant_blocks_execution';
END $$;

DROP TABLE _test_http_priv4;

-- Permission Test 5: grant_usage(false) does NOT grant df.http, but residual PUBLIC grant persists
GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO PUBLIC;

-- grant_usage is purely additive — it does not revoke df.http or warn about
-- residual PUBLIC grants.  The caller is responsible for revoking separately.

DO $$
BEGIN
    BEGIN
        PERFORM df.grant_usage('http_priv_bob', include_http => false);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'TEST FAILED: grant_usage raised an unexpected exception: %', SQLERRM;
    END;
    -- grant_usage(include_http => false) does not grant df.http, but the
    -- PUBLIC grant above still gives http_priv_bob effective access.
    IF NOT has_function_privilege('http_priv_bob'::regrole,
                                   'df.http(text, text, text, jsonb, integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'TEST FAILED: expected http_priv_bob to still have effective HTTP access via PUBLIC grant';
    END IF;
    RAISE NOTICE 'TEST PASSED: grant_usage_warns_on_residual_public_grant';
END $$;

-- Restore: revoke the PUBLIC grant again so subsequent tests are unaffected
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM PUBLIC;

-- Permission Test 6: Superuser always passes the execution-time privilege check
CREATE TEMP TABLE _test_http_priv6 (instance_id TEXT);
INSERT INTO _test_http_priv6
SELECT df.start(
    '{"node_type":"HTTP","query":"{\"url\":\"https://api.github.com/\",\"method\":\"GET\",\"body\":null,\"headers\":null,\"timeout_seconds\":5}"}',
    'test-http-superuser'
);

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_priv6;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) NOT IN ('completed', 'failed') THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected status for superuser HTTP node = %', status;
    END IF;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'HTTP';

    IF node_result ILIKE '%does not have EXECUTE privilege%' THEN
        RAISE EXCEPTION 'TEST FAILED: superuser was blocked by privilege check: %', node_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: superuser_bypasses_http_privilege_check';
END $$;

DROP TABLE _test_http_priv6;

-- --- Permission Test Cleanup ---
DO $cleanup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename IN ('http_priv_alice', 'http_priv_bob')
        AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY http_priv_alice; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE http_priv_alice;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY http_priv_bob;   EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE http_priv_bob;       EXCEPTION WHEN undefined_object THEN NULL; END;
END $cleanup$;

SELECT 'TEST PASSED' AS result;
