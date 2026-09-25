-- Kill a metadata session blocked BEFORE validation, replace the installation
-- in the same database, and reuse local IDs. Old work must not modify new rows.
CREATE EXTENSION IF NOT EXISTS dblink;
DO $$ BEGIN
    IF current_setting('pg_durable.max_user_connections')::int <> 1
        OR current_setting('pg_durable.reconcile_interval')::int <> 0 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires force-drop phase';
    END IF;
END $$;
DROP DATABASE IF EXISTS _e84_origin WITH (FORCE);
CREATE DATABASE _e84_origin;
SELECT dblink_connect('e84source', format('host=localhost port=%s dbname=_e84_origin user=postgres', current_setting('port')));
SELECT dblink_connect('e84ddl', format('host=localhost port=%s dbname=_e84_origin user=postgres', current_setting('port')));
SELECT dblink_connect('e84gate', format('host=localhost port=%s dbname=%L user=postgres',
    current_setting('port'), current_database()));
SELECT dblink_exec('e84source', $sql$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    SET SESSION AUTHORIZATION df_e2e_user;
$sql$);
CREATE FUNCTION pg_temp.e84_wait(check_sql text, assertion text, seconds int DEFAULT 10) RETURNS void
LANGUAGE plpgsql AS $$
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
SELECT dblink_exec('e84gate', 'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(840084, 1); END $hold$');
CREATE TEMP TABLE _e84_control(id text);
GRANT SELECT, INSERT ON _e84_control TO df_e2e_user;
SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _e84_control SELECT df.start('SELECT pg_advisory_xact_lock(840084, 1)', 'e84-control');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.e84_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity a JOIN pg_locks l USING(pid)
        WHERE a.application_name = 'pg_durable:worker:workflow-sql'
          AND l.locktype = 'advisory' AND l.classid = 840084 AND l.objid = 1 AND NOT l.granted)
$check$, 'control holds execution permit');
CREATE TEMP TABLE _e84_old AS SELECT * FROM dblink('e84source', format($sql$
    SELECT df.start('SELECT 84 AS value', 'e84-old', database => %L),
        (SELECT oid FROM pg_database WHERE datname = current_database()),
        (SELECT id FROM df._installation)
$sql$, current_database())) AS source(id text, database_oid oid, installation_id uuid);
ALTER TABLE _e84_old ADD COLUMN engine_id text;
UPDATE _e84_old SET engine_id = format('pgdf-%s-%s-%s',
    database_oid, replace(installation_id::text, '-', ''), id);
DO $$ BEGIN
    EXECUTE format($view$
        CREATE TEMP VIEW _e84_history AS
        SELECT h.event_data::jsonb AS event FROM %I.history h
        JOIN _e84_old source ON split_part(h.instance_id, '::', 1) = source.engine_id
    $view$, df.duroxide_schema());
END $$;
SELECT pg_temp.e84_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e84_history WHERE event->>'type' = 'ActivityScheduled'
        AND event->>'name' = 'pg_durable::activity::execute-sql')
        AND EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e84_origin'
            AND application_name = 'pg_durable:worker:management'
            AND state = 'idle' AND query LIKE 'ROLLBACK%')
$check$, 'old SQL is routed and waiting');
CREATE TEMP TABLE _e84_expected(instance jsonb, nodes jsonb);
INSERT INTO _e84_expected SELECT * FROM dblink('e84source', format($sql$
    SELECT (SELECT to_jsonb(i) FROM df.instances i WHERE id = %1$L),
        (SELECT jsonb_agg(to_jsonb(n) ORDER BY id) FROM df.nodes n WHERE instance_id = %1$L)
$sql$, (SELECT id FROM _e84_old))) AS source(instance jsonb, nodes jsonb);
SELECT dblink_exec('e84source', 'RESET SESSION AUTHORIZATION');
SELECT dblink_exec('e84ddl', 'BEGIN; LOCK TABLE df.nodes IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('e84gate', 'COMMIT');
SELECT pg_temp.e84_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e84_origin'
        AND application_name = 'pg_durable:worker:management'
        AND query LIKE 'LOCK TABLE df._installation, df.instances, df.nodes%'
        AND wait_event_type = 'Lock')
$check$, 'completion metadata is blocked before identity validation');
CREATE TEMP TABLE _e84_blocked AS SELECT pid FROM pg_stat_activity
    WHERE datname = '_e84_origin' AND application_name = 'pg_durable:worker:management'
        AND query LIKE 'LOCK TABLE df._installation, df.instances, df.nodes%' AND wait_event_type = 'Lock';
