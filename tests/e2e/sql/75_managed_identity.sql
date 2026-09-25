RESET SESSION AUTHORIZATION;
DROP SERVER IF EXISTS mi_system, mi_user, mi_error, mi_denied CASCADE;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mi_no_http') THEN
        DROP OWNED BY mi_no_http;
    END IF;
END $$;
DROP ROLE IF EXISTS mi_no_http;
CREATE ROLE mi_no_http LOGIN;
SELECT df.grant_usage('mi_no_http');
SELECT df.grant_usage('df_e2e_user', include_http => true);

DO $$
DECLARE
    statement text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_settings WHERE name = 'pg_durable.managed_identity_endpoint'
        AND context = 'postmaster' AND source = 'configuration file' AND NOT pending_restart) THEN
        RAISE EXCEPTION 'TEST FAILED: managed identity provider must be a startup-only setting';
    END IF;
    FOREACH statement IN ARRAY ARRAY[
        'SET pg_durable.managed_identity_endpoint = ''http://127.0.0.1:9/token''',
        'ALTER ROLE df_e2e_user SET pg_durable.managed_identity_endpoint = ''http://127.0.0.1:9/token''',
        format('ALTER DATABASE %I SET pg_durable.managed_identity_endpoint = ''http://127.0.0.1:9/token''', current_database())
    ] LOOP
        BEGIN
            EXECUTE statement;
            RAISE EXCEPTION 'TEST FAILED: accepted a runtime managed identity provider override';
        EXCEPTION WHEN cant_change_runtime_param THEN
            NULL;
        END;
    END LOOP;
END $$;

CREATE SERVER mi_system FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://pg-durable-mi.blob.core.windows.net/system', auth_scheme 'managed-identity');
CREATE SERVER mi_user FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://pg-durable-mi.blob.core.windows.net/user', auth_scheme 'managed-identity',
             client_id '11111111-1111-1111-1111-111111111111');
CREATE SERVER mi_error FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://pg-durable-mi.blob.core.windows.net/error', auth_scheme 'managed-identity',
             client_id '22222222-2222-2222-2222-222222222222');
CREATE SERVER mi_denied FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://pg-durable-mi.blob.core.windows.net/system', auth_scheme 'managed-identity');
GRANT USAGE ON FOREIGN SERVER mi_system, mi_user, mi_error TO df_e2e_user;
GRANT USAGE ON FOREIGN SERVER mi_system TO mi_no_http;

CREATE TEMP TABLE _mi_cases (instance_id text, expected text, status_code integer, error_pattern text);
GRANT SELECT, INSERT ON _mi_cases TO df_e2e_user, mi_no_http;
SET SESSION AUTHORIZATION df_e2e_user;

INSERT INTO _mi_cases VALUES
    (df.start(df.http(df.endpoint('mi_system', '/data'), 'GET'), 'mi-system-http'), 'completed', 204, NULL),
    (df.start(df.http_multipart(df.endpoint('mi_system', '/upload'), parts => '[{"name":"file","data_b64":"aGVsbG8="}]'), 'mi-system-multipart'), 'completed', 204, NULL),
    (df.start(df.http(df.endpoint('mi_user', '/data'), 'GET'), 'mi-user-http'), 'completed', 204, NULL),
    (df.start(df.http_multipart(df.endpoint('mi_user', '/upload'), parts => '[{"name":"file","data_b64":"aGVsbG8="}]'), 'mi-user-multipart'), 'completed', 204, NULL),
    (df.start(df.http(df.endpoint('mi_system', '/redirect'), 'GET'), 'mi-no-redirect'), 'completed', 302, NULL),
    (df.start(df.http(df.endpoint('mi_system', '/unauthorized'), 'GET'), 'mi-unauthorized'), 'completed', 401, NULL),
    (df.start(df.http(df.endpoint('mi_error', '/data'), 'GET'), 'mi-provider-error'), 'failed', NULL, '%token provider returned HTTP 400%'),
    (df.start(df.http_multipart(df.endpoint('mi_error', '/upload'), parts => '[{"name":"file","data_b64":"aGVsbG8="}]'), 'mi-provider-error-multipart'), 'failed', NULL, '%token provider returned HTTP 400%'),
    (df.start(df.http(df.endpoint('mi_denied', '/data'), 'GET'), 'mi-usage-denied'), 'failed', NULL, '%USAGE%'),
    (df.start(df.http_multipart(df.endpoint('mi_denied', '/upload'), parts => '[{"name":"file","data_b64":"aGVsbG8="}]'), 'mi-usage-denied-multipart'), 'failed', NULL, '%USAGE%'),
    (df.start(df.http(df.endpoint('mi_system', '/data'), 'GET', headers => '{"aUtHoRiZaTiOn":"override"}'), 'mi-override'), 'failed', NULL, '%override endpoint%'),
    (df.start(df.http_multipart(df.endpoint('mi_system', '/upload'), parts => '[{"name":"file","data_b64":"aGVsbG8="}]', headers => '{"Authorization":"override"}'), 'mi-override-multipart'), 'failed', NULL, '%override endpoint%'),
    (df.start(df.with_http_options(df.http(df.endpoint('mi_system', '/data'), 'GET'),
        jsonb_build_object('secret_bindings', jsonb_build_object('headers', jsonb_build_object('Authorization', df.secret('mi_system', 'absent')))))), 'failed', NULL, '%override endpoint authentication%'),
    (df.start(df.with_http_options(df.http_multipart(df.endpoint('mi_system', '/upload'), parts => '[{"name":"file","data_b64":"aGVsbG8="}]'),
        jsonb_build_object('secret_bindings', jsonb_build_object('headers', jsonb_build_object('authorization', df.secret('mi_system', 'absent')))))), 'failed', NULL, '%override endpoint authentication%');

RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION mi_no_http;
INSERT INTO _mi_cases VALUES
    (df.start('{"node_type":"HTTP","query":"{\"endpoint\":\"mi_system\",\"url\":\"/data\",\"method\":\"GET\"}"}', 'mi-forged-no-http'), 'failed', NULL, '%EXECUTE%'),
    (df.start('{"node_type":"HTTP_MULTIPART","query":"{\"endpoint\":\"mi_system\",\"url\":\"/upload\",\"method\":\"POST\",\"parts\":[{\"name\":\"file\",\"data_b64\":\"aGVsbG8=\"}]}"}', 'mi-forged-no-multipart'), 'failed', NULL, '%EXECUTE%');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    test_case record;
    actual_status text;
    result_text text;
    attempts integer;
    terminal_count integer;
    leaked boolean;
    engine_schema text := df.duroxide_schema();
BEGIN
    FOR test_case IN SELECT * FROM _mi_cases LOOP
        attempts := 0;
        LOOP
            actual_status := df.status(test_case.instance_id);
            EXIT WHEN actual_status IN ('completed', 'failed', 'cancelled') OR attempts >= 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        SELECT result::text INTO result_text FROM df.nodes
        WHERE instance_id = test_case.instance_id AND node_type IN ('HTTP', 'HTTP_MULTIPART');
        IF actual_status IS DISTINCT FROM test_case.expected THEN
            RAISE EXCEPTION 'TEST FAILED: MI instance % expected %, got %, result %', test_case.instance_id, test_case.expected, actual_status, result_text;
        END IF;
        IF test_case.error_pattern IS NOT NULL AND COALESCE(result_text, '') NOT LIKE test_case.error_pattern THEN
            RAISE EXCEPTION 'TEST FAILED: MI error did not match %: %', test_case.error_pattern, result_text;
        END IF;
        IF test_case.status_code IS NOT NULL AND (df.result(test_case.instance_id)::jsonb->>'status')::integer IS DISTINCT FROM test_case.status_code THEN
            RAISE EXCEPTION 'TEST FAILED: MI destination rejected authentication or followed a redirect: %', result_text;
        END IF;
        attempts := 0;
        LOOP
            EXECUTE format('SELECT count(*) FROM %I.history WHERE instance_id = $1 AND event_data::jsonb->>''type'' IN (''OrchestrationCompleted'', ''OrchestrationFailed'')', engine_schema)
                INTO terminal_count USING test_case.instance_id;
            EXIT WHEN terminal_count > 0 OR attempts >= 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        IF terminal_count = 0 THEN RAISE EXCEPTION 'TEST FAILED: MI terminal history not persisted'; END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.history WHERE instance_id = $1 AND event_data::text LIKE ''%%MI_PRIVATE_%%'')', engine_schema)
            INTO leaked USING test_case.instance_id;
        IF leaked THEN RAISE EXCEPTION 'TEST FAILED: MI token in durable history'; END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.executions AS execution WHERE instance_id = $1 AND row_to_json(execution)::text LIKE ''%%MI_PRIVATE_%%'')', engine_schema)
            INTO leaked USING test_case.instance_id;
        IF leaked THEN RAISE EXCEPTION 'TEST FAILED: MI token in execution state'; END IF;
        IF EXISTS (SELECT 1 FROM df.nodes AS node WHERE instance_id = test_case.instance_id AND row_to_json(node)::text LIKE '%MI_PRIVATE_%') THEN
            RAISE EXCEPTION 'TEST FAILED: MI token in node state';
        END IF;
        IF EXISTS (SELECT 1 FROM df.instances AS instance WHERE id = test_case.instance_id AND row_to_json(instance)::text LIKE '%MI_PRIVATE_%') THEN
            RAISE EXCEPTION 'TEST FAILED: MI token in instance state';
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM df.vars AS vars WHERE row_to_json(vars)::text LIKE '%MI_PRIVATE_%') THEN
        RAISE EXCEPTION 'TEST FAILED: MI token in durable variables';
    END IF;
END $$;

SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _mi_stats AS SELECT df.start(df.http(df.endpoint('mi_system', '/stats'), 'GET'), 'mi-cache-stats') AS instance_id;
DO $$
DECLARE
    instance text;
    actual_status text;
    attempts integer := 0;
    stats jsonb;
BEGIN
    SELECT instance_id INTO instance FROM _mi_stats;
    LOOP
        actual_status := df.status(instance);
        EXIT WHEN actual_status IN ('completed', 'failed', 'cancelled') OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF actual_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: MI stats request failed: %', df.result(instance);
    END IF;
    stats := (df.result(instance)::jsonb->>'body')::jsonb;
    IF stats->'token_requests' IS DISTINCT FROM '{"system":1,"11111111-1111-1111-1111-111111111111":1,"22222222-2222-2222-2222-222222222222":2}'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: MI token cache or permission gate mismatch: %', stats;
    END IF;
    IF jsonb_array_length(stats->'requests') IS DISTINCT FROM 6 THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected MI destination requests: %', stats;
    END IF;
END $$;
RESET SESSION AUTHORIZATION;
DROP TABLE _mi_cases, _mi_stats;
DROP SERVER mi_system, mi_user, mi_error, mi_denied;
DROP OWNED BY mi_no_http;
DROP ROLE mi_no_http;
SELECT 'TEST PASSED' AS result;