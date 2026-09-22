-- Acceptance gate: administrative SQL must retain autocommit in every route.
CREATE EXTENSION IF NOT EXISTS dblink;
DROP DATABASE IF EXISTS _e81_origin WITH (FORCE);
DROP DATABASE IF EXISTS _e81_target WITH (FORCE);
CREATE DATABASE _e81_origin;
CREATE DATABASE _e81_target;
SELECT dblink_connect('e81origin', format(
    'host=localhost port=%s dbname=_e81_origin user=postgres', current_setting('port')));
SELECT dblink_connect('e81target', format(
    'host=localhost port=%s dbname=_e81_target user=postgres', current_setting('port')));
SELECT dblink_connect('e81control', format(
    'host=localhost port=%s dbname=%L user=postgres', current_setting('port'), current_database()));
SELECT dblink_exec('e81origin', $sql$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
$sql$);
DO $$
DECLARE connection text;
BEGIN
    FOREACH connection IN ARRAY ARRAY['e81origin', 'e81target', 'e81control'] LOOP
        PERFORM dblink_exec(connection, $sql$
            DROP TABLE IF EXISTS public.e81_data;
            CREATE TABLE public.e81_data(value integer);
            ALTER TABLE public.e81_data OWNER TO df_e2e_user;
            GRANT USAGE, CREATE ON SCHEMA public TO df_e2e_user;
            SET SESSION AUTHORIZATION df_e2e_user;
        $sql$);
    END LOOP;
END $$;
CREATE TEMP TABLE _e81_routes(connection text, target text, route text);
INSERT INTO _e81_routes VALUES
    ('e81control', NULL, 'control-default'),
    ('e81origin', NULL, 'satellite-default'),
    ('e81origin', '_e81_origin', 'satellite-explicit-self'),
    ('e81control', '_e81_target', 'control-remote'),
    ('e81origin', '_e81_target', 'satellite-remote');
CREATE TEMP TABLE _e81_cases(connection text, target_connection text, route text,
    kind text, index_name text, id text, status text);
DO $$
DECLARE
    route record;
    kind text;
    statement text;
    instance text;
    n int := 0;
BEGIN
    FOR route IN SELECT * FROM _e81_routes LOOP
        FOREACH kind IN ARRAY ARRAY['vacuum', 'concurrent-index'] LOOP
            n := n + 1;
            statement := CASE WHEN kind = 'vacuum' THEN 'VACUUM public.e81_data'
                ELSE format('CREATE INDEX CONCURRENTLY e81_index_%s ON public.e81_data(value)', n) END;
            SELECT id INTO instance FROM dblink(route.connection, format(
                'SELECT df.start(%L, %L, database => %L)',
                statement, 'e81-' || route.route || '-' || kind, route.target)) AS remote(id text);
            INSERT INTO _e81_cases VALUES (route.connection,
                CASE WHEN route.target = '_e81_target' THEN 'e81target' ELSE route.connection END,
                route.route, kind, format('e81_index_%s', n), instance, NULL);
        END LOOP;
    END LOOP;
END $$;
DO $$
DECLARE
    item record;
    outcome text;
    detail text;
    deadline timestamptz;
    valid bool;
BEGIN
    FOR item IN SELECT * FROM _e81_cases LOOP
        deadline := clock_timestamp() + interval '30 seconds';
        LOOP
            -- Concurrent index creation waits for old snapshots, including the
            -- test's own poll transaction. Never wait inside df.await_instance.
            COMMIT;
            SELECT status INTO outcome FROM dblink(item.connection,
                format('SELECT df.status(%L)', item.id)) AS remote(status text);
            EXIT WHEN outcome IN ('completed', 'failed', 'cancelled')
                OR clock_timestamp() >= deadline;
            COMMIT;
            PERFORM pg_sleep(0.05);
        END LOOP;
        UPDATE _e81_cases SET status = outcome WHERE connection = item.connection AND id = item.id;
        SELECT result INTO detail FROM dblink(item.connection, format(
            'SELECT result::text FROM df.nodes WHERE instance_id = %L AND node_type = ''SQL''',
            item.id)) AS remote(result text);
        RAISE NOTICE 'AUTOCOMMIT route=% kind=% status=% result=%', item.route, item.kind, outcome, detail;
        IF item.kind = 'concurrent-index' AND outcome = 'completed' THEN
            SELECT indisvalid INTO valid FROM dblink(item.target_connection, format(
                'SELECT indisvalid FROM pg_index WHERE indexrelid = %L::regclass',
                'public.' || item.index_name)) AS target(indisvalid bool);
            IF valid IS DISTINCT FROM true THEN
                RAISE EXCEPTION 'TEST FAILED: completed concurrent index is not valid';
            END IF;
        END IF;
    END LOOP;
END $$;
DO $$
DECLARE connection text;
BEGIN
    FOREACH connection IN ARRAY ARRAY['e81origin', 'e81target', 'e81control'] LOOP
        PERFORM dblink_exec(connection, 'RESET SESSION AUTHORIZATION; DROP TABLE public.e81_data');
        PERFORM dblink_disconnect(connection);
    END LOOP;
END $$;
BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT id FROM _e81_cases WHERE connection = 'e81control');
DELETE FROM df.instances WHERE id IN (SELECT id FROM _e81_cases WHERE connection = 'e81control');
COMMIT;
DROP DATABASE _e81_origin WITH (FORCE);
DROP DATABASE _e81_target WITH (FORCE);
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM _e81_cases WHERE status IS DISTINCT FROM 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED: autocommit compatibility is not preserved: %',
            (SELECT jsonb_agg(to_jsonb(c)) FROM _e81_cases c WHERE status IS DISTINCT FROM 'completed');
    END IF;
END $$;
DROP TABLE _e81_cases, _e81_routes;
SELECT 'TEST PASSED: multi-database autocommit matrix' AS result;
