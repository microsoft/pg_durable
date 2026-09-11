CREATE EXTENSION IF NOT EXISTS dblink;

DO $$
BEGIN
    IF current_database() IS DISTINCT FROM df.target_database() OR
        current_setting('server_version_num')::int < 170000 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: run guards in the PG17+ control database';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user'
        AND NOT rolsuper AND NOT rolbypassrls) THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: df_e2e_user must not bypass RLS';
    END IF;
END $$;

DROP DATABASE IF EXISTS _e2e74_origin WITH (FORCE);
CREATE DATABASE _e2e74_origin;
GRANT CONNECT ON DATABASE _e2e74_origin TO df_e2e_user;
CREATE TEMP TABLE _e2e74_epoch AS SELECT epoch_id FROM df._worker_epoch;
CREATE TEMP TABLE _e2e74_connections (connection_name TEXT PRIMARY KEY, pid INT);
CREATE TEMP TABLE _e2e74_state (scenario TEXT PRIMARY KEY, local_id TEXT, engine_id TEXT);
CREATE TEMP TABLE _e2e74_relations (relation_id OID PRIMARY KEY);

DO $$
DECLARE
    connection_name TEXT;
    database_name TEXT;
BEGIN
    FOREACH connection_name IN ARRAY ARRAY['e2e74_admin', 'e2e74_submit', 'e2e74_fresh',
        'e2e74_ddl', 'e2e74_gate', 'e2e74_marker', 'e2e74_ready_lock'] LOOP
        database_name := CASE WHEN connection_name IN ('e2e74_marker', 'e2e74_ready_lock')
            THEN current_database() ELSE '_e2e74_origin' END;
        PERFORM dblink_connect(connection_name, format(
            'host=localhost port=%s dbname=%L user=postgres application_name=%s options=%L',
            current_setting('port'), database_name, connection_name,
            '-c statement_timeout=20000 -c lock_timeout=0 -c idle_in_transaction_session_timeout=0 -c transaction_timeout=0'));
        INSERT INTO _e2e74_connections SELECT connection_name, remote.pid
            FROM dblink(connection_name, 'SELECT pg_backend_pid()') AS remote(pid INT);
    END LOOP;
    PERFORM dblink_exec('e2e74_admin', $remote$
        CREATE EXTENSION pg_durable;
        DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    $remote$);
    PERFORM dblink_exec('e2e74_submit', 'SET SESSION AUTHORIZATION df_e2e_user');
    PERFORM dblink_exec('e2e74_fresh', 'SET SESSION AUTHORIZATION df_e2e_user');
END $$;

INSERT INTO _e2e74_relations SELECT relation_id FROM dblink('e2e74_admin',
    'SELECT unnest(ARRAY[''df._installation''::regclass::oid,
        ''df.instances''::regclass::oid, ''df.nodes''::regclass::oid])') AS remote(relation_id OID);

CREATE TEMP VIEW _e2e74_guards AS
SELECT activity.pid, activity.xact_start, activity.state_change
FROM pg_stat_activity AS activity
WHERE activity.datname = '_e2e74_origin'
    AND activity.application_name = 'pg_durable:worker:management'
    AND activity.state = 'idle in transaction'
    AND (SELECT count(DISTINCT locks.relation) FROM pg_locks AS locks
        WHERE locks.pid = activity.pid AND locks.database = activity.datid
            AND locks.relation IN (SELECT relation_id FROM _e2e74_relations)
            AND locks.mode = 'AccessShareLock' AND locks.granted) = 3;

CREATE FUNCTION pg_temp.e2e74_wait(check_sql TEXT, assertion TEXT, seconds INT DEFAULT 10)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    deadline TIMESTAMPTZ := clock_timestamp() + make_interval(secs => seconds);
    satisfied BOOLEAN;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE check_sql INTO satisfied;
        IF satisfied IS TRUE THEN
            RETURN;
        END IF;
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'TEST FAILED [%]: condition not observed within %s', assertion, seconds;
        END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;

