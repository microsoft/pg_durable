RESET SESSION AUTHORIZATION;
DROP DATABASE IF EXISTS _test_binding_sql_target;
CREATE DATABASE _test_binding_sql_target TEMPLATE template0;
DROP SERVER IF EXISTS sb_service, sb_endpoint, sb_denied, sb_nomap, sb_auth CASCADE;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sb_no_http') THEN DROP OWNED BY sb_no_http; END IF;
END $$;
DROP ROLE IF EXISTS sb_no_http;
CREATE ROLE sb_no_http LOGIN;
GRANT CONNECT ON DATABASE _test_binding_sql_target TO df_e2e_user, sb_no_http;
SELECT df.grant_usage('sb_no_http');
SELECT df.grant_usage('df_e2e_user', include_http => true);
CREATE SERVER sb_service FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (auth_scheme 'none');
CREATE SERVER sb_endpoint FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://httpbingo.org', auth_scheme 'none');
CREATE SERVER sb_denied FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (auth_scheme 'none');
CREATE SERVER sb_nomap FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (auth_scheme 'none');
CREATE SERVER sb_auth FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://httpbingo.org', auth_scheme 'bearer');
GRANT USAGE ON FOREIGN SERVER sb_service, sb_endpoint, sb_nomap, sb_auth TO df_e2e_user;
GRANT USAGE ON FOREIGN SERVER sb_service TO sb_no_http;
CREATE USER MAPPING FOR df_e2e_user SERVER sb_service OPTIONS
    ("secret.private" 'BINDING_PRIVATE_CREDENTIAL', "secret.probe" 'a&b+c= %',
     "secret.empty" '', "secret.invalid_header" E'BINDING_PRIVATE_BAD\r\n');
CREATE USER MAPPING FOR df_e2e_user SERVER sb_auth OPTIONS (token 'BINDING_PRIVATE_ENDPOINT');
CREATE USER MAPPING FOR sb_no_http SERVER sb_service OPTIONS ("secret.private" 'BINDING_PRIVATE_OTHER');
CREATE TEMP TABLE _binding_cases(instance_id text, expected text, error_pattern text, echo boolean DEFAULT false);
GRANT SELECT, INSERT ON _binding_cases TO df_e2e_user, sb_no_http;
SET SESSION AUTHORIZATION df_e2e_user;

ALTER USER MAPPING FOR CURRENT_USER SERVER sb_service OPTIONS (ADD "secret.new_key" 'BINDING_PRIVATE_ADDED');
ALTER USER MAPPING FOR CURRENT_USER SERVER sb_service OPTIONS (SET "secret.private" 'BINDING_PRIVATE_ROTATED');
ALTER USER MAPPING FOR CURRENT_USER SERVER sb_service OPTIONS (DROP "secret.new_key");

