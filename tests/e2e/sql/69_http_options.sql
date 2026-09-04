-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: the frozen df.http() / df.http_multipart() `options` parameter.
--        NULL and '{}' are accepted and change nothing about the node config;
--        any option key (or a non-object value) is rejected.
-- Requires: pg_durable built with --features http (standard phase uses http-allow-test-domains)
SET SESSION AUTHORIZATION df_e2e_user;

-- Test 1: options => NULL and options => '{}' produce the same node as omitting
-- the argument. The node config is a duroxide activity input matched by exact
-- string equality, so it must not change.
DO $$
DECLARE
    without_options TEXT;
    explicit_null   TEXT;
    empty_object    TEXT;
BEGIN
    without_options := df.http('https://httpbingo.org/get', 'GET');
    explicit_null   := df.http('https://httpbingo.org/get', 'GET', NULL, NULL, 30, NULL);
    empty_object    := df.http('https://httpbingo.org/get', 'GET', options => '{}'::jsonb);

    IF without_options IS DISTINCT FROM explicit_null THEN
        RAISE EXCEPTION 'TEST 1 FAILED: options => NULL changed the node: % vs %',
            without_options, explicit_null;
    END IF;

    IF without_options IS DISTINCT FROM empty_object THEN
        RAISE EXCEPTION 'TEST 1 FAILED: options => ''{}'' changed the node: % vs %',
            without_options, empty_object;
    END IF;

    RAISE NOTICE 'TEST 1 PASSED: df.http() options NULL/{} leave the node config unchanged';
END $$;

-- Test 2: unknown option keys and non-object values are rejected.
DO $$
DECLARE
    err TEXT;
BEGIN
    BEGIN
        PERFORM df.http('https://httpbingo.org/get', 'GET', options => '{"retry": 3}'::jsonb);
        RAISE EXCEPTION 'TEST 2 FAILED: df.http() accepted an unknown option key';
    EXCEPTION WHEN others THEN
        err := SQLERRM;
        IF err NOT LIKE '%retry%' THEN
            RAISE EXCEPTION 'TEST 2 FAILED: error should name the option key, got: %', err;
        END IF;
    END;

    BEGIN
        PERFORM df.http('https://httpbingo.org/get', 'GET', options => '[]'::jsonb);
        RAISE EXCEPTION 'TEST 2 FAILED: df.http() accepted a non-object options value';
    EXCEPTION WHEN others THEN
        err := SQLERRM;
        IF err NOT LIKE '%JSON object%' THEN
            RAISE EXCEPTION 'TEST 2 FAILED: expected a "must be a JSON object" error, got: %', err;
        END IF;
    END;

    RAISE NOTICE 'TEST 2 PASSED: df.http() rejects unsupported options';
END $$;

-- Test 3: df.http_multipart() enforces the same rules.
DO $$
DECLARE
    parts_json      jsonb := jsonb_build_array(
                                 jsonb_build_object('name', 'field', 'data_b64', 'aGk='));
    without_options TEXT;
    empty_object    TEXT;
    err             TEXT;
BEGIN
    without_options := df.http_multipart('https://httpbingo.org/post', 'POST', parts_json);
    empty_object    := df.http_multipart('https://httpbingo.org/post', 'POST', parts_json,
                                         options => '{}'::jsonb);

    IF without_options IS DISTINCT FROM empty_object THEN
        RAISE EXCEPTION 'TEST 3 FAILED: options => ''{}'' changed the multipart node: % vs %',
            without_options, empty_object;
    END IF;

    BEGIN
        PERFORM df.http_multipart('https://httpbingo.org/post', 'POST', parts_json,
                                  options => '{"stream": true}'::jsonb);
        RAISE EXCEPTION 'TEST 3 FAILED: df.http_multipart() accepted an unknown option key';
    EXCEPTION WHEN others THEN
        err := SQLERRM;
        IF err NOT LIKE '%stream%' THEN
            RAISE EXCEPTION 'TEST 3 FAILED: error should name the option key, got: %', err;
        END IF;
    END;

    RAISE NOTICE 'TEST 3 PASSED: df.http_multipart() rejects unsupported options';
END $$;

-- Test 4: a workflow using the new signature executes end to end (this also
-- exercises the execution-time privilege check against the new signature).
CREATE TEMP TABLE _test_http_options (instance_id TEXT);

INSERT INTO _test_http_options SELECT df.start(
    df.http('https://httpbingo.org/get', 'GET', options => '{}'::jsonb) |=> 'response'
    ~> 'SELECT ($response::jsonb->>''ok'')::boolean as success',
    'test-http-options'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_options;

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST 4 FAILED: status = %', status;
    END IF;

    RAISE NOTICE 'TEST 4 PASSED: http_options_execution';
END $$;

DROP TABLE _test_http_options;

RESET SESSION AUTHORIZATION;

SELECT 'TEST PASSED' AS result;