DROP FUNCTION IF EXISTS public.e2e74_effect(INT);
DROP TABLE IF EXISTS public.e2e74_effects;
CREATE TABLE public.e2e74_effects (
    marker INT PRIMARY KEY,
    role_name TEXT NOT NULL DEFAULT current_user,
    database_name TEXT NOT NULL DEFAULT current_database()
);
GRANT INSERT, SELECT ON public.e2e74_effects TO df_e2e_user;
CREATE FUNCTION public.e2e74_effect(marker_key INT) RETURNS INT LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(740074, marker_key);
    INSERT INTO public.e2e74_effects (marker) VALUES (marker_key);
    RETURN marker_key;
END $$;

CREATE FUNCTION pg_temp.e2e74_start(scenario_name TEXT, marker_key INT,
    submit_connection TEXT DEFAULT 'e2e74_submit')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _e2e74_state
    SELECT scenario_name, remote.local_id, remote.prefix || remote.local_id
    FROM dblink(submit_connection, format($remote$
        SELECT df.start(%L, %L, database => %L),
            'pgdf-' || (SELECT oid::text FROM pg_database WHERE datname = current_database()) ||
            '-' || (SELECT replace(id::text, '-', '') FROM df._installation) || '-'
    $remote$, format('SELECT public.e2e74_effect(%s)', marker_key),
        'e2e74-' || scenario_name, current_database())) AS remote(local_id TEXT, prefix TEXT);
END $$;

CREATE FUNCTION pg_temp.e2e74_completed(scenario_name TEXT) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    instance_id TEXT := (SELECT local_id FROM _e2e74_state WHERE scenario = scenario_name);
    workflow_engine_id TEXT := (SELECT engine_id FROM _e2e74_state WHERE scenario = scenario_name);
BEGIN
    PERFORM pg_temp.e2e74_wait(format(
        'SELECT EXISTS (SELECT 1 FROM %I.get_instance_info(%L) WHERE status = ''Completed'')',
        df.duroxide_schema(), workflow_engine_id), scenario_name || ': engine completed', 15);
    PERFORM pg_temp.e2e74_wait(format($check$
        SELECT remote.completed FROM dblink('e2e74_admin', %L) AS remote(completed BOOLEAN)
    $check$, format($remote$
        SELECT EXISTS (SELECT 1 FROM df.instance_info(%1$L) WHERE status = 'completed')
            AND EXISTS (SELECT 1 FROM df.instances WHERE id = %1$L AND status = 'completed')
            AND EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = %1$L AND status = 'completed')
    $remote$, instance_id)), scenario_name || ': retained engine and metadata completed', 15);
END $$;

CREATE FUNCTION pg_temp.e2e74_drain() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.e2e74_wait($check$
        SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e2e74_origin'
            AND application_name LIKE 'pg_durable:worker:%')
    $check$, 'origin connections and guard transactions drained', 15);
END $$;

CREATE FUNCTION pg_temp.e2e74_guard_case(scenario_name TEXT, marker_key INT, hold_seconds INT)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    guard_pid INT;
    ddl_pid INT := (SELECT pid FROM _e2e74_connections WHERE connection_name = 'e2e74_ddl');
    deadline TIMESTAMPTZ;
    ddl_result TEXT;
