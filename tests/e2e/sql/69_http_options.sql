-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.with_http_options.
SELECT df.grant_usage('df_e2e_user', include_http => true);
SET SESSION AUTHORIZATION df_e2e_user;

DO $$
DECLARE
    request_node TEXT;
    named_node TEXT;
    configured_node TEXT;
    configured_config JSONB;
    option_value JSONB;
    expected_error TEXT;
    actual_error TEXT;
BEGIN
    FOREACH request_node IN ARRAY ARRAY[
        df.http('https://httpbingo.org/{path}', 'POST', '$response {value}', '{"Authorization":"${secret:server.token}"}', 15),
        df.http_multipart('https://httpbingo.org/post', 'POST', '[{"name":"field","data_b64":"$response.body"}]')
    ] LOOP
        IF df.with_http_options(request_node, NULL) IS DISTINCT FROM request_node
           OR df.with_http_options(request_node, '{}') IS DISTINCT FROM request_node
           OR df.with_http_options(df.with_http_options(request_node, '{}'), '{}') IS DISTINCT FROM request_node THEN
            RAISE EXCEPTION 'TEST FAILED: empty options changed the node';
        END IF;

        named_node := df.as(request_node, 'response');
        IF df.with_http_options(named_node, '{}') IS DISTINCT FROM named_node
           OR df.as(df.with_http_options(request_node, '{}'), 'response') IS DISTINCT FROM named_node THEN
            RAISE EXCEPTION 'TEST FAILED: options changed result naming';
        END IF;

        configured_node := df.with_http_options(named_node,
            '{"max_request_bytes":4096,"max_response_bytes":4096,"response":"metadata","response_headers":["Content-Type"]}');
        configured_config := (configured_node::jsonb->>'query')::jsonb;
        IF configured_node::jsonb->>'result_name' IS DISTINCT FROM 'response'
           OR configured_config->>'response' IS DISTINCT FROM 'metadata'
           OR configured_config->>'max_request_bytes' IS DISTINCT FROM '4096'
           OR configured_config->'response_headers' IS DISTINCT FROM '["Content-Type"]'::jsonb THEN
            RAISE EXCEPTION 'TEST FAILED: body options were not attached correctly';
        END IF;
        configured_node := df.with_http_options(configured_node,
            '{"response":"discard","max_response_bytes":null,"response_headers":[]}');
        configured_config := (configured_node::jsonb->>'query')::jsonb;
        IF configured_config->>'response' IS DISTINCT FROM 'discard'
           OR configured_config->>'max_request_bytes' IS DISTINCT FROM '4096'
           OR configured_config->'max_response_bytes' IS DISTINCT FROM 'null'::jsonb
           OR configured_config->'response_headers' IS DISTINCT FROM '[]'::jsonb THEN
            RAISE EXCEPTION 'TEST FAILED: replacing body options changed unrelated settings';
        END IF;

        FOR option_value, expected_error IN
            SELECT * FROM (VALUES
                ('{"retry":3}'::jsonb, 'unrecognised option ''retry'''),
                ('{"response":"automatic"}'::jsonb, 'invalid body options'),
                ('{"max_request_bytes":-1}'::jsonb, 'invalid body options'),
                ('{"max_response_bytes":1.5}'::jsonb, 'invalid body options'),
                ('{"response_headers":{}}'::jsonb, 'invalid body options'),
                ('{"response_headers":["bad header"]}'::jsonb, 'valid HTTP header names'),
                ('[]'::jsonb, 'options must be a JSON object'),
                ('null'::jsonb, 'options must be a JSON object'),
                ('true'::jsonb, 'options must be a JSON object'),
                ('42'::jsonb, 'options must be a JSON object'),
                ('"value"'::jsonb, 'options must be a JSON object')
            ) AS cases(option_value, expected_error)
        LOOP
            actual_error := NULL;
            BEGIN
                PERFORM df.with_http_options(request_node, option_value);
            EXCEPTION WHEN others THEN
                actual_error := SQLERRM;
            END;
            IF actual_error IS NULL OR strpos(actual_error, expected_error) = 0 THEN
                RAISE EXCEPTION 'TEST FAILED: expected %, got %', expected_error, actual_error;
            END IF;
        END LOOP;
    END LOOP;

    request_node := ' { "result_name": "response", "query": "{\"url\":\"https://httpbingo.org/{path}\",\"method\":\"GET\",\"body\":\"$response ${secret:server.token}\"}", "node_type": "HTTP" } ';
    IF df.with_http_options(request_node, '{}') IS DISTINCT FROM request_node THEN
        RAISE EXCEPTION 'TEST FAILED: options reserialized the original graph text';
    END IF;

    FOREACH request_node IN ARRAY ARRAY[
        'SELECT 1', '{', 'null', '{}', df.sql('SELECT 1'), df.sleep(1),
        df.http('https://httpbingo.org/get') ~> 'SELECT 1',
        '{"node_type":"HTTP"}',
        '{"node_type":"HTTP","query":"not JSON"}',
        '{"node_type":"HTTP_MULTIPART","query":"[]"}',
        '{"node_type":"HTTP","query":"{}","left_node":{"node_type":"SQL","query":"SELECT 1"}}'
    ] LOOP
        actual_error := NULL;
        BEGIN
            PERFORM df.with_http_options(request_node, '{}');
        EXCEPTION WHEN others THEN
            actual_error := SQLERRM;
        END;
        IF actual_error IS NULL OR actual_error NOT LIKE 'df.with_http_options(): %' THEN
            RAISE EXCEPTION 'TEST FAILED: expected invalid-node rejection, got %', actual_error;
        END IF;
    END LOOP;

    RAISE NOTICE 'TEST PASSED: HTTP options validation and byte preservation';
