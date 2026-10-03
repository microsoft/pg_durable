-- A-origin SQL targeting B must not dispatch after A is replaced during admission.
-- B deliberately has no pg_durable installation. Reconciliation is disabled.
\if :{?e79_replace_extension}
\else
\set e79_replace_extension false
\endif
CREATE EXTENSION IF NOT EXISTS dblink;
DO $$
BEGIN
    IF current_database() IS DISTINCT FROM df.target_database()
        OR current_setting('pg_durable.max_user_connections')::int <> 1
        OR current_setting('pg_durable.execution_acquire_timeout')::int <> 30
        OR current_setting('pg_durable.reconcile_interval')::int <> 0 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires the force-drop phase';
    END IF;
END $$;

DROP DATABASE IF EXISTS _e2e79_a WITH (FORCE);
DROP DATABASE IF EXISTS _e2e79_b WITH (FORCE);
CREATE DATABASE _e2e79_a;
CREATE DATABASE _e2e79_b;
GRANT CONNECT ON DATABASE _e2e79_a, _e2e79_b TO df_e2e_user;

SELECT dblink_connect('e79a', format('host=localhost port=%s dbname=_e2e79_a user=postgres',
    current_setting('port')));
SELECT dblink_connect('e79b', format('host=localhost port=%s dbname=_e2e79_b user=postgres',
    current_setting('port')));
SELECT dblink_connect('e79barrier', format('host=localhost port=%s dbname=%L user=postgres',
    current_setting('port'), current_database()));
SELECT dblink_exec('e79a', $sql$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    SET SESSION AUTHORIZATION df_e2e_user;
$sql$);
SELECT dblink_exec('e79b', $sql$
    CREATE TABLE public.e79_effects(marker text PRIMARY KEY);
    GRANT SELECT, INSERT ON public.e79_effects TO df_e2e_user;
$sql$);
SELECT dblink_exec('e79barrier',
    'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(790079, 1); END $hold$');

CREATE TEMP TABLE _e79_control(id text);
GRANT INSERT, SELECT ON _e79_control TO df_e2e_user;
SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _e79_control SELECT df.start(
    'SELECT pg_advisory_xact_lock(790079, 1)', 'e79-control-barrier');
RESET SESSION AUTHORIZATION;
CREATE FUNCTION pg_temp.e79_wait(check_sql text, assertion text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    deadline timestamptz := clock_timestamp() + interval '10 seconds';
    satisfied bool;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE check_sql INTO satisfied;
        IF satisfied IS TRUE THEN RETURN; END IF;
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'TEST FAILED: %', assertion;
        END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;
SELECT pg_temp.e79_wait($check$
    SELECT EXISTS (
        SELECT 1 FROM pg_stat_activity a JOIN pg_locks l USING (pid)
        WHERE a.application_name = 'pg_durable:worker:workflow-sql'
          AND a.datname = current_database() AND a.wait_event_type = 'Lock'
          AND l.locktype = 'advisory' AND l.classid = 790079
          AND l.objid = 1 AND NOT l.granted)
$check$, 'control SQL must occupy the sole execution permit');

CREATE TEMP TABLE _e79_old AS SELECT * FROM dblink('e79a', $sql$
    SELECT df.start('INSERT INTO public.e79_effects VALUES (''stale'')',
        'e79-remote', database => '_e2e79_b'),
        (SELECT oid FROM pg_database WHERE datname = current_database()),
        (SELECT id FROM df._installation),
        'df._installation'::regclass::oid
$sql$) AS source(id text, database_oid oid, installation_id uuid, relation_oid oid);
ALTER TABLE _e79_old ADD COLUMN engine_id text;
ALTER TABLE _e79_old ADD COLUMN route_pid int;
UPDATE _e79_old SET engine_id = format('pgdf-%s-%s-%s',
    database_oid, replace(installation_id::text, '-', ''), id);
DO $$
BEGIN
    EXECUTE format($view$
        CREATE TEMP VIEW _e79_history AS
        SELECT outcome.event_data::jsonb->>'type' AS outcome_type,
            outcome.event_data::jsonb #>> '{details,Application,message}' AS error
        FROM %1$I.history scheduled
        JOIN _e79_old source ON split_part(scheduled.instance_id, '::', 1) = source.engine_id
        LEFT JOIN %1$I.history outcome
          ON outcome.instance_id = scheduled.instance_id
         AND outcome.execution_id = scheduled.execution_id
         AND outcome.event_data::jsonb->>'source_event_id' = scheduled.event_id::text
         AND outcome.event_data::jsonb->>'type' IN ('ActivityCompleted', 'ActivityFailed')
        WHERE scheduled.event_data::jsonb->>'type' = 'ActivityScheduled'
          AND scheduled.event_data::jsonb->>'name' = 'pg_durable::activity::execute-sql'
    $view$, df.duroxide_schema());
END $$;
SELECT pg_temp.e79_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e79_history WHERE outcome_type IS NULL)
        AND EXISTS (
            SELECT 1 FROM pg_stat_activity a
            JOIN _e79_old source ON a.datid = source.database_oid
            WHERE a.application_name = 'pg_durable:worker:management'
              AND a.state = 'idle' AND a.query LIKE 'ROLLBACK%'
              AND NOT EXISTS (SELECT 1 FROM pg_locks l WHERE l.pid = a.pid
                  AND l.relation = source.relation_oid AND l.granted))
        AND NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e2e79_b'
            AND application_name = 'pg_durable:worker:workflow-sql')