BEGIN
    PERFORM pg_temp.e2e74_drain();
    PERFORM dblink_exec('e2e74_marker', format(
        'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(740074, %s); END $hold$', marker_key));
    PERFORM pg_temp.e2e74_start(scenario_name, marker_key);
    PERFORM pg_temp.e2e74_wait(format($check$
        SELECT EXISTS (SELECT 1 FROM pg_locks AS locks JOIN pg_stat_activity AS activity USING (pid)
            WHERE locks.locktype = 'advisory' AND locks.classid = 740074 AND locks.objid = %s
                AND locks.objsubid = 2 AND NOT locks.granted
                AND activity.datname = current_database() AND activity.usename = 'df_e2e_user')
            AND EXISTS (SELECT 1 FROM _e2e74_guards)
    $check$, marker_key), scenario_name || ': SQL waiting with separate idle metadata guard');
    SELECT pid INTO STRICT guard_pid FROM _e2e74_guards;
    IF dblink_send_query('e2e74_ddl', format(
        'ALTER TABLE df.instances ADD COLUMN e2e74_guard_%s INT', marker_key)) <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED [%]: could not queue DDL', scenario_name;
    END IF;
    PERFORM pg_temp.e2e74_wait(format($check$
        SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = %1$s
            AND locktype = 'relation' AND mode = 'AccessExclusiveLock' AND NOT granted)
            AND %2$s = ANY(pg_blocking_pids(%1$s))
    $check$, ddl_pid, guard_pid), scenario_name || ': DDL queued AFTER guard acquisition');

    deadline := clock_timestamp() + make_interval(secs => hold_seconds);
    LOOP
        PERFORM pg_stat_clear_snapshot();
        IF dblink_is_busy('e2e74_ddl') <> 1 OR
            NOT EXISTS (SELECT 1 FROM _e2e74_guards WHERE pid = guard_pid) OR
            NOT (guard_pid = ANY(pg_blocking_pids(ddl_pid))) OR
            EXISTS (SELECT 1 FROM public.e2e74_effects WHERE marker = marker_key) THEN
            RAISE EXCEPTION 'TEST FAILED [%]: guard lost or DDL/effect ran before SQL release', scenario_name;
        END IF;
        EXIT WHEN clock_timestamp() >= deadline;
        PERFORM pg_sleep(0.025);
    END LOOP;

    PERFORM dblink_exec('e2e74_marker', 'COMMIT');
    PERFORM pg_temp.e2e74_wait('SELECT dblink_is_busy(''e2e74_ddl'') = 0',
        scenario_name || ': queued DDL finishes after SQL release', 8);
    SELECT status INTO ddl_result FROM dblink_get_result('e2e74_ddl') AS remote(status TEXT);
    IF ddl_result IS DISTINCT FROM 'ALTER TABLE' THEN
        RAISE EXCEPTION 'TEST FAILED [%]: DDL result = %', scenario_name, ddl_result;
    END IF;
    PERFORM status FROM dblink_get_result('e2e74_ddl') AS remote(status TEXT);
    PERFORM pg_temp.e2e74_completed(scenario_name);
    IF NOT EXISTS (SELECT 1 FROM public.e2e74_effects WHERE marker = marker_key
        AND role_name = 'df_e2e_user' AND database_name = current_database()) THEN
        RAISE EXCEPTION 'TEST FAILED [%]: committed effect missing or wrong execution identity', scenario_name;
    END IF;
    PERFORM pg_temp.e2e74_drain();
END $$;

-- Guard first, queued ACCESS EXCLUSIVE second, SQL completion last: not DDL-first admission.
SELECT pg_temp.e2e74_guard_case('reverse-order', 1, 0);
SELECT pg_temp.e2e74_start('after-ddl', 11);
SELECT pg_temp.e2e74_completed('after-ddl');
SELECT pg_temp.e2e74_drain();

-- Pause the final status route's second connection AFTER its guard, BEFORE its UPDATE.
-- Login's own transaction releases its locks before the metadata query needs them again.
SELECT dblink_exec('e2e74_gate',
    'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(740074, 74); END $hold$');
SELECT dblink_exec('e2e74_admin', $remote$
    CREATE FUNCTION public.e2e74_second_connection() RETURNS event_trigger LANGUAGE plpgsql AS $gate$
    BEGIN
        IF current_setting('application_name') = 'pg_durable:worker:management' AND
            EXISTS (SELECT 1 FROM pg_stat_activity AS activity JOIN pg_locks AS locks USING (pid)
                WHERE activity.datid = (SELECT oid FROM pg_database WHERE datname = current_database())
                    AND activity.application_name = 'pg_durable:worker:management'
                    AND activity.state = 'idle in transaction' AND activity.pid <> pg_backend_pid()
                    AND locks.relation = 'df.instances'::regclass
                    AND locks.mode = 'AccessShareLock' AND locks.granted) AND
            EXISTS (SELECT 1 FROM df.instances AS instance WHERE instance.label = 'e2e74-reverse-query'
                AND instance.status = 'running'
                AND EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = instance.id)
                AND NOT EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = instance.id
                    AND status IS DISTINCT FROM 'completed')) THEN
            PERFORM pg_advisory_xact_lock(740074, 74);
        END IF;
    END $gate$;
    CREATE EVENT TRIGGER e2e74_second_connection ON login
        EXECUTE FUNCTION public.e2e74_second_connection();