END $$;

CREATE TEMP TABLE _test_http_options (instance_id TEXT, node_type TEXT, query TEXT);

INSERT INTO _test_http_options
SELECT df.start(
           df.with_http_options(request_node, '{}') |=> 'response'
           ~> 'SELECT ($response::jsonb->>''status'')::integer as status',
           'test-http-options'
       ), request_node::jsonb->>'node_type', request_node::jsonb->>'query'
FROM (VALUES
    (df.http('https://httpbingo.org/get', 'GET')),
    (df.http_multipart('https://httpbingo.org/post', 'POST', '[{"name":"field","data_b64":"aGk="}]'))
) AS requests(request_node);

DO $$
DECLARE
    test_case RECORD;
    status TEXT;
BEGIN
    FOR test_case IN SELECT * FROM _test_http_options LOOP
        SELECT df.await_instance(test_case.instance_id) INTO status;
        IF status IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: % with options ended with %', test_case.node_type, status;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM df.nodes AS node
            WHERE node.instance_id = test_case.instance_id
              AND node.node_type = test_case.node_type
              AND node.query = test_case.query
              AND node.result_name = 'response'
        ) THEN
            RAISE EXCEPTION 'TEST FAILED: stored HTTP config or result name changed';
        END IF;
    END LOOP;
END $$;

DROP TABLE _test_http_options;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _test_http_bodies (
    instance_id TEXT,
    response_mode TEXT,
    expected_status TEXT,
    http_status INTEGER,
    expected_bytes INTEGER,
    error_pattern TEXT,
    history_marker BOOLEAN,
    activity_expected BOOLEAN DEFAULT true
);

INSERT INTO _test_http_bodies
SELECT df.start(df.with_http_options(request_node, jsonb_build_object(
           'response', response_mode, 'response_headers', '[]'::jsonb,
           'max_request_bytes', 4096, 'max_response_bytes', 25
       )), 'test-http-body-' || response_mode),
       response_mode, 'completed', 200, 25, NULL, response_mode = 'inline', true
