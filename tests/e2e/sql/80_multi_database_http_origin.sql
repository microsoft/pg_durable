-- Non-echoing loopback server checks colliding origin-local credentials.
-- The runner selects http-allow-all only for this test's local mock.
\getenv e80_port PGDURABLE_TEST_HTTP_PORT
SELECT set_config('test.e80_port', :'e80_port', false);
CREATE EXTENSION IF NOT EXISTS dblink;
DROP DATABASE IF EXISTS _e80_a WITH (FORCE);
DROP DATABASE IF EXISTS _e80_c WITH (FORCE);
DROP DATABASE IF EXISTS _e80_target WITH (FORCE);
CREATE DATABASE _e80_a;
CREATE DATABASE _e80_c;
CREATE DATABASE _e80_target;

CREATE TEMP TABLE _e80_sources(connection text, db text, route text, credential text);
INSERT INTO _e80_sources VALUES
    ('e80control', current_database(), 'control', 'E80_CONTROL'),
    ('e80a', '_e80_a', 'a', 'E80_A'),
    ('e80c', '_e80_c', 'c', 'E80_C');
DO $$
DECLARE
    source record;
BEGIN
    FOR source IN SELECT * FROM _e80_sources LOOP
        PERFORM dblink_connect(source.connection, format(
            'host=localhost port=%s dbname=%L user=postgres', current_setting('port'), source.db));
        IF source.db <> current_database() THEN
            PERFORM dblink_exec(source.connection, 'CREATE EXTENSION pg_durable');
        END IF;
        PERFORM dblink_exec(source.connection, format($remote$
            DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user', include_http => true); END $grant$;
            CREATE SERVER e80_endpoint FOREIGN DATA WRAPPER pg_durable_fdw
                OPTIONS (base_url %L, auth_scheme 'header', header_name 'X-Origin');
            CREATE SERVER e80_secrets FOREIGN DATA WRAPPER pg_durable_fdw
                OPTIONS (auth_scheme 'none');
            GRANT USAGE ON FOREIGN SERVER e80_endpoint, e80_secrets TO df_e2e_user;
            CREATE USER MAPPING FOR df_e2e_user SERVER e80_endpoint OPTIONS (header_value %L);
            CREATE USER MAPPING FOR df_e2e_user SERVER e80_secrets OPTIONS ("secret.probe" %L);
            CREATE TABLE public.e80_cases(id text, expected text, status_code int);
            GRANT SELECT, INSERT ON public.e80_cases TO df_e2e_user;
            SET SESSION AUTHORIZATION df_e2e_user;
        $remote$, format('https://127.0.0.1:%s/%s', current_setting('test.e80_port'), source.route),
            source.credential, source.credential));
    END LOOP;
END $$;