$remote$);
SELECT pg_temp.e2e74_start('reverse-query', 4);
SELECT pg_temp.e2e74_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_locks AS locks JOIN pg_stat_activity AS activity USING (pid)
        WHERE activity.datname = '_e2e74_origin'
            AND activity.application_name = 'pg_durable:worker:management'
            AND locks.locktype = 'advisory' AND locks.classid = 740074 AND locks.objid = 74
            AND locks.objsubid = 2 AND NOT locks.granted)
        AND EXISTS (SELECT 1 FROM _e2e74_guards)
$check$, 'final status route paused before second connection query');
DO $$
DECLARE
    guard_pid INT := (SELECT pid FROM _e2e74_guards);
    second_pid INT := (SELECT locks.pid FROM pg_locks AS locks JOIN pg_stat_activity AS activity USING (pid)
        WHERE activity.datname = '_e2e74_origin' AND locks.locktype = 'advisory'
            AND locks.classid = 740074 AND locks.objid = 74 AND locks.objsubid = 2 AND NOT locks.granted);
    ddl_pid INT := (SELECT pid FROM _e2e74_connections WHERE connection_name = 'e2e74_ddl');
    ddl_result TEXT;
BEGIN
    IF dblink_send_query('e2e74_ddl', 'ALTER TABLE df.instances ADD COLUMN e2e74_second_query INT') <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED [reverse query]: could not queue DDL';
    END IF;
    PERFORM pg_temp.e2e74_wait(format($check$
        SELECT %1$s = ANY(pg_blocking_pids(%2$s)) AND EXISTS (SELECT 1 FROM pg_locks
            WHERE pid = %2$s AND mode = 'AccessExclusiveLock' AND NOT granted)
    $check$, guard_pid, ddl_pid), 'second-query DDL queued behind existing guard');
    PERFORM dblink_exec('e2e74_gate', 'COMMIT');
    PERFORM pg_temp.e2e74_wait(format($check$
        SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = %1$s
            AND query LIKE 'UPDATE df.instances%%' AND wait_event_type = 'Lock')
            AND %2$s = ANY(pg_blocking_pids(%1$s))
            AND EXISTS (SELECT 1 FROM _e2e74_guards WHERE pid = %3$s)
            AND %3$s = ANY(pg_blocking_pids(%2$s))
    $check$, second_pid, ddl_pid, guard_pid), 'observed second UPDATE -> queued DDL -> idle guard', 3);
    PERFORM pg_temp.e2e74_wait('SELECT dblink_is_busy(''e2e74_ddl'') = 0',
        'second query deadline breaks client-side lock cycle', 8);
    SELECT status INTO ddl_result FROM dblink_get_result('e2e74_ddl') AS remote(status TEXT);
    IF ddl_result IS DISTINCT FROM 'ALTER TABLE' THEN
        RAISE EXCEPTION 'TEST FAILED [reverse query]: DDL result = %', ddl_result;
    END IF;
    PERFORM status FROM dblink_get_result('e2e74_ddl') AS remote(status TEXT);
END $$;
SELECT dblink_exec('e2e74_admin',
    'DROP EVENT TRIGGER e2e74_second_connection; DROP FUNCTION public.e2e74_second_connection()');
SELECT pg_temp.e2e74_completed('reverse-query');
SELECT pg_temp.e2e74_drain();

-- Block the completion UPDATE on the second pool connection, then cancel as its row-lock owner.
SELECT dblink_exec('e2e74_marker',
    'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(740074, 2); END $hold$');
SELECT pg_temp.e2e74_start('cancel-drain', 2);
SELECT pg_temp.e2e74_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_locks AS locks JOIN pg_stat_activity AS activity USING (pid)
        WHERE locks.locktype = 'advisory' AND locks.classid = 740074 AND locks.objid = 2
            AND locks.objsubid = 2 AND NOT locks.granted
            AND activity.usename = 'df_e2e_user' AND activity.datname = current_database())
$check$, 'cancellation SQL reached marker');
DO $$
DECLARE
    instance_id TEXT := (SELECT local_id FROM _e2e74_state WHERE scenario = 'cancel-drain');