ALTER DATABASE _e84_origin ALLOW_CONNECTIONS false;
SELECT pg_terminate_backend(pid) FROM _e84_blocked;
SELECT pg_temp.e84_wait('SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid IN (SELECT pid FROM _e84_blocked))',
    'only the test metadata session was terminated');
SELECT dblink_exec('e84ddl', 'ROLLBACK');
SELECT dblink_exec('e84source', $sql$
    DROP EXTENSION pg_durable CASCADE;
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
$sql$);
DO $$
DECLARE new_id uuid; new_oid oid; old_instance jsonb; old_nodes jsonb;
BEGIN
    SELECT oid, id INTO new_oid, new_id FROM dblink('e84source',
        'SELECT (SELECT oid FROM pg_database WHERE datname = current_database()), id FROM df._installation')
        AS source(oid oid, id uuid);
    IF new_oid IS DISTINCT FROM (SELECT database_oid FROM _e84_old)
        OR new_id = (SELECT installation_id FROM _e84_old) THEN
        RAISE EXCEPTION 'TEST FAILED: expected same OID and replaced installation UUID';
    END IF;
    SELECT instance, nodes INTO old_instance, old_nodes FROM _e84_expected;
    PERFORM dblink_exec('e84source', format($sql$
        BEGIN;
        SET CONSTRAINTS ALL DEFERRED;
        INSERT INTO df.instances SELECT * FROM jsonb_populate_record(NULL::df.instances, %L::jsonb);
        INSERT INTO df.nodes SELECT * FROM jsonb_populate_recordset(NULL::df.nodes, %L::jsonb);
        COMMIT;
    $sql$, old_instance, old_nodes));
END $$;
ALTER DATABASE _e84_origin ALLOW_CONNECTIONS true;
SELECT pg_temp.e84_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e84_history WHERE event->>'type' = 'ActivityFailed')
$check$, 'old metadata activity explicitly failed');
SELECT pg_temp.e84_wait(format(
    'SELECT EXISTS (SELECT 1 FROM %I.get_instance_info(%L) WHERE lower(status) IN (''completed'', ''failed'', ''cancelled''))',
    df.duroxide_schema(), engine_id), 'old engine reaches terminal outcome', 130) FROM _e84_old;
DO $$
DECLARE actual_instance jsonb; actual_nodes jsonb; fresh_id text; fresh_status text;
BEGIN
    SELECT instance, nodes INTO actual_instance, actual_nodes FROM dblink('e84source', format($sql$
        SELECT (SELECT to_jsonb(i) FROM df.instances i WHERE id = %1$L),
            (SELECT jsonb_agg(to_jsonb(n) ORDER BY id) FROM df.nodes n WHERE instance_id = %1$L)
    $sql$, (SELECT id FROM _e84_old))) AS source(instance jsonb, nodes jsonb);
    IF actual_instance IS DISTINCT FROM (SELECT instance FROM _e84_expected)
        OR actual_nodes IS DISTINCT FROM (SELECT nodes FROM _e84_expected) THEN
        RAISE EXCEPTION 'TEST FAILED: stale metadata activity wrote into the replacement installation';
    END IF;
    PERFORM dblink_exec('e84source', 'SET SESSION AUTHORIZATION df_e2e_user');
    SELECT id INTO fresh_id FROM dblink('e84source',
        'SELECT df.start(''SELECT current_database()::text'', ''e84-fresh'')') AS source(id text);
    SELECT status INTO fresh_status FROM dblink('e84source',
        format('SELECT df.await_instance(%L, 30)', fresh_id)) AS source(status text);
    IF fresh_status IS DISTINCT FROM 'completed'
        OR df.await_instance((SELECT id FROM _e84_control), 30) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: peer or replacement work failed';
    END IF;
END $$;
SELECT dblink_disconnect('e84source');
SELECT dblink_disconnect('e84ddl');
SELECT dblink_disconnect('e84gate');
DROP DATABASE _e84_origin WITH (FORCE);
BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT id FROM _e84_control);
DELETE FROM df.instances WHERE id IN (SELECT id FROM _e84_control);
COMMIT;
DROP VIEW _e84_history;
DROP TABLE _e84_old, _e84_control, _e84_expected, _e84_blocked;
DROP FUNCTION pg_temp.e84_wait(text, text, int);
SELECT 'TEST PASSED: metadata origin identity survives waits, session loss and same-OID replacement' AS result;
