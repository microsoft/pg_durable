RESET SESSION AUTHORIZATION;
SELECT current_database() AS sink_control_database \gset
DROP DATABASE IF EXISTS _test_http_sink_target;
CREATE DATABASE _test_http_sink_target TEMPLATE template0;
ALTER DATABASE _test_http_sink_target SET synchronous_commit = off;
\connect _test_http_sink_target
CREATE SCHEMA _http_sink_context;
ALTER ROLE df_e2e_user IN DATABASE _test_http_sink_target
    SET search_path = _http_sink_context, public, pg_catalog;
CREATE TABLE _http_sink_context.audit_log (
    sink_key UUID PRIMARY KEY,
    owner TEXT NOT NULL DEFAULT CURRENT_USER,
    search_path TEXT NOT NULL DEFAULT current_setting('search_path')
);
GRANT USAGE ON SCHEMA _http_sink_context TO df_e2e_user;
GRANT SELECT, INSERT ON _http_sink_context.audit_log TO df_e2e_user;
CREATE FUNCTION _http_sink_context.unexpected_char_equality(pg_catalog."char", pg_catalog."char")
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Sink resolved an internal equality operator through search_path';
END $$;
CREATE OPERATOR _http_sink_context.= (
    LEFTARG = pg_catalog."char", RIGHTARG = pg_catalog."char",
    FUNCTION = _http_sink_context.unexpected_char_equality
);
CREATE TABLE public._http_sink_target (
    sink_key UUID PRIMARY KEY,
    body BYTEA NOT NULL,
    owner TEXT NOT NULL DEFAULT CURRENT_USER
);
GRANT USAGE ON SCHEMA public TO df_e2e_user;
GRANT SELECT, INSERT ON public._http_sink_target TO df_e2e_user;
CREATE FUNCTION public._http_sink_sync_commit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('synchronous_commit') IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Sink write did not enable synchronous commit';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER http_sink_sync_commit BEFORE INSERT ON public._http_sink_target
    FOR EACH ROW EXECUTE FUNCTION public._http_sink_sync_commit();
CREATE FUNCTION public._http_sink_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF pg_catalog.current_setting('search_path') IS DISTINCT FROM '_http_sink_context, public, pg_catalog' THEN
        RAISE EXCEPTION 'Sink did not preserve the submitting role search_path';
    END IF;
    INSERT INTO audit_log (sink_key) VALUES (NEW.sink_key);
    RETURN NEW;
END $$;
CREATE TRIGGER http_sink_audit AFTER INSERT ON public._http_sink_target
    FOR EACH ROW EXECUTE FUNCTION public._http_sink_audit();
\connect :sink_control_database

DROP SCHEMA IF EXISTS "Sink.Schema" CASCADE;
CREATE SCHEMA "Sink.Schema";
CREATE TABLE "Sink.Schema"."Body.Table" (
    sink_key UUID PRIMARY KEY, body BYTEA NOT NULL, owner TEXT NOT NULL DEFAULT CURRENT_USER
);
GRANT USAGE ON SCHEMA "Sink.Schema" TO df_e2e_user;
GRANT SELECT, INSERT ON "Sink.Schema"."Body.Table" TO df_e2e_user;
DROP TABLE IF EXISTS public._http_sink, public._http_sink_denied,
    public._http_sink_insert_only, public._http_sink_rls_denied, public._http_sink_unlogged,
    public._http_sink_mutated, public._http_sink_skipped, public._http_sink_constraint,
    public._http_sink_trigger_error, public._http_sink_hidden, public._http_sink_slow,
    public._http_sink_partitioned, public._http_sink_partitioned_unlogged,
    public._http_sink_partitioned_foreign, public._http_sink_foreign_data;
