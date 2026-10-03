-- Former user SQL -> queued DDL -> idle guard cycle: DDL must complete before
-- the execution permit is released; arbitrary user SQL can then read metadata.
CREATE EXTENSION IF NOT EXISTS dblink;
DO $$
BEGIN
    IF current_setting('pg_durable.max_user_connections')::int <> 1
        OR current_setting('pg_durable.reconcile_interval')::int <> 0 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires force-drop phase';
    END IF;
END $$;
DROP DATABASE IF EXISTS _e82_origin WITH (FORCE);
CREATE DATABASE _e82_origin;
SELECT dblink_connect('e82source', format(
    'host=localhost port=%s dbname=_e82_origin user=postgres', current_setting('port')));
SELECT dblink_connect('e82ddl', format(
    'host=localhost port=%s dbname=_e82_origin user=postgres', current_setting('port')));
SELECT dblink_connect('e82gate', format(
    'host=localhost port=%s dbname=%L user=postgres', current_setting('port'), current_database()));
SELECT dblink_exec('e82source', $sql$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    SET SESSION AUTHORIZATION df_e2e_user;
$sql$);
SELECT dblink_exec('e82gate',
    'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(820082, 1); END $hold$');
CREATE TEMP TABLE _e82_control(id text);
GRANT SELECT, INSERT ON _e82_control TO df_e2e_user;
SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _e82_control SELECT df.start(
    'SELECT pg_advisory_xact_lock(820082, 1)', 'e82-control');
RESET SESSION AUTHORIZATION;
CREATE FUNCTION pg_temp.e82_wait(check_sql text, assertion text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + interval '10 seconds'; satisfied bool;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE check_sql INTO satisfied;
        IF satisfied IS TRUE THEN RETURN; END IF;
        IF clock_timestamp() >= deadline THEN RAISE EXCEPTION 'TEST SETUP FAILED: %', assertion; END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;
SELECT pg_temp.e82_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity a JOIN pg_locks l USING (pid)
        WHERE a.application_name = 'pg_durable:worker:workflow-sql'
          AND a.datname = current_database() AND l.locktype = 'advisory'
          AND l.classid = 820082 AND l.objid = 1 AND NOT l.granted)
$check$, 'control permit occupied');
CREATE TEMP TABLE _e82_source AS SELECT * FROM dblink('e82source', $sql$
    SELECT df.start('SELECT count(*) FROM df.nodes /* e82 user metadata read */', 'e82-origin'),
        'df.nodes'::regclass::oid,
        (SELECT oid FROM pg_database WHERE datname = current_database()),
        (SELECT id FROM df._installation)
$sql$) AS source(id text, relation_oid oid, database_oid oid, installation_id uuid);
DO $$
BEGIN
    EXECUTE format($view$
        CREATE TEMP VIEW _e82_scheduled AS
        SELECT h.event_id FROM %I.history h JOIN _e82_source source
          ON split_part(h.instance_id, '::', 1) = format('pgdf-%%s-%%s-%%s',
              source.database_oid, replace(source.installation_id::text, '-', ''), source.id)
        WHERE h.event_data::jsonb->>'type' = 'ActivityScheduled'
          AND h.event_data::jsonb->>'name' = 'pg_durable::activity::execute-sql'
    $view$, df.duroxide_schema());
END $$;
CREATE TEMP TABLE _e82_pids(route_pid int, ddl_pid int);
INSERT INTO _e82_pids(ddl_pid) SELECT pid FROM dblink('e82ddl', 'SELECT pg_backend_pid()') AS ddl(pid int);
SELECT pg_temp.e82_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity a
        JOIN _e82_source source ON a.datid = source.database_oid
        WHERE a.application_name = 'pg_durable:worker:management'
          AND a.state = 'idle' AND a.query LIKE 'ROLLBACK%'
          AND NOT EXISTS (SELECT 1 FROM pg_locks l WHERE l.pid = a.pid
              AND l.relation = source.relation_oid AND l.granted))
        AND EXISTS (SELECT 1 FROM _e82_scheduled)
$check$, 'origin validated without retained locks while SQL waits for permit');
UPDATE _e82_pids SET route_pid = (
    SELECT a.pid FROM pg_stat_activity a
    JOIN _e82_source source ON a.datid = source.database_oid
    WHERE a.application_name = 'pg_durable:worker:management'
      AND a.state = 'idle' AND a.query LIKE 'ROLLBACK%');
SELECT dblink_send_query('e82ddl', 'DO $ddl$ BEGIN LOCK TABLE df.nodes IN ACCESS EXCLUSIVE MODE; END $ddl$');
SELECT pg_temp.e82_wait('SELECT dblink_is_busy(''e82ddl'') = 0',
    'DDL finishes while SQL still waits for its execution permit');
SELECT * FROM dblink_get_result('e82ddl') AS ddl(status text);
SELECT * FROM dblink_get_result('e82ddl') AS ddl(status text);
SELECT dblink_exec('e82gate', 'COMMIT');
DO $$
DECLARE status text;
BEGIN
    SELECT s INTO status FROM dblink('e82source', format('SELECT df.await_instance(%L, 30)',
        (SELECT id FROM _e82_source))) AS remote(s text);
    IF status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: user metadata SQL failed after DDL: %', status;
    END IF;
    IF df.await_instance((SELECT id FROM _e82_control), 30) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: control peer failed';
    END IF;
END $$;
SELECT dblink_disconnect('e82source');
SELECT dblink_disconnect('e82ddl');
SELECT dblink_disconnect('e82gate');
DROP DATABASE _e82_origin WITH (FORCE);
BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT id FROM _e82_control);
DELETE FROM df.instances WHERE id IN (SELECT id FROM _e82_control);
COMMIT;
DROP VIEW _e82_scheduled;
DROP TABLE _e82_control, _e82_source, _e82_pids;
DROP FUNCTION pg_temp.e82_wait(text, text);
SELECT 'TEST PASSED: metadata DDL and user SQL have no separate guard dependency' AS result;
