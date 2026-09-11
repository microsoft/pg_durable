-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.with_http_options.
SELECT df.grant_usage('df_e2e_user', include_http => true);
SET SESSION AUTHORIZATION df_e2e_user;

DO $$
DECLARE
    request_node TEXT;
    named_node TEXT;
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

        FOR option_value, expected_error IN
            SELECT * FROM (VALUES
                ('{"retry":3}'::jsonb, 'unrecognised option ''retry'''),
                ('{"response":"metadata"}'::jsonb, 'unrecognised option ''response'''),
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
