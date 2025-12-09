-- E2E Test: HTTP Requests
-- Tests df.http() with httpbingo.org for real HTTP calls
-- Based on USER_GUIDE.md HTTP examples
--
-- NOTE: These tests require network access to httpbingo.org
-- For local testing without network, use: cargo test --test http_integration

-- ============================================================================
-- Test 1: Simple GET request
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_get;
    RAISE NOTICE 'Testing HTTP GET: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP GET status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_get';
END $$;

DROP TABLE _test_http_get;

-- ============================================================================
-- Test 2: POST request with JSON body
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_post;
    RAISE NOTICE 'Testing HTTP POST: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP POST status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_post';
END $$;

DROP TABLE _test_http_post;

-- ============================================================================
-- Test 3: HTTP with custom headers
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_headers;
    RAISE NOTICE 'Testing HTTP with headers: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP headers status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_headers';
END $$;

DROP TABLE _test_http_headers;

-- ============================================================================
-- Test 4: HTTP in a sequence (fetch data, then use it)
-- ============================================================================

CREATE TEMP TABLE _test_http_sequence (instance_id TEXT);

INSERT INTO _test_http_sequence SELECT df.start(
    -- Step 1: Fetch UUID from httpbingo
    (df.http('https://httpbingo.org/uuid', 'GET') |=> 'uuid_response')
    -- Step 2: Echo it back
    ~> (df.http(
        'https://httpbingo.org/post',
        'POST',
        '{"received_uuid": "will_be_substituted"}'
    ) |=> 'echo_response')
    -- Step 3: Verify both succeeded
    ~> 'SELECT 
            ($uuid_response::jsonb->>''ok'')::boolean as uuid_ok,
            ($echo_response::jsonb->>''ok'')::boolean as echo_ok',
    'test-http-sequence'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_sequence;
    RAISE NOTICE 'Testing HTTP sequence: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP sequence status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_sequence';
END $$;

DROP TABLE _test_http_sequence;

-- ============================================================================
-- Test 5: Parallel HTTP requests
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_parallel;
    RAISE NOTICE 'Testing HTTP parallel: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP parallel status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_parallel';
END $$;

DROP TABLE _test_http_parallel;

-- ============================================================================
-- Test 6: HTTP 4xx error handling (should NOT fail, returns response)
-- ============================================================================

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
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_404;
    RAISE NOTICE 'Testing HTTP 404 handling: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    -- 404 should NOT cause failure - we handle it in the workflow
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP 404 should complete (user handles), got status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_404_handling';
END $$;

DROP TABLE _test_http_404;

-- ============================================================================
-- Test 7: HTTP delay (tests timeout handling)
-- ============================================================================

CREATE TEMP TABLE _test_http_delay (instance_id TEXT);

INSERT INTO _test_http_delay SELECT df.start(
    -- Request 1 second delay - should succeed with default 30s timeout
    df.http('https://httpbingo.org/delay/1', 'GET') |=> 'response'
    ~> 'SELECT ($response::jsonb->>''ok'')::boolean as ok',
    'test-http-delay'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_delay;
    RAISE NOTICE 'Testing HTTP delay: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP delay status = %', status;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: http_delay';
END $$;

DROP TABLE _test_http_delay;

-- ============================================================================
-- Summary
-- ============================================================================

SELECT 'ALL HTTP TESTS PASSED' AS result;