CREATE FUNCTION pg_temp.e80_submit(connection text, route text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM dblink_exec(connection, format($remote$
        INSERT INTO public.e80_cases VALUES
            (df.start(df.http(df.endpoint('e80_endpoint', '/'), 'GET'),
                'e80-endpoint', database => '_e80_target'), 'completed', 204),
            (df.start(df.http_multipart(df.endpoint('e80_endpoint', '/'),
                parts => '[{"name":"file","data_b64":"aA=="}]'),
                'e80-multipart', database => '_e80_target'), 'completed', 204),
            (df.start(df.with_http_options(df.http(%1$L, 'GET'),
                jsonb_build_object('secret_bindings', jsonb_build_object('headers',
                    jsonb_build_object('X-Origin', df.secret('e80_secrets', 'probe'))))),
                'e80-raw-secret', database => '_e80_target'), 'completed', 204),
            (df.start(df.with_http_options(df.http_multipart(%1$L,
                parts => '[{"name":"file","data_b64":"aA=="}]'),
                jsonb_build_object('secret_bindings', jsonb_build_object('headers',
                    jsonb_build_object('X-Origin', df.secret('e80_secrets', 'probe'))))),
                'e80-raw-multipart-secret', database => '_e80_target'), 'completed', 204);
    $remote$, format('https://127.0.0.1:%s/%s', current_setting('test.e80_port'), route)));
END $$;

SELECT pg_temp.e80_submit(connection, route) FROM _e80_sources;
CREATE FUNCTION pg_temp.e80_check(connection text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM dblink_exec(connection, $remote$
        DO $check$
        DECLARE item record; actual text; code int;
        BEGIN
            FOR item IN SELECT * FROM public.e80_cases LOOP
                actual := df.await_instance(item.id, 30);
                IF actual IS DISTINCT FROM item.expected THEN
                    RAISE EXCEPTION 'TEST FAILED: HTTP origin status %, expected %', actual, item.expected;
                END IF;
                IF item.expected = 'completed' THEN
                    code := (df.result(item.id)::jsonb->>'status')::int;
                    IF code IS DISTINCT FROM item.status_code THEN
                        RAISE EXCEPTION 'TEST FAILED: origin credential oracle returned %, expected %', code, item.status_code;
                    END IF;
                END IF;
            END LOOP;
        END $check$;
    $remote$);
END $$;
SELECT pg_temp.e80_check(connection) FROM _e80_sources;

-- Main's new response sink follows the SQL target, defaulting to the origin.
-- Credentials remain origin-local even when the sink target has no extension.
SELECT dblink_connect('e80target', format(
    'host=localhost port=%s dbname=_e80_target user=postgres', current_setting('port')));
SELECT dblink_exec('e80target', $sql$
    CREATE TABLE public.e80_sink(sink_key uuid PRIMARY KEY, body bytea NOT NULL);
    GRANT INSERT, SELECT ON public.e80_sink TO df_e2e_user;
$sql$);
DO $$
DECLARE source record;
BEGIN
    FOR source IN SELECT * FROM _e80_sources LOOP
        PERFORM dblink_exec(source.connection, $sql$
            RESET SESSION AUTHORIZATION;
            CREATE TABLE public.e80_sink(sink_key uuid PRIMARY KEY, body bytea NOT NULL);
            GRANT INSERT, SELECT ON public.e80_sink TO df_e2e_user;
            CREATE TABLE public.e80_sink_cases(id text, expected_database text);
            GRANT SELECT, INSERT ON public.e80_sink_cases TO df_e2e_user;
            SET SESSION AUTHORIZATION df_e2e_user;
            DO $start$
            DECLARE target text; node text; multipart bool;
            BEGIN
                FOREACH target IN ARRAY ARRAY[NULL::text, current_database()::text, '_e80_target'] LOOP
                    FOREACH multipart IN ARRAY ARRAY[false, true] LOOP
                        node := CASE WHEN multipart THEN df.http_multipart(
                            df.endpoint('e80_endpoint', '/'), parts => '[{"name":"file","data_b64":"aA=="}]')
                            ELSE df.http(df.endpoint('e80_endpoint', '/'), 'GET') END;
                        INSERT INTO public.e80_sink_cases VALUES (
                            df.start(df.with_http_options(node,
                                '{"response":"sink","into":"public.e80_sink","max_response_bytes":1}'),
                                'e80-sink', database => target),
                            COALESCE(target, current_database()));
                    END LOOP;
                END LOOP;
            END $start$;
        $sql$);
        PERFORM dblink_exec(source.connection, $sql$
            DO $check$
            DECLARE item record; response jsonb;
            BEGIN
                FOR item IN SELECT * FROM public.e80_sink_cases LOOP
                    IF df.await_instance(item.id, 30) <> 'completed' THEN
                        RAISE EXCEPTION 'TEST FAILED: origin HTTP sink failed';
                    END IF;
                    response := df.result(item.id)::jsonb;
                    IF response->>'sink_database' IS DISTINCT FROM item.expected_database
                        OR (response->>'status')::int IS DISTINCT FROM 204
                        OR response->>'body' IS NOT NULL THEN
                        RAISE EXCEPTION 'TEST FAILED: wrong sink target or retained body: %', response;
                    END IF;
                END LOOP;
                IF (SELECT count(*) FROM public.e80_sink WHERE octet_length(body) = 0) <> 4 THEN
                    RAISE EXCEPTION 'TEST FAILED: missing default/explicit-self origin sink rows';
                END IF;
            END $check$;
        $sql$);
    END LOOP;
END $$;
SELECT dblink_exec('e80target', $sql$
    DO $check$ BEGIN
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_durable')
            OR (SELECT count(*) FROM public.e80_sink WHERE octet_length(body) = 0) <> 6 THEN
            RAISE EXCEPTION 'TEST FAILED: expected six remote sink rows in extension-free target';
        END IF;
    END $check$;
$sql$);
SELECT dblink_disconnect('e80target');

-- New attempts see rotation, while other origins keep their own values.
SELECT dblink_exec('e80a', format($remote$
    RESET SESSION AUTHORIZATION;
    ALTER SERVER e80_endpoint OPTIONS (SET base_url %L);
    ALTER USER MAPPING FOR df_e2e_user SERVER e80_endpoint OPTIONS (SET header_value 'E80_A_ROTATED');
    ALTER USER MAPPING FOR df_e2e_user SERVER e80_secrets OPTIONS (SET "secret.probe" 'E80_A_ROTATED');
    TRUNCATE public.e80_cases;
    SET SESSION AUTHORIZATION df_e2e_user;
$remote$, format('https://127.0.0.1:%s/a-rotated', current_setting('test.e80_port'))));
SELECT pg_temp.e80_submit('e80a', 'a-rotated');
SELECT pg_temp.e80_check(connection) FROM _e80_sources;

-- Local revocation must fail closed, never fall back to control or C mappings.
SELECT dblink_exec('e80a', $remote$
    RESET SESSION AUTHORIZATION;
    REVOKE USAGE ON FOREIGN SERVER e80_endpoint, e80_secrets FROM df_e2e_user;
    TRUNCATE public.e80_cases;
    SET SESSION AUTHORIZATION df_e2e_user;
$remote$);
SELECT pg_temp.e80_submit('e80a', 'a-rotated');
SELECT dblink_exec('e80a', $remote$
    RESET SESSION AUTHORIZATION;
    UPDATE public.e80_cases SET expected = 'failed';
    SET SESSION AUTHORIZATION df_e2e_user;
$remote$);
SELECT pg_temp.e80_check(connection) FROM _e80_sources;
DO $$
DECLARE
    leaked bool;
BEGIN
    EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM %I.history WHERE event_data::text LIKE ANY ($1))',
        df.duroxide_schema()) INTO leaked
        USING ARRAY['%E80_CONTROL%', '%E80_A%', '%E80_C%'];
    IF leaked THEN RAISE EXCEPTION 'TEST FAILED: origin credential persisted in engine history'; END IF;
END $$;
SELECT dblink_disconnect(connection) FROM _e80_sources;
DROP SERVER e80_endpoint, e80_secrets CASCADE;
BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT id FROM public.e80_cases UNION ALL SELECT id FROM public.e80_sink_cases);
DELETE FROM df.instances WHERE id IN (SELECT id FROM public.e80_cases UNION ALL SELECT id FROM public.e80_sink_cases);
COMMIT;
DROP TABLE public.e80_cases;
DROP TABLE public.e80_sink_cases, public.e80_sink;
DROP DATABASE _e80_a WITH (FORCE);
DROP DATABASE _e80_c WITH (FORCE);
DROP DATABASE _e80_target WITH (FORCE);
DROP TABLE _e80_sources;
DROP FUNCTION pg_temp.e80_submit(text, text), pg_temp.e80_check(text);
SELECT 'TEST PASSED: HTTP endpoint and secret catalogs are origin-local' AS result;
