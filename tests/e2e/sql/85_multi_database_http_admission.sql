-- The non-echoing TLS oracle records only case names, never credentials.
-- A logged successful first privilege check plus an occupied catalog permit
-- makes revocation/replacement occur after authorization but before dispatch.
\getenv e85_port PGDURABLE_TEST_HTTP_PORT
\getenv e85_log PGDURABLE_TEST_SERVER_LOG
\getenv e85_counts PGDURABLE_TEST_HTTP_COUNTS
SELECT set_config('test.e85_port', :'e85_port', false),
    set_config('test.e85_log', :'e85_log', false),
    set_config('test.e85_counts', :'e85_counts', false);
CREATE EXTENSION IF NOT EXISTS dblink;
DO $$ BEGIN
    IF current_setting('pg_durable.max_user_connections')::int <> 1
        OR current_setting('pg_durable.reconcile_interval')::int <> 0 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires one user slot and disabled reconciliation';
    END IF;
END $$;
DROP DATABASE IF EXISTS _e85_origin WITH (FORCE);
DROP DATABASE IF EXISTS _e85_target WITH (FORCE);
CREATE DATABASE _e85_origin;
CREATE DATABASE _e85_target;
SELECT dblink_connect('e85source', format(
    'host=localhost port=%s dbname=_e85_origin user=postgres', current_setting('port')));
SELECT dblink_connect('e85gate', format(
    'host=localhost port=%s dbname=%L user=postgres', current_setting('port'), current_database()));
CREATE TEMP TABLE _e85_cases(name text PRIMARY KEY, id text, engine_id text, control_id text, log_offset bigint);
CREATE FUNCTION pg_temp.e85_setup() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM dblink_exec('e85source', format($sql$
        CREATE EXTENSION IF NOT EXISTS pg_durable;
        DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user', include_http => true); END $grant$;
        DROP SERVER IF EXISTS e85_endpoint, e85_secrets CASCADE;
        CREATE SERVER e85_endpoint FOREIGN DATA WRAPPER pg_durable_fdw
            OPTIONS (base_url %L, auth_scheme 'header', header_name 'X-Origin');
        CREATE SERVER e85_secrets FOREIGN DATA WRAPPER pg_durable_fdw OPTIONS (auth_scheme 'none');
        GRANT USAGE ON FOREIGN SERVER e85_endpoint, e85_secrets TO df_e2e_user;
        CREATE USER MAPPING FOR df_e2e_user SERVER e85_endpoint OPTIONS (header_value 'E80_A');
        CREATE USER MAPPING FOR df_e2e_user SERVER e85_secrets OPTIONS ("secret.probe" 'E80_A');
    $sql$, format('https://127.0.0.1:%s/a', current_setting('test.e85_port'))));