BEGIN
    PERFORM dblink_exec('e2e74_submit', format($remote$
        BEGIN;
        DO $lock$ BEGIN PERFORM id FROM df.instances WHERE id = %L FOR UPDATE; END $lock$;
    $remote$, instance_id));
END $$;
SELECT dblink_exec('e2e74_marker', 'COMMIT');
SELECT pg_temp.e2e74_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity AS activity
        WHERE activity.datname = '_e2e74_origin'
            AND activity.application_name = 'pg_durable:worker:management'
            AND activity.query LIKE 'UPDATE df.instances%'
            AND activity.wait_event_type = 'Lock'
            AND (SELECT pid FROM _e2e74_connections WHERE connection_name = 'e2e74_submit')
                = ANY(pg_blocking_pids(activity.pid))
            AND EXISTS (SELECT 1 FROM _e2e74_guards WHERE pid <> activity.pid))
$check$, 'status UPDATE blocked on submitting role, separate guard already acquired');

DO $$
DECLARE
    instance_id TEXT := (SELECT local_id FROM _e2e74_state WHERE scenario = 'cancel-drain');
    engine_id TEXT := (SELECT state.engine_id FROM _e2e74_state AS state WHERE scenario = 'cancel-drain');
    cancel_result TEXT;
BEGIN
    SELECT result INTO cancel_result FROM dblink('e2e74_submit', format(
        'SELECT df.cancel(%L, ''e2e74 drain'')', instance_id)) AS remote(result TEXT);
    IF cancel_result IS DISTINCT FROM format('Instance %s cancelled: e2e74 drain', instance_id) THEN
        RAISE EXCEPTION 'TEST FAILED [cancel]: %', cancel_result;
    END IF;
    PERFORM pg_temp.e2e74_wait(format(
        'SELECT EXISTS (SELECT 1 FROM %I.get_instance_info(%L) WHERE status = ''Failed'')',
        df.duroxide_schema(), engine_id), 'cancelled engine retained in Failed state', 15);
END $$;
SELECT pg_temp.e2e74_drain();
SELECT pg_temp.e2e74_start('permits-reusable', 12, 'e2e74_fresh');
SELECT pg_temp.e2e74_completed('permits-reusable');
SELECT pg_temp.e2e74_drain();
DO $$
DECLARE
    submit_pid INT := (SELECT pid FROM _e2e74_connections WHERE connection_name = 'e2e74_submit');
BEGIN
    PERFORM pg_stat_clear_snapshot();
    IF NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = submit_pid AND state = 'idle in transaction') OR
        NOT EXISTS (SELECT 1 FROM pg_locks WHERE pid = submit_pid
            AND locktype = 'transactionid' AND mode = 'ExclusiveLock' AND granted) OR
        NOT EXISTS (SELECT 1 FROM public.e2e74_effects WHERE marker = 2) THEN
        RAISE EXCEPTION 'TEST FAILED [drain]: row-lock transaction ended early or SQL effect missing';
    END IF;
    PERFORM dblink_exec('e2e74_admin', format($remote$
        DO $locked$ BEGIN
            BEGIN
                PERFORM id FROM df.instances WHERE id = %L FOR UPDATE NOWAIT;
                RAISE EXCEPTION 'TEST FAILED [drain]: cancelled instance row lock was released early';
            EXCEPTION WHEN lock_not_available THEN NULL;
            END;
        END $locked$;
    $remote$, (SELECT local_id FROM _e2e74_state WHERE scenario = 'cancel-drain')));
END $$;
SELECT dblink_exec('e2e74_submit', 'COMMIT');
SELECT pg_temp.e2e74_wait(format(
    'SELECT remote.cancelled FROM dblink(''e2e74_admin'', %L) AS remote(cancelled BOOLEAN)',
    format('SELECT df.status(%L) = ''cancelled''', local_id)), 'cancelled metadata remains terminal')
FROM _e2e74_state WHERE scenario = 'cancel-drain';

