-- A slow-body TLS fixture holds every HTTP permit while SQL and metadata must progress.
\getenv e90_port PGDURABLE_TEST_HTTP_PORT
\getenv e90_counts PGDURABLE_TEST_HTTP_COUNTS
\getenv e90_release PGDURABLE_TEST_HTTP_RELEASE
SELECT set_config('test.e90_url', 'https://127.0.0.1:' || :'e90_port' || '/capacity?case=', false),
    set_config('test.e90_counts', :'e90_counts', false),
    set_config('test.e90_release', :'e90_release', false);
CREATE EXTENSION IF NOT EXISTS dblink;
DROP DATABASE IF EXISTS _e90_origin WITH (FORCE);
CREATE DATABASE _e90_origin;
SELECT dblink_connect('e90origin', format(
    'host=localhost port=%s dbname=_e90_origin user=postgres', current_setting('port')));
SELECT dblink_exec('e90origin', 'CREATE EXTENSION pg_durable');

CREATE TEMP TABLE _e90_cases(case_name text PRIMARY KEY, id text, engine_id text, satellite bool DEFAULT false);
CREATE FUNCTION pg_temp.e90_wait(check_sql text, assertion text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + interval '15 seconds'; satisfied bool;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE check_sql INTO satisfied;
        IF satisfied IS TRUE THEN RETURN; END IF;
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'TEST FAILED [%]: deadline exceeded', assertion;
        END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;

DO $$
DECLARE id text; limit_count int := current_setting('pg_durable.max_http_concurrency')::int;
BEGIN
    IF current_setting('pg_durable.max_activity_concurrency')::int <> 4
        OR limit_count NOT IN (1, 2) THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires four activity slots and one or two HTTP slots';
    END IF;
    FOR i IN 1..limit_count LOOP
        id := df.start(df.http(current_setting('test.e90_url') || 'held-' || i,
            'GET', timeout_seconds => 60), 'e90-held-' || i);
        INSERT INTO _e90_cases VALUES ('held-' || i, id, id, false);
    END LOOP;
END $$;
SELECT pg_temp.e90_wait(
    'SELECT (pg_read_file(current_setting(''test.e90_counts''))::jsonb #>> ''{_capacity,active}'')::int
        = current_setting(''pg_durable.max_http_concurrency'')::int',
    'all HTTP slots occupied by slow response bodies');

DO $$
DECLARE id text; request text; case_name text;
BEGIN
    id := df.start(df.http(current_setting('test.e90_url') || 'queued-short',
        'GET', timeout_seconds => 1), 'e90-queued-short');
    INSERT INTO _e90_cases VALUES ('queued-short', id, id, false);
    id := df.start(df.http_multipart(current_setting('test.e90_url') || 'control-multipart',
        parts => '[{"name":"payload","data_b64":"eA=="}]', timeout_seconds => 60), 'e90-control-multipart');
    INSERT INTO _e90_cases VALUES ('control-multipart', id, id, false);
    id := df.start(df.http(current_setting('test.e90_url') || 'cancelled',
        'GET', timeout_seconds => 60), 'e90-cancelled');
    INSERT INTO _e90_cases VALUES ('cancelled', id, id, false);
    FOREACH case_name IN ARRAY ARRAY['satellite-http', 'satellite-multipart'] LOOP
        request := CASE WHEN case_name = 'satellite-http' THEN
            format('df.http(%L, ''GET'', timeout_seconds => 60)',
                current_setting('test.e90_url') || case_name)
        ELSE format('df.http_multipart(%L, parts => %L::jsonb, timeout_seconds => 60)',
            current_setting('test.e90_url') || case_name, '[{"name":"payload","data_b64":"eA=="}]') END;
        INSERT INTO _e90_cases
        SELECT case_name, started.id, started.prefix || started.id, true
        FROM dblink('e90origin', format($sql$
            SELECT df.start(%s, %L),
                'pgdf-' || (SELECT oid FROM pg_database WHERE datname = current_database()) ||
                '-' || (SELECT replace(id::text, '-', '') FROM df._installation) || '-'
        $sql$, request, 'e90-' || case_name)) AS started(id text, prefix text);
    END LOOP;
END $$;
SELECT pg_temp.e90_wait(format($check$
    SELECT count(DISTINCT h.instance_id) = (SELECT count(*) FROM _e90_cases)
    FROM %I.history h JOIN _e90_cases c ON h.instance_id = c.engine_id
    WHERE h.event_data::jsonb->>'type' = 'ActivityScheduled'
      AND h.event_data::jsonb->>'name' IN (
        'pg_durable::activity::execute-http', 'pg_durable::activity::execute-multipart')
$check$, df.duroxide_schema()), 'every HTTP activity is durably scheduled');

CREATE TEMP TABLE _e90_sql AS SELECT df.start('SELECT 42', 'e90-sql-headroom') AS id;
DO $$ BEGIN
    IF df.await_instance((SELECT id FROM _e90_sql), 10) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: queued HTTP work blocked SQL or status updates';
    END IF;
    PERFORM df.cancel((SELECT id FROM _e90_cases WHERE case_name = 'cancelled'));
    IF df.await_instance((SELECT id FROM _e90_cases WHERE case_name = 'cancelled'), 10)
        IS DISTINCT FROM 'cancelled' THEN
        RAISE EXCEPTION 'TEST FAILED: queued HTTP cancellation did not complete';
    END IF;
END $$;

-- Exceeds the queued request's timeout and allows repeated capacity deferrals.
SELECT pg_sleep(3);
DO $$
DECLARE observed jsonb := pg_read_file(current_setting('test.e90_counts'))::jsonb;
    limit_count int := current_setting('pg_durable.max_http_concurrency')::int;
BEGIN
    IF (observed #>> '{_capacity,active}')::int IS DISTINCT FROM limit_count
        OR (observed #>> '{_capacity,peak}')::int IS DISTINCT FROM limit_count
        OR (SELECT count(*) FROM jsonb_object_keys(observed)) <> limit_count + 1 THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP ceiling or body-lifetime violation: %', observed;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e90_origin'
        AND application_name = 'pg_durable:worker:management') THEN
        RAISE EXCEPTION 'TEST FAILED: deferred HTTP activity retained an origin connection';
    END IF;
    EXECUTE format('COPY (SELECT ''release'') TO %L', current_setting('test.e90_release'));
END $$;

DO $$
DECLARE item record; status text; observed jsonb;
BEGIN
    FOR item IN SELECT * FROM _e90_cases WHERE case_name <> 'cancelled' LOOP
        IF item.satellite THEN
            SELECT s INTO status FROM dblink('e90origin', format(
                'SELECT df.await_instance(%L, 20)', item.id)) AS result(s text);
        ELSE
            status := df.await_instance(item.id, 20);
        END IF;
        IF status IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: % did not complete after admission: %', item.case_name, status;
        END IF;
    END LOOP;
    observed := pg_read_file(current_setting('test.e90_counts'))::jsonb;
    IF (observed #>> '{_capacity,peak}')::int
            IS DISTINCT FROM current_setting('pg_durable.max_http_concurrency')::int
        OR (observed #>> '{_capacity,active}')::int IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected peak or active requests: %', observed;
    END IF;
    FOR item IN SELECT * FROM _e90_cases LOOP
        IF COALESCE((observed->>item.case_name)::int, 0)
            <> (CASE WHEN item.case_name = 'cancelled' THEN 0 ELSE 1 END) THEN
            RAISE EXCEPTION 'TEST FAILED: incorrect request count for %: %', item.case_name, observed;
        END IF;
    END LOOP;
END $$;

CREATE TEMP TABLE _e90_error AS SELECT df.start(
    df.http(current_setting('test.e90_url') || 'error', 'GET'), 'e90-error') AS id;
DO $$ BEGIN
    IF df.await_instance((SELECT id FROM _e90_error), 10) IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected HTTP server error';
    END IF;
END $$;
CREATE TEMP TABLE _e90_after_error AS SELECT df.start(
    df.http(current_setting('test.e90_url') || 'after-error', 'GET'), 'e90-after-error') AS id;
DO $$ BEGIN
    IF df.await_instance((SELECT id FROM _e90_after_error), 10) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: failed HTTP activity leaked its permit';
    END IF;
END $$;

SELECT dblink_disconnect('e90origin');
DROP DATABASE _e90_origin WITH (FORCE);
DROP TABLE _e90_cases, _e90_sql, _e90_error, _e90_after_error;
SELECT 'TEST PASSED' AS result;