END $$;
SELECT pg_temp.e85_setup();
CREATE FUNCTION pg_temp.e85_wait(check_sql text, assertion text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + interval '15 seconds'; satisfied bool;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE check_sql INTO satisfied;
        IF satisfied IS TRUE THEN RETURN; END IF;
        IF clock_timestamp() >= deadline THEN RAISE EXCEPTION 'TEST FAILED [%]: deadline exceeded', assertion; END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;
DO $$ BEGIN
    EXECUTE format($view$
        CREATE TEMP VIEW _e85_history AS
        SELECT c.name, outcome.event_data::jsonb->>'type' AS outcome,
            outcome.event_data::jsonb #>> '{details,Application,message}' AS error
        FROM %1$I.history scheduled JOIN _e85_cases c
          ON split_part(scheduled.instance_id, '::', 1) = c.engine_id
        LEFT JOIN %1$I.history outcome
          ON outcome.instance_id = scheduled.instance_id
         AND outcome.execution_id = scheduled.execution_id
         AND outcome.event_data::jsonb->>'source_event_id' = scheduled.event_id::text
         AND outcome.event_data::jsonb->>'type' IN ('ActivityFailed', 'ActivityCompleted')
        WHERE scheduled.event_data::jsonb->>'type' = 'ActivityScheduled'
          AND scheduled.event_data::jsonb->>'name' IN ('pg_durable::activity::execute-http',
              'pg_durable::activity::execute-multipart')
    $view$, df.duroxide_schema());
END $$;
CREATE FUNCTION pg_temp.e85_start(case_name text, multipart bool) RETURNS void LANGUAGE plpgsql AS $$
DECLARE control_id text; request text; offset_bytes bigint;
BEGIN
    PERFORM dblink_exec('e85gate', 'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(850085, 1); END $hold$');
    control_id := df.start('SELECT pg_advisory_xact_lock(850085, 1)', 'e85-control-' || case_name,
        transaction_mode => 'new');
    PERFORM pg_temp.e85_wait($check$
        SELECT EXISTS (SELECT 1 FROM pg_stat_activity a JOIN pg_locks l USING (pid)
            WHERE a.application_name = 'pg_durable:worker:workflow-sql'
              AND l.locktype = 'advisory' AND l.classid = 850085 AND l.objid = 1 AND NOT l.granted)
    $check$, 'control occupies catalog permit');
    offset_bytes := (pg_stat_file(current_setting('test.e85_log'))).size;
    request := CASE WHEN multipart THEN format($expr$
        df.with_http_options(df.http_multipart(%L, parts => '[{"name":"file","data_b64":"aA=="}]'),
            jsonb_build_object('secret_bindings', jsonb_build_object('headers',
                jsonb_build_object('X-Origin', df.secret('e85_secrets', 'probe')))))
    $expr$, format('https://127.0.0.1:%s/a?case=%s', current_setting('test.e85_port'), case_name))
    ELSE format('df.http(df.endpoint(''e85_endpoint'', %L), ''GET'')', '/?case=' || case_name) END;
    PERFORM dblink_exec('e85source', 'SET SESSION AUTHORIZATION df_e2e_user');
    INSERT INTO _e85_cases SELECT case_name, id, prefix || id, control_id, offset_bytes
        FROM dblink('e85source', format($sql$
            SELECT df.start(%s, %L, database => '_e85_target'),
                'pgdf-' || (SELECT oid FROM pg_database WHERE datname = current_database()) ||
                '-' || (SELECT replace(id::text, '-', '') FROM df._installation) || '-'
        $sql$, request, 'e85-' || case_name)) AS source(id text, prefix text);
    PERFORM dblink_exec('e85source', 'RESET SESSION AUTHORIZATION');
    PERFORM pg_temp.e85_wait(format($check$
        SELECT pg_read_file(current_setting('test.e85_log'), log_offset, 1048576, true)
            LIKE '%%authorization checked; preparing request%%instance_id=' || engine_id || ' %%'
          AND EXISTS (SELECT 1 FROM _e85_history h WHERE h.name = c.name AND outcome IS NULL)
          AND NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e85_origin'
              AND application_name = 'pg_durable:worker:workflow-sql')
        FROM _e85_cases c WHERE name = %L
    $check$, case_name), 'initial HTTP authorization succeeded before catalog admission');