DROP SERVER IF EXISTS _http_sink_loopback CASCADE;
CREATE TABLE public._http_sink (
    sink_key UUID PRIMARY KEY,
    body BYTEA NOT NULL,
    owner TEXT NOT NULL DEFAULT CURRENT_USER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public._http_sink ENABLE ROW LEVEL SECURITY;
CREATE POLICY http_sink_owner ON public._http_sink
    USING (owner = CURRENT_USER) WITH CHECK (owner = CURRENT_USER);
CREATE TABLE public._http_sink_denied (LIKE public._http_sink INCLUDING ALL);
CREATE TABLE public._http_sink_insert_only (LIKE public._http_sink INCLUDING ALL);
CREATE TABLE public._http_sink_rls_denied (LIKE public._http_sink INCLUDING ALL);
ALTER TABLE public._http_sink_rls_denied ENABLE ROW LEVEL SECURITY;
CREATE POLICY http_sink_deny ON public._http_sink_rls_denied
    USING (true) WITH CHECK (false);
CREATE UNLOGGED TABLE public._http_sink_unlogged (LIKE public._http_sink INCLUDING ALL);
CREATE TABLE public._http_sink_mutated (LIKE public._http_sink INCLUDING ALL);
CREATE TABLE public._http_sink_skipped (LIKE public._http_sink INCLUDING ALL);
CREATE TABLE public._http_sink_constraint (LIKE public._http_sink INCLUDING ALL,
    CHECK (octet_length(body) = 0));
CREATE TABLE public._http_sink_trigger_error (LIKE public._http_sink INCLUDING ALL);
CREATE TABLE public._http_sink_hidden (LIKE public._http_sink INCLUDING ALL);
CREATE TABLE public._http_sink_slow (LIKE public._http_sink INCLUDING ALL);
CREATE TABLE public._http_sink_partitioned (LIKE public._http_sink INCLUDING ALL)
    PARTITION BY LIST (sink_key);
CREATE TABLE public._http_sink_cold_partition PARTITION OF public._http_sink_partitioned
    FOR VALUES IN ('00000000-0000-0000-0000-000000000000');
CREATE TABLE public._http_sink_partition PARTITION OF public._http_sink_partitioned DEFAULT;
CREATE TABLE public._http_sink_partitioned_unlogged (LIKE public._http_sink INCLUDING ALL)
    PARTITION BY HASH (sink_key);
CREATE UNLOGGED TABLE public._http_sink_unlogged_partition PARTITION OF public._http_sink_partitioned_unlogged
    FOR VALUES WITH (MODULUS 1, REMAINDER 0);
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DO $$
BEGIN
    EXECUTE format('CREATE SERVER _http_sink_loopback FOREIGN DATA WRAPPER postgres_fdw
        OPTIONS (host ''127.0.0.1'', port %L, dbname %L)', current_setting('port'), current_database());
END $$;
CREATE USER MAPPING FOR df_e2e_user SERVER _http_sink_loopback
    OPTIONS (user 'df_e2e_user', password_required 'false');
GRANT USAGE ON FOREIGN SERVER _http_sink_loopback TO df_e2e_user;
CREATE UNLOGGED TABLE public._http_sink_foreign_data (sink_key UUID PRIMARY KEY, body BYTEA NOT NULL);
CREATE TABLE public._http_sink_partitioned_foreign (sink_key UUID, body BYTEA NOT NULL)
    PARTITION BY HASH (sink_key);
CREATE FOREIGN TABLE public._http_sink_foreign_partition PARTITION OF public._http_sink_partitioned_foreign
    FOR VALUES WITH (MODULUS 1, REMAINDER 0)
    SERVER _http_sink_loopback OPTIONS (schema_name 'public', table_name '_http_sink_foreign_data');
ALTER TABLE public._http_sink_hidden ENABLE ROW LEVEL SECURITY;
CREATE POLICY http_sink_insert ON public._http_sink_hidden FOR INSERT WITH CHECK (true);
CREATE POLICY http_sink_hide ON public._http_sink_hidden FOR SELECT USING (false);
CREATE OR REPLACE FUNCTION public._http_sink_mutate() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.body := '\x00'::bytea;
    RETURN NEW;
END $$;
CREATE TRIGGER http_sink_mutate BEFORE INSERT ON public._http_sink_mutated
    FOR EACH ROW EXECUTE FUNCTION public._http_sink_mutate();
CREATE OR REPLACE FUNCTION public._http_sink_skip() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RETURN NULL;
END $$;
CREATE TRIGGER http_sink_skip BEFORE INSERT ON public._http_sink_skipped
    FOR EACH ROW EXECUTE FUNCTION public._http_sink_skip();
CREATE OR REPLACE FUNCTION public._http_sink_trigger_fail() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Sink body was %', encode(NEW.body, 'escape');
END $$;
CREATE CONSTRAINT TRIGGER http_sink_trigger_fail AFTER INSERT ON public._http_sink_trigger_error
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public._http_sink_trigger_fail();
CREATE OR REPLACE FUNCTION public._http_sink_wait() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_sleep(45);
    RETURN NEW;
END $$;
CREATE TRIGGER http_sink_wait BEFORE INSERT ON public._http_sink_slow
    FOR EACH ROW EXECUTE FUNCTION public._http_sink_wait();
REVOKE ALL ON public._http_sink, public._http_sink_denied, public._http_sink_insert_only,
    public._http_sink_rls_denied, public._http_sink_unlogged, public._http_sink_mutated,
    public._http_sink_skipped, public._http_sink_constraint, public._http_sink_trigger_error,
    public._http_sink_hidden, public._http_sink_slow, public._http_sink_partitioned,
    public._http_sink_partitioned_unlogged, public._http_sink_partition,
    public._http_sink_unlogged_partition, public._http_sink_cold_partition,
    public._http_sink_partitioned_foreign, public._http_sink_foreign_partition,
    public._http_sink_foreign_data FROM PUBLIC, df_e2e_user;
GRANT SELECT, INSERT ON public._http_sink, public._http_sink_rls_denied,
    public._http_sink_unlogged, public._http_sink_mutated, public._http_sink_skipped,
    public._http_sink_constraint, public._http_sink_trigger_error, public._http_sink_hidden,
    public._http_sink_slow, public._http_sink_partitioned, public._http_sink_partitioned_unlogged,
    public._http_sink_partitioned_foreign, public._http_sink_foreign_data TO df_e2e_user;
GRANT INSERT ON public._http_sink_insert_only TO df_e2e_user;
SELECT df.grant_usage('df_e2e_user', include_http => true);

SELECT dblink_connect('_http_sink_partition_lock', format('host=127.0.0.1 port=%s dbname=%L user=%L',
    current_setting('port'), current_database(), CURRENT_USER));
SELECT dblink_exec('_http_sink_partition_lock', 'BEGIN');
SELECT dblink_exec('_http_sink_partition_lock', 'LOCK TABLE ONLY public._http_sink_cold_partition IN SHARE MODE');

CREATE TEMP TABLE _http_sink_cases (
    instance_id TEXT,
    expected_status TEXT,
    http_status INTEGER,
    expected_body BYTEA,
    error_pattern TEXT,
    table_name TEXT NOT NULL DEFAULT 'public._http_sink',
    database_name TEXT NOT NULL DEFAULT current_database()
);
GRANT SELECT, INSERT ON _http_sink_cases TO df_e2e_user;
SET SESSION AUTHORIZATION df_e2e_user;

DO $$
DECLARE
    request_node TEXT;
    invalid_options JSONB;
    invalid_name TEXT;
    actual_error TEXT;
BEGIN
    FOREACH request_node IN ARRAY ARRAY[
        df.http('https://httpbingo.org/status/204', 'GET'),
        df.http_multipart('https://httpbingo.org/status/204', parts => '[{"name":"field","data_b64":"YWJj"}]')
    ] LOOP
        FOREACH invalid_options IN ARRAY ARRAY[
            '{"response":"sink"}'::jsonb,
            '{"response":"sink","into":""}'::jsonb,
            '{"response":"metadata","into":"public._http_sink"}'::jsonb,
            '{"into":"public._http_sink"}'::jsonb,
            '{"response":"sink","into":42}'::jsonb,
            '{"response":"sink","into":"_http_sink"}'::jsonb,
            '{"response":"sink","into":"public."}'::jsonb,
            '{"response":"sink","into":"database.public._http_sink"}'::jsonb,
            '{"response":"sink","into":"public._http_sink; DROP TABLE public._http_sink"}'::jsonb
        ] LOOP
            actual_error := NULL;
            BEGIN
                PERFORM df.with_http_options(request_node, invalid_options);
            EXCEPTION WHEN others THEN
                actual_error := SQLERRM;
            END;
            IF actual_error IS NULL THEN
                RAISE EXCEPTION 'TEST FAILED: invalid sink options accepted: %', invalid_options;
            END IF;
        END LOOP;
        FOREACH invalid_name IN ARRAY ARRAY[
            '_http_sink', 'public.', 'database.public._http_sink',
            'public._http_sink; DROP TABLE public._http_sink'
        ] LOOP
            actual_error := NULL;
            BEGIN
                PERFORM df.start(jsonb_set(request_node::jsonb, '{query}',
                    to_jsonb(((request_node::jsonb->>'query')::jsonb ||
                        jsonb_build_object('response', 'sink', 'into', invalid_name))::text)
                )::text, 'test-http-sink-invalid-name');
            EXCEPTION WHEN others THEN
                actual_error := SQLERRM;
            END;
            IF actual_error IS NULL THEN
                RAISE EXCEPTION 'TEST FAILED: invalid raw sink destination was submitted: %', invalid_name;
            END IF;
        END LOOP;
    END LOOP;
    IF EXISTS (SELECT 1 FROM df.instances WHERE label = 'test-http-sink-invalid-name') THEN
        RAISE EXCEPTION 'TEST FAILED: invalid sink destination was persisted';
    END IF;
END $$;

INSERT INTO _http_sink_cases
SELECT df.start(df.with_http_options(request_node,
           '{"response":"sink","into":"public._http_sink","response_headers":[],"max_response_bytes":18}'),
           'test-http-sink-binary'),
       'completed', 200, decode('AP9TSU5LX1BSSVZBVEVfMzc2', 'base64'), NULL
FROM (VALUES
    (df.http('https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2', 'GET')),
    (df.http_multipart('https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2',
        parts => '[{"name":"field","data_b64":"YWJj"}]'))
) AS requests(request_node)
CROSS JOIN generate_series(1, 2);

INSERT INTO _http_sink_cases
SELECT df.start(df.with_http_options(df.http('https://httpbingo.org/status/' || status_code, 'GET'),
           '{"response":"sink","into":"public._http_sink","response_headers":[],"max_response_bytes":0}'),
           'test-http-sink-status-' || status_code),
       CASE WHEN status_code = 500 THEN 'failed' ELSE 'completed' END,
       status_code, ''::bytea, CASE WHEN status_code = 500 THEN '%response body omitted%' END
FROM (VALUES (204), (400), (500)) AS statuses(status_code);

INSERT INTO _http_sink_cases VALUES
    (df.start(df.with_http_options(df.http('https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2', 'GET'),
        '{"response":"sink","into":"public._http_sink","response_headers":[],"max_response_bytes":17}'),
        'test-http-sink-overflow'), 'failed', NULL, NULL, '%max_response_bytes%'),
    (df.start(
        df.with_http_options(df.http('https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2', 'GET'),
            '{"response":"sink","into":"public._http_sink","response_headers":[],"max_response_bytes":18}') |=> 'payload'
        ~> 'SELECT octet_length(body) AS bytes FROM public._http_sink WHERE sink_key = $payload.sink_key::uuid',
        'test-http-sink-read-back'), 'completed', 200, decode('AP9TSU5LX1BSSVZBVEVfMzc2', 'base64'), NULL);

INSERT INTO _http_sink_cases VALUES
    (df.start(df.with_http_options(df.http('https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2', 'GET'),
        '{"response":"sink","into":"\"Sink.Schema\".\"Body.Table\"","response_headers":[],"max_response_bytes":18}'),
        'test-http-sink-quoted-table'), 'completed', 200, decode('AP9TSU5LX1BSSVZBVEVfMzc2', 'base64'), NULL,
        '"Sink.Schema"."Body.Table"', current_database()),
    (df.start(df.with_http_options(df.http('https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2', 'GET'),
        '{"response":"sink","into":"public._http_sink_partitioned","response_headers":[],"max_response_bytes":18}'),
        'test-http-sink-partitioned'), 'completed', 200, decode('AP9TSU5LX1BSSVZBVEVfMzc2', 'base64'), NULL,
        'public._http_sink_partitioned', current_database());

INSERT INTO _http_sink_cases VALUES
    (df.start(df.with_http_options(df.http('https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2', 'GET'),
        '{"response":"sink","into":"public._http_sink_slow","response_headers":[],"max_response_bytes":18}'),
        'test-http-sink-timeout'), 'failed', NULL, NULL, '%HTTP response sink%');

INSERT INTO _http_sink_cases
SELECT df.start(
           jsonb_build_object('node_type', node_type, 'query', jsonb_build_object(
               'url', 'https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2',
               'method', 'POST', 'parts', '[{"name":"field","data_b64":"YWJj"}]'::jsonb,
               'response', response_mode, 'into', table_name,
               'response_headers', '[]'::jsonb, 'max_response_bytes', 18,
               'submitted_by', 'postgres', 'database',
                   CASE WHEN target_database IS NULL THEN '_test_http_sink_target' ELSE current_database() END
           )::text)::text |=> 'payload'
           ~> format('SELECT octet_length(body) AS bytes, owner, encode(sha256(body), ''hex'') AS digest
               FROM %s WHERE sink_key = $payload.sink_key::uuid', table_name),
           'test-http-sink-target-database', database => target_database),
       'completed', 200, decode('AP9TSU5LX1BSSVZBVEVfMzc2', 'base64'), NULL,
       table_name, COALESCE(target_database, current_database())
FROM (VALUES ('HTTP'), ('HTTP_MULTIPART')) AS requests(node_type)
CROSS JOIN (VALUES ('"sink"'::jsonb), ('{"sink":null}'::jsonb)) AS modes(response_mode)
CROSS JOIN (VALUES
    ('public._http_sink_target', '_test_http_sink_target'),
    ('public._http_sink', NULL)
) AS destinations(table_name, target_database);

INSERT INTO _http_sink_cases
SELECT df.start(df.with_http_options(df.http('https://httpbingo.org/base64/AP9TSU5LX1BSSVZBVEVfMzc2', 'GET'),
           jsonb_build_object('response', 'sink', 'into', sink_table,
               'response_headers', '[]'::jsonb, 'max_response_bytes', 18)),
           'test-http-sink-rejected'),
       'failed', NULL, NULL, error_pattern
FROM (VALUES
    ('public._http_sink_denied', '%SQLSTATE 42501%'),
    ('public._http_sink_insert_only', '%SQLSTATE 42501%'),
    ('public._http_sink_rls_denied', '%SQLSTATE 42501%'),
    ('public._http_sink_unlogged', '%requires a permanent table%'),
    ('public._http_sink_partitioned_unlogged', '%not durable%'),
    ('public._http_sink_partitioned_foreign', '%not durable%'),
    ('public._http_sink_mutated', '%key or body was changed%'),
    ('public._http_sink_skipped', '%did not insert exactly one row%'),
    ('public._http_sink_constraint', '%SQLSTATE 23514%'),
    ('public._http_sink_trigger_error', '%SQLSTATE P0001%'),
    ('public._http_sink_hidden', '%row is missing%'),
    ('public._http_sink_missing', '%SQLSTATE 42P01%')
) AS destinations(sink_table, error_pattern);

DO $$
DECLARE
    test_case RECORD;
    actual_status TEXT;
    response JSONB;
    stored_body BYTEA;
    stored_owner TEXT;
    target_result JSONB;
    expected_rows INTEGER;
BEGIN
    FOR test_case IN SELECT * FROM _http_sink_cases LOOP
        actual_status := df.await_instance(test_case.instance_id, 60);
        SELECT result INTO response FROM df.nodes
        WHERE instance_id = test_case.instance_id AND node_type IN ('HTTP', 'HTTP_MULTIPART');
        IF actual_status IS DISTINCT FROM test_case.expected_status THEN
            RAISE EXCEPTION 'TEST FAILED: sink instance % expected %, got %, result %',
                test_case.instance_id, test_case.expected_status, actual_status, response;
        END IF;
        IF test_case.error_pattern IS NOT NULL THEN
            IF response IS NULL OR response::text NOT LIKE test_case.error_pattern THEN
                RAISE EXCEPTION 'TEST FAILED: sink error did not match %: %', test_case.error_pattern, response;
            END IF;
            CONTINUE;
        END IF;
        IF response ? 'body' OR response ? 'encoding'
              OR response->>'sink' IS DISTINCT FROM test_case.table_name
              OR response->>'sink_database' IS DISTINCT FROM test_case.database_name
           OR (response->>'status')::integer IS DISTINCT FROM test_case.http_status
           OR (response->>'ok')::boolean IS DISTINCT FROM (test_case.http_status BETWEEN 200 AND 299)
           OR response->'headers' IS DISTINCT FROM '{}'::jsonb
           OR (response->>'bytes')::integer IS DISTINCT FROM octet_length(test_case.expected_body)
           OR response->>'sha256' IS DISTINCT FROM encode(sha256(test_case.expected_body), 'hex') THEN
            RAISE EXCEPTION 'TEST FAILED: invalid sink envelope: %', response;
        END IF;
        IF test_case.database_name IS DISTINCT FROM current_database() THEN
            target_result := df.result(test_case.instance_id)::jsonb->'rows'->0;
            IF (target_result->>'bytes')::integer IS DISTINCT FROM octet_length(test_case.expected_body)
               OR target_result->>'digest' IS DISTINCT FROM response->>'sha256'
               OR target_result->>'owner' IS DISTINCT FROM CURRENT_USER THEN
                RAISE EXCEPTION 'TEST FAILED: sink did not use the trusted target database and role: %', target_result;
            END IF;
            CONTINUE;
        END IF;
        EXECUTE format('SELECT body, owner FROM %s WHERE sink_key = $1', test_case.table_name)
            INTO stored_body, stored_owner USING (response->>'sink_key')::uuid;
        IF stored_body IS DISTINCT FROM test_case.expected_body OR stored_owner IS DISTINCT FROM CURRENT_USER THEN
            RAISE EXCEPTION 'TEST FAILED: stored sink bytes or submitting identity differ';
        END IF;
    END LOOP;
        SELECT count(*) INTO expected_rows FROM _http_sink_cases
        WHERE expected_status = 'completed' AND table_name = 'public._http_sink'
            AND database_name = current_database();
    IF (SELECT count(*) FROM public._http_sink) IS DISTINCT FROM expected_rows THEN
        RAISE EXCEPTION 'TEST FAILED: sink attempts overwrote rows or failed responses left rows';
    END IF;
    IF EXISTS (
        SELECT 1 FROM df.instances
        WHERE label = 'test-http-sink-read-back'
          AND (df.result(id)::jsonb->'rows'->0->>'bytes')::integer IS DISTINCT FROM 18
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: downstream SQL could not consume the committed sink reference';
    END IF;
END $$;
RESET SESSION AUTHORIZATION;

SELECT dblink_exec('_http_sink_partition_lock', 'ROLLBACK');
SELECT dblink_disconnect('_http_sink_partition_lock');

DO $$
DECLARE
    test_case RECORD;
    terminal_count INTEGER;
    attempts INTEGER;
    leaked BOOLEAN;
    engine_schema TEXT := df.duroxide_schema();
BEGIN
    IF EXISTS (SELECT 1 FROM public._http_sink_denied)
       OR EXISTS (SELECT 1 FROM public._http_sink_insert_only)
       OR EXISTS (SELECT 1 FROM public._http_sink_rls_denied)
    OR EXISTS (SELECT 1 FROM public._http_sink_unlogged)
    OR EXISTS (SELECT 1 FROM public._http_sink_mutated)
    OR EXISTS (SELECT 1 FROM public._http_sink_skipped)
    OR EXISTS (SELECT 1 FROM public._http_sink_constraint)
    OR EXISTS (SELECT 1 FROM public._http_sink_trigger_error)
    OR EXISTS (SELECT 1 FROM public._http_sink_hidden)
    OR EXISTS (SELECT 1 FROM public._http_sink_slow)
    OR EXISTS (SELECT 1 FROM public._http_sink_partitioned_unlogged)
    OR EXISTS (SELECT 1 FROM public._http_sink_foreign_data) THEN
        RAISE EXCEPTION 'TEST FAILED: a rejected sink write committed data';
    END IF;
    FOR test_case IN SELECT * FROM _http_sink_cases LOOP
        attempts := 0;
        LOOP
            EXECUTE format('SELECT count(*) FROM %I.history WHERE instance_id = $1
                AND event_data::jsonb->>''type'' IN (''OrchestrationCompleted'', ''OrchestrationFailed'')', engine_schema)
                INTO terminal_count USING test_case.instance_id;
            EXIT WHEN terminal_count > 0 OR attempts >= 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        IF terminal_count = 0 THEN
            RAISE EXCEPTION 'TEST FAILED: sink terminal history was not persisted';
        END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.history
            WHERE (instance_id = $1 OR starts_with(instance_id, $1 || ''::''))
              AND (strpos(event_data::text, ''SINK_PRIVATE_376'') > 0
                OR strpos(event_data::text, ''00ff53494e4b5f505249564154455f333736'') > 0))', engine_schema)
            INTO leaked USING test_case.instance_id;
        IF leaked THEN
            RAISE EXCEPTION 'TEST FAILED: sink body entered durable history';
        END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.executions AS execution
            WHERE (instance_id = $1 OR starts_with(instance_id, $1 || ''::''))
              AND strpos(row_to_json(execution)::text, ''SINK_PRIVATE_376'') > 0)', engine_schema)
            INTO leaked USING test_case.instance_id;
        IF leaked OR EXISTS (SELECT 1 FROM df.nodes AS node
            WHERE instance_id = test_case.instance_id AND strpos(row_to_json(node)::text, 'SINK_PRIVATE_376') > 0) THEN
            RAISE EXCEPTION 'TEST FAILED: sink body entered persisted workflow state';
        END IF;
    END LOOP;
END $$;

DROP TABLE _http_sink_cases;
DROP TABLE public._http_sink, public._http_sink_denied, public._http_sink_insert_only,
    public._http_sink_rls_denied, public._http_sink_unlogged, public._http_sink_mutated,
    public._http_sink_skipped, public._http_sink_constraint, public._http_sink_trigger_error,
    public._http_sink_hidden, public._http_sink_slow, public._http_sink_partitioned,
    public._http_sink_partitioned_unlogged, public._http_sink_partitioned_foreign,
    public._http_sink_foreign_data;
DROP SERVER _http_sink_loopback CASCADE;
DROP FUNCTION public._http_sink_mutate(), public._http_sink_skip(), public._http_sink_trigger_fail(), public._http_sink_wait();
DROP SCHEMA "Sink.Schema" CASCADE;
DROP DATABASE _test_http_sink_target;
SELECT 'TEST PASSED' AS result;