-- A database owner is not trusted with worker credentials. After an authorized
-- uninstall, old queued work must reject counterfeit views before planning reads.
CREATE EXTENSION IF NOT EXISTS dblink;
DO $$ BEGIN
    IF current_setting('pg_durable.max_user_connections')::int <> 1
        OR current_setting('pg_durable.reconcile_interval')::int <> 0 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires force-drop phase';
    END IF;
END $$;
DROP DATABASE IF EXISTS _e86_origin WITH (FORCE);
CREATE DATABASE _e86_origin OWNER df_e2e_user;
SELECT dblink_connect('e86source', format(
    'host=localhost port=%s dbname=_e86_origin user=postgres', current_setting('port')));
SELECT dblink_connect('e86gate', format(
    'host=localhost port=%s dbname=%L user=postgres', current_setting('port'), current_database()));
SELECT dblink_exec('e86source', $sql$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    SET SESSION AUTHORIZATION df_e2e_user;
$sql$);
CREATE FUNCTION pg_temp.e86_wait(check_sql text, assertion text, seconds int DEFAULT 10)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + make_interval(secs => seconds); satisfied bool;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE check_sql INTO satisfied;
        IF satisfied IS TRUE THEN RETURN; END IF;
        IF clock_timestamp() >= deadline THEN RAISE EXCEPTION 'TEST FAILED [%]: deadline exceeded', assertion; END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;
CREATE TABLE public.e86_effects(marker text PRIMARY KEY);
GRANT SELECT, INSERT ON public.e86_effects TO df_e2e_user;
SELECT dblink_exec('e86gate', 'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(860086, 1); END $hold$');
CREATE TEMP TABLE _e86_control(id text);
GRANT SELECT, INSERT ON _e86_control TO df_e2e_user;
SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _e86_control SELECT df.start('SELECT pg_advisory_xact_lock(860086, 1)', 'e86-control');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.e86_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity a JOIN pg_locks l USING(pid)
        WHERE a.application_name = 'pg_durable:worker:workflow-sql'
          AND l.locktype = 'advisory' AND l.classid = 860086 AND l.objid = 1 AND NOT l.granted)
$check$, 'control occupies execution permit');
CREATE TEMP TABLE _e86_old AS SELECT * FROM dblink('e86source', format($sql$
    SELECT df.start('INSERT INTO public.e86_effects VALUES (''stale'')', 'e86-stale', database => %L),
        (SELECT oid FROM pg_database WHERE datname = current_database()),
        (SELECT id FROM df._installation)
$sql$, current_database())) AS source(id text, database_oid oid, installation_id uuid);
ALTER TABLE _e86_old ADD COLUMN engine_id text;
UPDATE _e86_old SET engine_id = format('pgdf-%s-%s-%s', database_oid, replace(installation_id::text, '-', ''), id);
DO $$ BEGIN
    EXECUTE format($view$
        CREATE TEMP VIEW _e86_history AS SELECT h.event_data::jsonb AS event
        FROM %I.history h JOIN _e86_old source
          ON split_part(h.instance_id, '::', 1) = source.engine_id
    $view$, df.duroxide_schema());
END $$;
SELECT pg_temp.e86_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e86_history WHERE event->>'type' = 'ActivityScheduled'
        AND event->>'name' = 'pg_durable::activity::execute-sql')
        AND EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e86_origin'
            AND application_name = 'pg_durable:worker:management'
            AND state = 'idle' AND query LIKE 'ROLLBACK%')
$check$, 'old source work is routed before uninstall');
SELECT dblink_exec('e86source', $sql$
    RESET SESSION AUTHORIZATION;
    DROP EXTENSION pg_durable CASCADE;
    SET SESSION AUTHORIZATION df_e2e_user;
    CREATE SCHEMA df;
    CREATE FUNCTION public.e86_canary() RETURNS uuid LANGUAGE plpgsql
    IMMUTABLE SECURITY INVOKER AS $fn$
    BEGIN RAISE EXCEPTION 'E86_UNTRUSTED_VIEW_EXECUTED'; END $fn$;
    CREATE VIEW df._installation AS SELECT public.e86_canary() AS id;
    CREATE VIEW df.instances AS SELECT public.e86_canary() AS id;
    CREATE VIEW df.nodes AS SELECT public.e86_canary() AS id;
    DO $positive$
    BEGIN
        BEGIN
            PERFORM id FROM df._installation;
            RAISE EXCEPTION 'TEST FAILED: replacement view canary was not callable';
        EXCEPTION WHEN raise_exception THEN
            IF SQLERRM <> 'E86_UNTRUSTED_VIEW_EXECUTED' THEN RAISE; END IF;
        END;
    END $positive$;
$sql$);
SELECT dblink_exec('e86gate', 'COMMIT');
SELECT pg_temp.e86_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e86_history WHERE event->>'type' = 'ActivityFailed'
        AND event #>> '{details,Application,message}' LIKE '%Origin installation removed or replaced%')
$check$, 'queued SQL rejects untrusted relation without executing it');
SELECT pg_temp.e86_wait(format(
    'SELECT EXISTS (SELECT 1 FROM %I.get_instance_info(%L) WHERE lower(status) = ''failed'')',
    df.duroxide_schema(), engine_id), 'old workflow terminates', 130) FROM _e86_old;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM _e86_history WHERE event::text LIKE '%E86_UNTRUSTED_VIEW_EXECUTED%')
        OR EXISTS (SELECT 1 FROM public.e86_effects) THEN
        RAISE EXCEPTION 'TEST FAILED: worker evaluated a counterfeit view or dispatched stale SQL';
    END IF;
    IF df.await_instance((SELECT id FROM _e86_control), 30) <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: control peer failed';
    END IF;
END $$;
SELECT dblink_exec('e86source', $sql$
    DROP SCHEMA df CASCADE;
    DROP FUNCTION public.e86_canary();
    RESET SESSION AUTHORIZATION;
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    SET SESSION AUTHORIZATION df_e2e_user;
$sql$);
DO $$
DECLARE fresh text; status text;
BEGIN
    SELECT id INTO fresh FROM dblink('e86source',
        'SELECT df.start(''SELECT current_user::text'', ''e86-fresh'')') AS source(id text);
    SELECT s INTO status FROM dblink('e86source',
        format('SELECT df.await_instance(%L, 30)', fresh)) AS source(s text);
    IF status IS DISTINCT FROM 'completed' THEN RAISE EXCEPTION 'TEST FAILED: fresh satellite failed'; END IF;
END $$;
SELECT dblink_disconnect('e86source');
SELECT dblink_disconnect('e86gate');
DROP DATABASE _e86_origin WITH (FORCE);
BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT id FROM _e86_control);
DELETE FROM df.instances WHERE id IN (SELECT id FROM _e86_control);
COMMIT;
DROP TABLE public.e86_effects;
DROP VIEW _e86_history;
DROP TABLE _e86_old, _e86_control;
DROP FUNCTION pg_temp.e86_wait(text, text, int);
SELECT 'TEST PASSED: untrusted replacement views are rejected without evaluation' AS result;