$check$, 'A-origin/B-target SQL routed but not admitted');
UPDATE _e79_old SET route_pid = (SELECT pid FROM pg_stat_activity
    WHERE datname = '_e2e79_a' AND application_name = 'pg_durable:worker:management'
        AND state = 'idle' AND query LIKE 'ROLLBACK%');
\if :e79_replace_extension
SELECT dblink_exec('e79a', 'RESET SESSION AUTHORIZATION; DROP EXTENSION pg_durable CASCADE');
\else
SELECT dblink_disconnect('e79a');
DROP DATABASE _e2e79_a WITH (FORCE);
CREATE DATABASE _e2e79_a;
SELECT dblink_connect('e79a', format('host=localhost port=%s dbname=_e2e79_a user=postgres',
    current_setting('port')));
\endif
SELECT dblink_exec('e79a', $sql$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    SET SESSION AUTHORIZATION df_e2e_user;
$sql$);
\if :e79_replace_extension
DO $$
DECLARE oid_now oid; uuid_now uuid;
BEGIN
    SELECT oid, id INTO oid_now, uuid_now FROM dblink('e79a',
        'SELECT (SELECT oid FROM pg_database WHERE datname = current_database()), id FROM df._installation')
        AS source(oid oid, id uuid);
    IF oid_now IS DISTINCT FROM (SELECT database_oid FROM _e79_old)
        OR uuid_now = (SELECT installation_id FROM _e79_old)
        OR NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = (SELECT route_pid FROM _e79_old)) THEN
        RAISE EXCEPTION 'TEST FAILED: expected same database and live source connection but a new installation UUID';
    END IF;
END $$;
\endif
SELECT dblink_exec('e79barrier', 'COMMIT');
SELECT dblink_disconnect('e79barrier');
SELECT pg_temp.e79_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e79_history
        WHERE outcome_type = 'ActivityFailed' AND error LIKE 'Origin admission unavailable:%')
        AND NOT EXISTS (SELECT 1 FROM _e79_history WHERE outcome_type = 'ActivityCompleted')
$check$, 'remote-target activity must explicitly fail on source loss');
\if :e79_replace_extension
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM _e79_history WHERE error LIKE '%Origin installation removed or replaced%') THEN
        RAISE EXCEPTION 'TEST FAILED: live source connection must freshly validate installation UUID';
    END IF;
END $$;
\endif
DO $$
DECLARE
    count_effects bigint;
    fresh_id text;
    fresh_status text;
BEGIN
    SELECT n INTO count_effects FROM dblink('e79b',
        'SELECT count(*) FROM public.e79_effects') AS target(n bigint);
    IF count_effects <> 0 THEN RAISE EXCEPTION 'TEST FAILED: stale source wrote to B'; END IF;
    SELECT id INTO fresh_id FROM dblink('e79a', $sql$
        SELECT df.start('INSERT INTO public.e79_effects VALUES (''fresh'')',
            'e79-replacement', database => '_e2e79_b')
    $sql$) AS source(id text);
    SELECT status INTO fresh_status FROM dblink('e79a',
        format('SELECT df.await_instance(%L, 30)', fresh_id)) AS source(status text);
    IF fresh_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: replacement origin status %', fresh_status;
    END IF;
    IF df.await_instance((SELECT id FROM _e79_control), 30) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: control peer failed';
    END IF;
END $$;
SELECT dblink_exec('e79b', $sql$
    DO $check$ BEGIN
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_durable')
            OR (SELECT count(*) FROM public.e79_effects) <> 1
            OR NOT EXISTS (SELECT 1 FROM public.e79_effects WHERE marker = 'fresh') THEN
            RAISE EXCEPTION 'TEST FAILED: expected only fresh effect in extension-free B';
        END IF;
    END $check$;
$sql$);
SELECT dblink_disconnect('e79a');
SELECT dblink_disconnect('e79b');
DROP DATABASE _e2e79_a WITH (FORCE);
DROP DATABASE _e2e79_b WITH (FORCE);
BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT id FROM _e79_control);
DELETE FROM df.instances WHERE id IN (SELECT id FROM _e79_control);
COMMIT;
DROP VIEW _e79_history;
DROP TABLE _e79_control, _e79_old;
DROP FUNCTION pg_temp.e79_wait(text, text);
SELECT 'TEST PASSED: removed source cannot dispatch queued remote-target SQL' AS result;
