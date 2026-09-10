RESET SESSION AUTHORIZATION;
DROP SERVER IF EXISTS eh_none, eh_bearer, eh_header, eh_query, eh_missing, eh_denied, eh_blocked CASCADE;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eh_no_http') THEN
        DROP OWNED BY eh_no_http;
    END IF;
END $$;
DROP ROLE IF EXISTS eh_no_http;
CREATE ROLE eh_no_http LOGIN;
SELECT df.grant_usage('eh_no_http');
SELECT df.grant_usage('df_e2e_user', include_http => true);

CREATE SERVER eh_none FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://httpbingo.org/status', auth_scheme 'none');
CREATE SERVER eh_bearer FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://httpbingo.org', auth_scheme 'bearer');
CREATE SERVER eh_header FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://httpbingo.org', auth_scheme 'header', header_name 'x-api-key');
CREATE SERVER eh_query FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://httpbingo.org', auth_scheme 'query');
CREATE SERVER eh_missing FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://httpbingo.org', auth_scheme 'bearer');
CREATE SERVER eh_denied FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://httpbingo.org', auth_scheme 'none');
CREATE SERVER eh_blocked FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://127.0.0.1', auth_scheme 'none');
GRANT USAGE ON FOREIGN SERVER eh_none, eh_bearer, eh_header, eh_query, eh_missing, eh_blocked TO df_e2e_user;
GRANT USAGE ON FOREIGN SERVER eh_none TO eh_no_http;
CREATE USER MAPPING FOR df_e2e_user SERVER eh_bearer OPTIONS (token 'ENDPOINT_PRIVATE_BEARER');
CREATE USER MAPPING FOR df_e2e_user SERVER eh_header OPTIONS (header_value 'ENDPOINT_PRIVATE_HEADER');
CREATE USER MAPPING FOR df_e2e_user SERVER eh_query OPTIONS (query_string 'sig=ENDPOINT_PRIVATE_QUERY&sv=1');

CREATE TEMP TABLE _endpoint_http_cases (instance_id text, expected text, error_pattern text);
GRANT SELECT, INSERT ON _endpoint_http_cases TO df_e2e_user, eh_no_http;

SET SESSION AUTHORIZATION df_e2e_user;
SELECT df.setvar('endpoint_status_code', '204');
SELECT df.setvar('endpoint_bad_path', '..');

DO $$
DECLARE
    server_name text;
    request_path text;
    request_node text;
    config jsonb;
BEGIN
    FOREACH server_name IN ARRAY ARRAY['eh_none', 'eh_bearer', 'eh_header', 'eh_query'] LOOP
        request_path := CASE WHEN server_name = 'eh_none' THEN '/{endpoint_status_code}' ELSE '/status/{endpoint_status_code}' END;
        request_node := df.http(df.endpoint(server_name, request_path), 'GET');
        config := (request_node::jsonb->>'query')::jsonb;
        IF config->>'endpoint' IS DISTINCT FROM server_name OR config->>'url' IS DISTINCT FROM request_path THEN
            RAISE EXCEPTION 'TEST FAILED: endpoint construction changed reference fields';
        END IF;
        IF df.explain(request_node) NOT LIKE '%' || server_name || '%' THEN
            RAISE EXCEPTION 'TEST FAILED: endpoint missing from explain output';
        END IF;
        INSERT INTO _endpoint_http_cases VALUES (df.start(request_node, 'endpoint-http-' || server_name), 'completed', NULL);
        request_node := df.http_multipart(df.endpoint(server_name, request_path), parts => '[{"name":"file","data_b64":"aGVsbG8="}]');
        INSERT INTO _endpoint_http_cases VALUES (df.start(request_node, 'endpoint-multipart-' || server_name), 'completed', NULL);
    END LOOP;
END $$;

INSERT INTO _endpoint_http_cases VALUES
    (df.start(df.http(df.endpoint('eh_missing', '/status/204'), 'GET'), 'endpoint-missing-mapping'), 'failed', '%mapping%required%'),
    (df.start(df.http(df.endpoint('eh_denied', '/status/204'), 'GET'), 'endpoint-server-denied'), 'failed', '%USAGE%'),
    (df.start(df.http_multipart(df.endpoint('eh_denied', '/status/204'), parts => '[{"name":"file","data_b64":"aA=="}]'), 'endpoint-multipart-denied'), 'failed', '%USAGE%'),
    (df.start(df.http(df.endpoint('eh_none', '/{endpoint_bad_path}/escape'), 'GET'), 'endpoint-substituted-traversal'), 'failed', '%traversal%'),
    (df.start(df.http(df.endpoint('eh_bearer', '/status/204'), 'GET', headers => '{"authorization":"override"}'), 'endpoint-header-override'), 'failed', '%override%'),
    (df.start(df.http_multipart(df.endpoint('eh_header', '/status/204'), parts => '[{"name":"file","data_b64":"aA=="}]', headers => '{"X-API-KEY":"override"}'), 'endpoint-multipart-override'), 'failed', '%override%'),
    (df.start(df.http(df.endpoint('eh_query', '/status/204?%73ig=override'), 'GET'), 'endpoint-query-override'), 'failed', '%override%'),
    (df.start(df.http(df.endpoint('eh_none', '/204'), 'GET', headers => '{"Host":"evil.example"}'), 'endpoint-host-override'), 'failed', '%override%'),
    (df.start(df.http(df.endpoint('eh_blocked', '/'), 'GET'), 'endpoint-ssrf'), 'failed', '%bare IP%'),
    (df.start(df.http(df.endpoint('eh_bearer', '/status/400'), 'GET'), 'endpoint-client-error'), 'completed', NULL);

RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION eh_no_http;
INSERT INTO _endpoint_http_cases VALUES
    (df.start('{"node_type":"HTTP","query":"{\"endpoint\":\"eh_none\",\"url\":\"/204\",\"method\":\"GET\"}"}', 'endpoint-forged-no-http'), 'failed', '%EXECUTE%df.http()%'),
    (df.start('{"node_type":"HTTP_MULTIPART","query":"{\"endpoint\":\"eh_none\",\"url\":\"/204\",\"method\":\"POST\",\"parts\":[{\"name\":\"file\",\"data_b64\":\"aA==\"}]}"}', 'endpoint-forged-no-multipart'), 'failed', '%EXECUTE%df.http_multipart()%');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    test_case record;
    actual_status text;
    attempts integer;
    result_text text;
    terminal_count integer;
    leaked boolean;
    engine_schema text := df.duroxide_schema();
BEGIN
    FOR test_case IN SELECT * FROM _endpoint_http_cases LOOP
        attempts := 0;
        LOOP
            actual_status := df.status(test_case.instance_id);
            EXIT WHEN actual_status IN ('completed', 'failed', 'cancelled') OR attempts >= 600;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        result_text := df.result(test_case.instance_id);
        IF test_case.expected = 'failed' THEN
            SELECT result::text INTO result_text FROM df.nodes
            WHERE instance_id = test_case.instance_id AND node_type IN ('HTTP', 'HTTP_MULTIPART');
        END IF;
        IF actual_status IS DISTINCT FROM test_case.expected THEN
            RAISE EXCEPTION 'TEST FAILED: endpoint instance % expected %, got %, result %', test_case.instance_id, test_case.expected, actual_status, result_text;
        END IF;
        IF test_case.error_pattern IS NOT NULL AND COALESCE(result_text, '') NOT LIKE test_case.error_pattern THEN
            RAISE EXCEPTION 'TEST FAILED: endpoint error did not match %: %', test_case.error_pattern, result_text;
        END IF;
        IF test_case.expected = 'completed' AND (result_text::jsonb->>'status')::integer NOT IN (204, 400) THEN
            RAISE EXCEPTION 'TEST FAILED: non-echoing endpoint returned unexpected result %', result_text;
        END IF;
        attempts := 0;
        LOOP
            EXECUTE format('SELECT count(*) FROM %I.history WHERE instance_id = $1 AND event_data::jsonb->>''type'' IN (''OrchestrationCompleted'', ''OrchestrationFailed'')', engine_schema)
                INTO terminal_count USING test_case.instance_id;
            EXIT WHEN terminal_count > 0 OR attempts >= 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        IF terminal_count = 0 THEN RAISE EXCEPTION 'TEST FAILED: endpoint history not persisted'; END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.history WHERE instance_id = $1 AND event_data::text LIKE ''%%ENDPOINT_PRIVATE_%%'')', engine_schema)
            INTO leaked USING test_case.instance_id;
        IF leaked THEN RAISE EXCEPTION 'TEST FAILED: endpoint credential in durable history'; END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.executions AS execution WHERE instance_id = $1 AND row_to_json(execution)::text LIKE ''%%ENDPOINT_PRIVATE_%%'')', engine_schema)
            INTO leaked USING test_case.instance_id;
        IF leaked THEN RAISE EXCEPTION 'TEST FAILED: endpoint credential in execution state'; END IF;
        IF EXISTS (SELECT 1 FROM df.nodes AS node WHERE instance_id = test_case.instance_id AND row_to_json(node)::text LIKE '%ENDPOINT_PRIVATE_%') THEN
            RAISE EXCEPTION 'TEST FAILED: endpoint credential in node state';
        END IF;
    END LOOP;
END $$;

SET SESSION AUTHORIZATION df_e2e_user;
SELECT df.unsetvar('endpoint_status_code');
SELECT df.unsetvar('endpoint_bad_path');
RESET SESSION AUTHORIZATION;
DROP TABLE _endpoint_http_cases;
DROP SERVER eh_none, eh_bearer, eh_header, eh_query, eh_missing, eh_denied, eh_blocked CASCADE;
DROP OWNED BY eh_no_http;
DROP ROLE eh_no_http;
SELECT 'TEST PASSED' AS result;