FROM (VALUES ('inline'), ('metadata'), ('discard')) AS modes(response_mode)
CROSS JOIN (VALUES
    (df.http('https://httpbingo.org/base64/SFRUUF9SRVNQT05TRV9QUklWQVRFXzM3Ng==', 'GET')),
    (df.http_multipart('https://httpbingo.org/base64/SFRUUF9SRVNQT05TRV9QUklWQVRFXzM3Ng==',
        parts => '[{"name":"field","data_b64":"YWJj"}]'))
) AS requests(request_node);

INSERT INTO _test_http_bodies
SELECT df.start(df.with_http_options(request_node,
           '{"response":"metadata","response_headers":[],"max_response_bytes":24}'),
           'test-http-response-overflow'),
       'metadata', 'failed', NULL, NULL, '%max_response_bytes%', false, true
FROM (VALUES
    (df.http('https://httpbingo.org/base64/SFRUUF9SRVNQT05TRV9QUklWQVRFXzM3Ng==', 'GET')),
    (df.http_multipart('https://httpbingo.org/base64/SFRUUF9SRVNQT05TRV9QUklWQVRFXzM3Ng==',
        parts => '[{"name":"field","data_b64":"YWJj"}]'))
) AS requests(request_node);

INSERT INTO _test_http_bodies VALUES
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/204', 'GET'),
        '{"response":"metadata","response_headers":[],"max_request_bytes":0,"max_response_bytes":0}'),
        'test-http-empty-body'), 'metadata', 'completed', 204, 0, NULL, false, true),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/400', 'GET'),
        '{"response":"discard","response_headers":[],"max_response_bytes":0}'),
        'test-http-client-error-body'), 'discard', 'completed', 400, 0, NULL, false, true),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/500', 'GET'),
        '{"response":"discard","response_headers":[],"max_response_bytes":0}'),
        'test-http-server-error-body'), 'discard', 'failed', NULL, NULL, '%response body omitted%', false, true),
    (df.start(df.with_http_options(
        df.http_multipart('https://httpbingo.org/post', parts => '[{"name":"field","data_b64":"YWJj"}]',
            headers => '{"Content-Length":"1"}'),
        '{"response":"discard","max_request_bytes":3}'),
        'test-http-multipart-framing'), 'discard', 'failed', NULL, NULL, '%max_request_bytes%', false, true),
    (df.start(
        df.with_http_options(df.http('https://httpbingo.org/base64/SFRUUF9SRVNQT05TRV9QUklWQVRFXzM3Ng==', 'GET'),
            '{"response":"metadata","response_headers":[],"max_response_bytes":25}') |=> 'payload'
        ~> ('SELECT ($payload::jsonb->>''bytes'')::integer as bytes'
            & 'SELECT ($payload::jsonb->>''status'')::integer as status'),
        'test-http-metadata-subtrees'), 'metadata', 'completed', 200, 25, NULL, false, true);

SELECT df.setvar('http_body_text', repeat('q', 64));
SELECT df.setvar('http_body_b64', encode(convert_to(repeat('q', 64), 'UTF8'), 'base64'));
INSERT INTO _test_http_bodies
SELECT df.start(df.with_http_options(request_node,
           '{"response":"discard","max_request_bytes":4}'), 'test-http-expanded-request-overflow'),
       'discard', 'failed', NULL, NULL, '%max_request_bytes%', false, false
FROM (VALUES
    (df.http('https://httpbingo.org/post', 'POST', '{http_body_text}')),
    (df.http_multipart('https://httpbingo.org/post',
        parts => '[{"name":"field","data_b64":"{http_body_b64}"}]'))
) AS requests(request_node);
SELECT df.unsetvar('http_body_text');
SELECT df.unsetvar('http_body_b64');

DO $$
DECLARE
    request_node TEXT;
    actual_error TEXT;