DO $$
DECLARE
    destination text;
    bindings jsonb;
    request_node text;
    target_probe text := $probe$SELECT 1 / (pg_catalog.current_database() = '_test_binding_sql_target'
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_durable'))::integer$probe$;
BEGIN
    FOREACH destination IN ARRAY ARRAY['https://httpbingo.org/status/204', df.endpoint('sb_endpoint', '/status/204'), df.endpoint('sb_auth', '/status/204')] LOOP
        bindings := jsonb_build_object(
            'headers', jsonb_build_object('X-Key', df.secret('sb_service', 'private') || '{"prefix":"Key "}'::jsonb),
            'query', jsonb_build_object('key', df.secret('sb_service', 'private')));
        request_node := df.with_http_options(df.http(destination, 'POST'),
            jsonb_build_object('secret_bindings', bindings || jsonb_build_object('form', jsonb_build_object('password', df.secret('sb_service', 'private'))),
                'form_fields', jsonb_build_object('payload', '${secret:sb_service.private} $missing {missing}')));
        INSERT INTO _binding_cases VALUES (df.start(request_node, 'secret-form'), 'completed', NULL, false);
        INSERT INTO _binding_cases VALUES (df.start(target_probe ~> request_node, 'secret-form-other-database',
            database => '_test_binding_sql_target'), 'completed', NULL, false);
        request_node := df.with_http_options(df.http_multipart(destination, parts => '[{"name":"file","data_b64":"aGVsbG8="}]'),
            jsonb_build_object('secret_bindings', bindings));
        INSERT INTO _binding_cases VALUES (df.start(request_node, 'secret-multipart'), 'completed', NULL, false);
        INSERT INTO _binding_cases VALUES (df.start(target_probe ~> request_node, 'secret-multipart-other-database',
            database => '_test_binding_sql_target'), 'completed', NULL, false);
    END LOOP;
END $$;

INSERT INTO _binding_cases VALUES
    (df.start(df.http(df.endpoint('sb_service', '/status/204'), 'GET'), 'binding-url-less-endpoint'), 'failed', '%has no base_url%', false),
    (df.start(df.http_multipart(df.endpoint('sb_service', '/status/204'), parts => '[{"name":"file","data_b64":"aGVsbG8="}]'),
        'binding-url-less-multipart-endpoint'), 'failed', '%has no base_url%', false),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/204', 'GET'),
        jsonb_build_object('secret_bindings', jsonb_build_object('headers', jsonb_build_object('X-Key', df.secret('sb_service', 'missing'))))), 'binding-missing-key'), 'failed', '%secret key is missing%', false),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/204', 'GET'),
        jsonb_build_object('secret_bindings', jsonb_build_object('query', jsonb_build_object('key', df.secret('sb_denied', 'private'))))), 'binding-denied-server', database => '_test_binding_sql_target'), 'failed', '%USAGE%', false),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/204', 'GET'),
        jsonb_build_object('secret_bindings', jsonb_build_object('query', jsonb_build_object('key', df.secret('sb_nomap', 'private'))))), 'binding-no-mapping', database => '_test_binding_sql_target'), 'failed', '%mapping%required%', false),
    (df.start(df.http(df.endpoint('sb_denied', '/status/204'), 'GET'), 'binding-endpoint-denied-other-database',
        database => '_test_binding_sql_target'), 'failed', '%USAGE%', false),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/204', 'GET'),
        jsonb_build_object('secret_bindings', jsonb_build_object('headers', jsonb_build_object('X-Key', df.secret('sb_service', 'invalid_header'))))), 'binding-invalid-header'), 'failed', '%not a valid HTTP header%', false),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/204?%6bey=ordinary', 'GET'),
        jsonb_build_object('secret_bindings', jsonb_build_object('query', jsonb_build_object('key', df.secret('sb_service', 'private'))))), 'binding-query-conflict'), 'failed', '%conflicts%query%', false),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/status/204', 'GET', headers => '{"x-key":"ordinary"}'),
        jsonb_build_object('secret_bindings', jsonb_build_object('headers', jsonb_build_object('X-Key', df.secret('sb_service', 'private'))))), 'binding-header-conflict'), 'failed', '%conflict%headers%', false),
    (df.start(df.with_http_options(df.http(df.endpoint('sb_auth', '/status/204'), 'GET'),
        jsonb_build_object('secret_bindings', jsonb_build_object('headers', jsonb_build_object('Authorization', df.secret('sb_service', 'private'))))), 'binding-endpoint-conflict'), 'failed', '%override endpoint%', false),
    (df.start(df.with_http_options(df.http('https://127.0.0.1', 'GET'),
        jsonb_build_object('secret_bindings', jsonb_build_object('query', jsonb_build_object('key', df.secret('sb_service', 'private'))))), 'binding-blocked-destination'), 'failed', '%bare IP%', false);

INSERT INTO _binding_cases VALUES (df.start(df.with_http_options(
    df.http('https://httpbingo.org/anything?ordinary=%24%7Bsecret%3Asb_service.private%7D', 'POST', headers => '{"X-Literal":"${secret:sb_service.private}"}'),
    jsonb_build_object('secret_bindings', jsonb_build_object(
        'headers', jsonb_build_object('X-Probe', df.secret('sb_service', 'probe') || '{"prefix":"Key "}'::jsonb),
        'query', jsonb_build_object('probe', df.secret('sb_service', 'probe')),
        'form', jsonb_build_object('password', df.secret('sb_service', 'probe'), 'empty', df.secret('sb_service', 'empty'))),
        'form_fields', jsonb_build_object('payload', '${secret:sb_service.private} $missing {missing}', 'descriptor', '{"server":"sb_service","key":"private"}'))),
    'binding-echo-public-probe'), 'completed', NULL, true);

RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION sb_no_http;
INSERT INTO _binding_cases VALUES (df.start(
    '{"node_type":"HTTP","query":"{\"url\":\"https://httpbingo.org/status/204\",\"method\":\"GET\",\"secret_bindings\":{\"headers\":{\"X-Key\":{\"server\":\"sb_service\",\"key\":\"private\"}}}}"}',
    'binding-forged-no-http', database => '_test_binding_sql_target'), 'failed', '%EXECUTE%df.http()%', false);
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    test_case record;
    actual text;
    result_text text;
    body jsonb;
    attempts integer;
    terminal_count integer;
    leaked boolean;
    engine_schema text := df.duroxide_schema();
BEGIN
    FOR test_case IN SELECT * FROM _binding_cases LOOP
        actual := df.await_instance(test_case.instance_id, 60);
        SELECT result::text INTO result_text FROM df.nodes WHERE instance_id = test_case.instance_id AND node_type IN ('HTTP','HTTP_MULTIPART');
        IF actual IS DISTINCT FROM test_case.expected THEN
            RAISE EXCEPTION 'TEST FAILED: binding expected %, got %, result %', test_case.expected, actual, result_text;
        END IF;
        IF test_case.error_pattern IS NOT NULL AND COALESCE(result_text,'') NOT LIKE test_case.error_pattern THEN
            RAISE EXCEPTION 'TEST FAILED: binding error did not match %: %', test_case.error_pattern, result_text;
        END IF;
        IF actual = 'completed' THEN
            IF (result_text::jsonb->>'status')::integer IS DISTINCT FROM (CASE WHEN test_case.echo THEN 200 ELSE 204 END) THEN
                RAISE EXCEPTION 'TEST FAILED: unexpected HTTP result %', result_text;
            END IF;
            IF test_case.echo THEN
                body := (result_text::jsonb->>'body')::jsonb;
                IF body->'form'->'password'->>0 IS DISTINCT FROM 'a&b+c= %'
                    OR body->'form'->'empty'->>0 IS DISTINCT FROM ''
                    OR body->'form'->'payload'->>0 IS DISTINCT FROM '${secret:sb_service.private} $missing {missing}'
                    OR body->'form'->'descriptor'->>0 IS DISTINCT FROM '{"server":"sb_service","key":"private"}'
                    OR body->'args'->'probe'->>0 IS DISTINCT FROM 'a&b+c= %'
                    OR body->'args'->'ordinary'->>0 IS DISTINCT FROM '${secret:sb_service.private}'
                    OR body->'headers'->'X-Probe'->>0 IS DISTINCT FROM 'Key a&b+c= %'
                    OR body->'headers'->'X-Literal'->>0 IS DISTINCT FROM '${secret:sb_service.private}' THEN
                    RAISE EXCEPTION 'TEST FAILED: binding encoding or literal data changed: %', body;
                END IF;
            END IF;
        END IF;
        attempts := 0;
        LOOP
            EXECUTE format('SELECT count(*) FROM %I.history WHERE instance_id = $1 AND event_data::jsonb->>''type'' IN (''OrchestrationCompleted'',''OrchestrationFailed'')', engine_schema)
                INTO terminal_count USING test_case.instance_id;
            EXIT WHEN terminal_count > 0 OR attempts >= 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        IF terminal_count = 0 THEN RAISE EXCEPTION 'TEST FAILED: binding terminal history missing'; END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.history WHERE instance_id = $1 AND event_data::text LIKE ''%%BINDING_PRIVATE_%%'')', engine_schema)
            INTO leaked USING test_case.instance_id;
        IF leaked THEN RAISE EXCEPTION 'TEST FAILED: credential in binding history'; END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.executions AS execution WHERE instance_id = $1 AND row_to_json(execution)::text LIKE ''%%BINDING_PRIVATE_%%'')', engine_schema)
            INTO leaked USING test_case.instance_id;
        IF leaked THEN RAISE EXCEPTION 'TEST FAILED: credential in binding execution state'; END IF;
        IF EXISTS (SELECT 1 FROM df.nodes node WHERE instance_id = test_case.instance_id AND row_to_json(node)::text LIKE '%BINDING_PRIVATE_%') THEN
            RAISE EXCEPTION 'TEST FAILED: credential in binding node state';
        END IF;
    END LOOP;
END $$;

DROP TABLE _binding_cases;
DROP SERVER sb_service, sb_endpoint, sb_denied, sb_nomap, sb_auth CASCADE;
DROP OWNED BY sb_no_http;
DROP ROLE sb_no_http;
DROP DATABASE _test_binding_sql_target;
SELECT 'TEST PASSED' AS result;