-- All worker origin connections are fresh; admin sessions override these DB defaults.
-- SQL explicitly targets control, so a user-session timeout cannot impersonate a dead guard.
ALTER DATABASE _e2e74_origin SET idle_in_transaction_session_timeout = '1s';
ALTER DATABASE _e2e74_origin SET transaction_timeout = '2s';
SELECT pg_temp.e2e74_guard_case('guard-timeouts', 3, 3);
SELECT pg_temp.e2e74_start('after-timeouts', 13);
SELECT pg_temp.e2e74_completed('after-timeouts');
SELECT pg_temp.e2e74_drain();

-- Readiness resolution must time out on the control query, before the harness's 20s timeout.
DO $$
DECLARE
    instance_id TEXT := (SELECT local_id FROM _e2e74_state WHERE scenario = 'after-timeouts');
BEGIN
    PERFORM dblink_exec('e2e74_ready_lock', format(
        'BEGIN; LOCK TABLE %I._worker_ready IN ACCESS EXCLUSIVE MODE', df.duroxide_schema()));
    IF dblink_send_query('e2e74_submit', format(
        'SELECT count(*)::text FROM df.instance_info(%L)', instance_id)) <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED [readiness]: could not send management query';
    END IF;
END $$;
SELECT pg_temp.e2e74_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity AS activity
        WHERE activity.datname = current_database() AND activity.query LIKE '%_worker_ready%'
            AND activity.wait_event_type = 'Lock'
            AND (SELECT pid FROM _e2e74_connections WHERE connection_name = 'e2e74_ready_lock')
                = ANY(pg_blocking_pids(activity.pid)))
$check$, 'satellite management blocked on control readiness', 2);
SELECT pg_temp.e2e74_wait('SELECT dblink_is_busy(''e2e74_submit'') = 0',
    'control readiness lookup has a server-side deadline', 4);
DO $$
DECLARE
    error_message TEXT;
    returned_rows INT;
BEGIN
    SELECT count(*) INTO returned_rows FROM dblink_get_result('e2e74_submit', false) AS remote(result TEXT);
    error_message := dblink_error_message('e2e74_submit');
    IF returned_rows <> 0 OR error_message NOT LIKE '%control installation unavailable%' OR
        error_message !~ '(lock timeout|statement timeout)' THEN
        RAISE EXCEPTION 'TEST FAILED [readiness]: expected bounded control error, rows=%, error=%',
            returned_rows, error_message;
    END IF;
    PERFORM result FROM dblink_get_result('e2e74_submit', false) AS remote(result TEXT);
    IF NOT EXISTS (SELECT 1 FROM pg_locks WHERE pid =
        (SELECT pid FROM _e2e74_connections WHERE connection_name = 'e2e74_ready_lock')
        AND mode = 'AccessExclusiveLock' AND granted) THEN
        RAISE EXCEPTION 'TEST FAILED [readiness]: blocker ended before deadline assertion';
    END IF;
END $$;
SELECT dblink_exec('e2e74_ready_lock', 'ROLLBACK');
SELECT pg_temp.e2e74_completed('after-timeouts');
SELECT pg_temp.e2e74_start('after-readiness', 14);
SELECT pg_temp.e2e74_completed('after-readiness');
SELECT pg_temp.e2e74_drain();

DO $$
BEGIN
    IF (SELECT count(*) FROM public.e2e74_effects) <> 8 OR
        EXISTS (SELECT 1 FROM public.e2e74_effects
            WHERE role_name <> 'df_e2e_user' OR database_name <> current_database()) OR
        (SELECT count(*) FROM _e2e74_epoch) <> 1 OR
        (SELECT epoch_id FROM df._worker_epoch) IS DISTINCT FROM (SELECT epoch_id FROM _e2e74_epoch) THEN
        RAISE EXCEPTION 'TEST FAILED [isolation]: missing effects, wrong identity, or control runtime restarted';
    END IF;
END $$;

SELECT dblink_disconnect(connection_name) FROM _e2e74_connections;
DROP DATABASE _e2e74_origin WITH (FORCE);
DROP FUNCTION public.e2e74_effect(INT);
DROP TABLE public.e2e74_effects;
DROP VIEW _e2e74_guards;
DROP TABLE _e2e74_connections, _e2e74_state, _e2e74_relations, _e2e74_epoch;

SELECT 'TEST PASSED: multi-database guards' AS result;