BEGIN
    FOR request_node IN
        SELECT jsonb_build_object('node_type', node_type, 'query', config::text)::text
        FROM (VALUES
            ('HTTP', '{"url":"https://httpbingo.org/post","method":"POST","body":"too large","max_request_bytes":1}'::jsonb),
            ('HTTP_MULTIPART', '{"url":"https://httpbingo.org/post","method":"POST","parts":[{"name":"field","data_b64":"YWJj"}],"max_request_bytes":1}'::jsonb)
        ) AS requests(node_type, config)
    LOOP
        actual_error := NULL;
        BEGIN
            PERFORM df.start(request_node, 'test-http-static-request-overflow');
        EXCEPTION WHEN others THEN
            actual_error := SQLERRM;
        END;
        IF actual_error IS NULL OR actual_error NOT LIKE '%max_request_bytes%' THEN
            RAISE EXCEPTION 'TEST FAILED: oversized literal request was not rejected: %', actual_error;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM df.instances WHERE label = 'test-http-static-request-overflow') THEN
        RAISE EXCEPTION 'TEST FAILED: oversized literal request was persisted';
    END IF;
END $$;

DO $$
DECLARE
    test_case RECORD;
    actual_status TEXT;
    response JSONB;
    expected_body TEXT;
BEGIN
    FOR test_case IN SELECT * FROM _test_http_bodies LOOP
        actual_status := df.await_instance(test_case.instance_id);
        SELECT node.result INTO response FROM df.nodes AS node
        WHERE node.instance_id = test_case.instance_id AND node.node_type IN ('HTTP', 'HTTP_MULTIPART');
        IF actual_status IS DISTINCT FROM test_case.expected_status THEN
            RAISE EXCEPTION 'TEST FAILED: body case % expected %, got %, result %',
                test_case.instance_id, test_case.expected_status, actual_status, response;
        END IF;
        IF test_case.error_pattern IS NOT NULL THEN
            IF response IS NULL OR response::text NOT LIKE test_case.error_pattern THEN
                RAISE EXCEPTION 'TEST FAILED: wrong body-limit error: %', response;
            END IF;
            CONTINUE;
        END IF;
        IF (response->>'status')::integer IS DISTINCT FROM test_case.http_status
           OR (response->>'ok')::boolean IS DISTINCT FROM (test_case.http_status BETWEEN 200 AND 299)
           OR response->'headers' IS DISTINCT FROM '{}'::jsonb THEN
            RAISE EXCEPTION 'TEST FAILED: wrong response metadata: %', response;
        END IF;
        expected_body := CASE WHEN test_case.expected_bytes = 0 THEN '' ELSE 'HTTP_RESPONSE_PRIVATE_376' END;
        IF test_case.response_mode = 'inline' THEN
            IF response->>'body' IS DISTINCT FROM expected_body
               OR response->>'encoding' IS DISTINCT FROM 'text'
               OR response ? 'bytes' OR response ? 'sha256' THEN
                RAISE EXCEPTION 'TEST FAILED: inline response shape changed: %', response;
            END IF;
        ELSE
            IF response ? 'body' OR response ? 'encoding'
               OR (response->>'bytes')::integer IS DISTINCT FROM test_case.expected_bytes THEN
                RAISE EXCEPTION 'TEST FAILED: omitted response contains body or wrong size: %', response;
            END IF;
            IF test_case.response_mode = 'metadata' THEN
                IF response->>'sha256' IS DISTINCT FROM encode(sha256(convert_to(expected_body, 'UTF8')), 'hex') THEN
                    RAISE EXCEPTION 'TEST FAILED: incorrect response hash: %', response;
                END IF;
            ELSIF response ? 'sha256' THEN
                RAISE EXCEPTION 'TEST FAILED: discard response contains a hash';
            END IF;
        END IF;
    END LOOP;
END $$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    test_case RECORD;
    attempts INTEGER;
    terminal_count INTEGER;
    has_marker BOOLEAN;
    scheduled BOOLEAN;
    engine_schema TEXT := df.duroxide_schema();