END $$;
CREATE FUNCTION pg_temp.e85_finish(case_name text, expected_error text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE expected text := CASE WHEN expected_error IS NULL THEN 'ActivityCompleted' ELSE 'ActivityFailed' END;
    requests int; status text; code int;
BEGIN
    PERFORM dblink_exec('e85gate', 'COMMIT');
    PERFORM pg_temp.e85_wait(format(
        'SELECT EXISTS (SELECT 1 FROM _e85_history WHERE name = %L AND outcome IS NOT NULL)', case_name),
        'HTTP activity outcome recorded');
    IF NOT EXISTS (SELECT 1 FROM _e85_history h WHERE h.name = case_name AND outcome = expected
        AND (expected_error IS NULL OR error LIKE expected_error)) THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP admission outcome mismatch for %: %', case_name,
            (SELECT jsonb_agg(to_jsonb(h)) FROM _e85_history h WHERE h.name = case_name);
    END IF;
    requests := COALESCE((pg_read_file(current_setting('test.e85_counts'))::jsonb->>case_name)::int, 0);
    IF requests <> (CASE WHEN expected_error IS NULL THEN 1 ELSE 0 END) THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected network dispatch count for %: %', case_name, requests;
    END IF;
    IF expected_error IS NULL THEN
        SELECT s INTO status FROM dblink('e85source', format(
            'SELECT df.await_instance(%L, 30)', (SELECT id FROM _e85_cases WHERE name = case_name))) AS source(s text);
        SELECT status_code INTO code FROM dblink('e85source', format(
            'SELECT (df.result(%L)::jsonb->>''status'')::int',
            (SELECT id FROM _e85_cases WHERE name = case_name))) AS source(status_code int);
        IF status IS DISTINCT FROM 'completed' OR code IS DISTINCT FROM 204 THEN
            RAISE EXCEPTION 'TEST FAILED: valid origin did not reach its credential oracle';
        END IF;
    END IF;
    IF df.await_instance((SELECT control_id FROM _e85_cases WHERE name = case_name), 30) <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: control peer failed';
    END IF;
END $$;

-- Revocation after the first privilege check must be enforced for typed HTTP
-- and for raw multipart requests that need a named secret catalog.
SELECT pg_temp.e85_start('revoked-http', false);
SELECT dblink_exec('e85source',
    'REVOKE EXECUTE ON FUNCTION df.http(df.http_endpoint,text,text,jsonb,integer) FROM df_e2e_user');
SELECT pg_temp.e85_finish('revoked-http', '%EXECUTE privilege%');
SELECT pg_temp.e85_setup();
SELECT pg_temp.e85_start('revoked-multipart', true);
SELECT dblink_exec('e85source',
    'REVOKE EXECUTE ON FUNCTION df.http_multipart(text,text,jsonb,jsonb,integer) FROM df_e2e_user');
SELECT pg_temp.e85_finish('revoked-multipart', '%EXECUTE privilege%');
SELECT pg_temp.e85_setup();

-- An idle metadata connection is no longer an installation-lifetime guard.
-- Losing it can reconnect only to the exact original installation.
SELECT pg_temp.e85_start('reconnected', false);
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '_e85_origin'
    AND application_name = 'pg_durable:worker:management' AND state = 'idle' AND query LIKE 'ROLLBACK%';
SELECT pg_temp.e85_finish('reconnected');

SELECT pg_temp.e85_start('same-oid-replacement', true);
SELECT dblink_exec('e85source', 'DROP EXTENSION pg_durable CASCADE');
SELECT pg_temp.e85_setup();
SELECT pg_temp.e85_finish('same-oid-replacement', '%Endpoint origin fence unavailable%');

SELECT pg_temp.e85_start('force-replacement', false);
SELECT dblink_disconnect('e85source');
DROP DATABASE _e85_origin WITH (FORCE);
CREATE DATABASE _e85_origin;
SELECT dblink_connect('e85source', format(
    'host=localhost port=%s dbname=_e85_origin user=postgres', current_setting('port')));
SELECT pg_temp.e85_setup();
SELECT pg_temp.e85_finish('force-replacement', '%Endpoint origin fence unavailable%');
SELECT pg_temp.e85_start('fresh-peer', true);
SELECT pg_temp.e85_finish('fresh-peer');

SELECT dblink_disconnect('e85source');
SELECT dblink_disconnect('e85gate');
DROP DATABASE _e85_origin WITH (FORCE);
DROP DATABASE _e85_target WITH (FORCE);
BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT control_id FROM _e85_cases);
DELETE FROM df.instances WHERE id IN (SELECT control_id FROM _e85_cases);
COMMIT;
DROP VIEW _e85_history;
DROP TABLE _e85_cases;
DROP FUNCTION pg_temp.e85_setup(), pg_temp.e85_start(text, bool), pg_temp.e85_finish(text, text),
    pg_temp.e85_wait(text, text);
SELECT 'TEST PASSED: HTTP admission revalidates source identity and privileges after catalog waits' AS result;