BEGIN
    FOR test_case IN SELECT * FROM _test_http_bodies LOOP
        attempts := 0;
        LOOP
            EXECUTE format('SELECT count(*) FROM %I.history WHERE instance_id = $1 AND event_data::jsonb->>''type'' IN (''OrchestrationCompleted'', ''OrchestrationFailed'')', engine_schema)
                INTO terminal_count USING test_case.instance_id;
            EXIT WHEN terminal_count > 0 OR attempts >= 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        IF terminal_count = 0 THEN
            RAISE EXCEPTION 'TEST FAILED: HTTP body history was not persisted';
        END IF;
        EXECUTE format('SELECT coalesce(bool_or(strpos(event_data::text, $2) > 0), false),
            coalesce(bool_or(strpos(event_data::text, $3) > 0 OR strpos(event_data::text, $4) > 0), false)
            FROM %I.history WHERE instance_id = $1 OR starts_with(instance_id, $1 || ''::'')', engine_schema)
            INTO has_marker, scheduled USING test_case.instance_id, 'HTTP_RESPONSE_PRIVATE_376',
                'pg_durable::activity::execute-http', 'pg_durable::activity::execute-multipart';
        IF has_marker IS DISTINCT FROM test_case.history_marker THEN
            RAISE EXCEPTION 'TEST FAILED: wrong response-body persistence for mode %: %', test_case.response_mode, has_marker;
        END IF;
        IF scheduled IS DISTINCT FROM test_case.activity_expected THEN
            RAISE EXCEPTION 'TEST FAILED: request body cap applied at wrong scheduling boundary';
        END IF;
        IF NOT test_case.history_marker THEN
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.executions AS execution
                WHERE (instance_id = $1 OR starts_with(instance_id, $1 || ''::''))
                  AND strpos(row_to_json(execution)::text, $2) > 0)', engine_schema)
                INTO has_marker USING test_case.instance_id, 'HTTP_RESPONSE_PRIVATE_376';
            IF has_marker OR EXISTS (SELECT 1 FROM df.nodes AS node
                WHERE node.instance_id = test_case.instance_id
                  AND strpos(row_to_json(node)::text, 'HTTP_RESPONSE_PRIVATE_376') > 0) THEN
                RAISE EXCEPTION 'TEST FAILED: response body leaked into persisted workflow state';
            END IF;
        END IF;
    END LOOP;
END $$;
DROP TABLE _test_http_bodies;

DROP ROLE IF EXISTS http_options_denied;
CREATE ROLE http_options_denied LOGIN;
SELECT df.grant_usage('http_options_denied');
SET SESSION AUTHORIZATION http_options_denied;

CREATE TEMP TABLE _test_http_options_denied (instance_id TEXT, node_type TEXT);
INSERT INTO _test_http_options_denied
SELECT df.start(df.with_http_options(
           jsonb_build_object('node_type', node_type, 'query', config)::text, '{}'
       ), 'test-http-options-denied'), node_type
FROM (VALUES
    ('HTTP', '{"url":"https://api.github.com/","method":"GET","timeout_seconds":1}'),
    ('HTTP_MULTIPART', '{"url":"https://api.github.com/","method":"POST","parts":[{"name":"field","data_b64":"aGk="}],"timeout_seconds":1}')
) AS requests(node_type, config);

DO $$
DECLARE
    test_case RECORD;
    status TEXT;
    node_result TEXT;
BEGIN
    FOR test_case IN SELECT * FROM _test_http_options_denied LOOP
        SELECT df.await_instance(test_case.instance_id) INTO status;
        SELECT node.result::text INTO node_result
        FROM df.nodes AS node
        WHERE node.instance_id = test_case.instance_id AND node.node_type = test_case.node_type;

        IF status IS DISTINCT FROM 'failed'
           OR node_result IS NULL
           OR node_result NOT LIKE '%does not have EXECUTE privilege%' THEN
            RAISE EXCEPTION 'TEST FAILED: options bypassed HTTP privilege checks: %, %', status, node_result;
        END IF;
    END LOOP;
END $$;

DROP TABLE _test_http_options_denied;
RESET SESSION AUTHORIZATION;
DROP OWNED BY http_options_denied;
DROP ROLE http_options_denied;

SELECT 'TEST PASSED' AS result;
