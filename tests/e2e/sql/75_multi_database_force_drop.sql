CREATE EXTENSION IF NOT EXISTS dblink;

DO $$
BEGIN
    IF current_database() IS DISTINCT FROM df.target_database() OR
        current_setting('server_version_num')::int < 170000 OR
        current_setting('pg_durable.max_user_connections')::int <> 1 OR
        current_setting('pg_durable.execution_acquire_timeout')::int <> 30 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: run in the PG17+ control database, force-drop phase (1 slot, 30s admission)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user'
        AND rolcanlogin AND NOT rolsuper AND NOT rolbypassrls) THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: df_e2e_user must be a non-superuser login without BYPASSRLS';
    END IF;
END $$;

DROP DATABASE IF EXISTS _e2e75_origin WITH (FORCE);
CREATE DATABASE _e2e75_origin;
GRANT CONNECT ON DATABASE _e2e75_origin TO df_e2e_user;

DROP TABLE IF EXISTS public.e2e75_effects;
CREATE TABLE public.e2e75_effects (
    marker TEXT PRIMARY KEY,
    database_name TEXT NOT NULL DEFAULT current_database(),
    role_name TEXT NOT NULL DEFAULT current_user
);
GRANT SELECT, INSERT ON public.e2e75_effects TO df_e2e_user;
CREATE TEMP TABLE _e2e75_control (local_id TEXT PRIMARY KEY, marker TEXT NOT NULL);
GRANT SELECT, INSERT ON _e2e75_control TO df_e2e_user;
CREATE TEMP TABLE _e2e75_unfenced (local_id TEXT PRIMARY KEY);
GRANT SELECT, INSERT ON _e2e75_unfenced TO df_e2e_user;
CREATE TEMP TABLE _e2e75_old (
    local_id TEXT NOT NULL,
    engine_id TEXT NOT NULL,
    database_oid OID NOT NULL,
    installation_id UUID NOT NULL,
    submitted_at TIMESTAMPTZ NOT NULL,
    guard_pid INT,
    released_at TIMESTAMPTZ
);
CREATE TEMP TABLE _e2e75_relations (relation_id OID PRIMARY KEY);
CREATE TEMP TABLE _e2e75_epoch AS SELECT epoch_id FROM df._worker_epoch;

CREATE FUNCTION pg_temp.e2e75_wait(check_sql TEXT, assertion TEXT,
    deadline TIMESTAMPTZ DEFAULT clock_timestamp() + interval '10 seconds')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    satisfied BOOLEAN;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE check_sql INTO satisfied;
        IF clock_timestamp() >= deadline THEN
            RAISE NOTICE 'Activity at deadline: %', (SELECT jsonb_agg(to_jsonb(activity)) FROM (
                SELECT pid, datname, usename, application_name, state, wait_event_type,
                    wait_event, pg_blocking_pids(pid) AS blockers, query
                FROM pg_stat_activity WHERE pid <> pg_backend_pid()
            ) AS activity);
            RAISE NOTICE 'Locks at deadline: %', (SELECT jsonb_agg(to_jsonb(locks)) FROM (
                SELECT pid, locktype, database, relation, mode, granted, classid, objid
                FROM pg_locks WHERE pid IN (SELECT pid FROM pg_stat_activity
                    WHERE application_name LIKE 'pg_durable:%' OR application_name LIKE 'e2e75%')
            ) AS locks);
            RAISE EXCEPTION 'TEST FAILED [%]: deadline exceeded', assertion;
        END IF;
        IF satisfied IS TRUE THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;

DO $$
BEGIN
    PERFORM dblink_connect('e2e75_blocker', format(
        'host=localhost port=%s dbname=%L user=postgres application_name=e2e75_blocker options=%L',
        current_setting('port'), current_database(),
        '-c idle_in_transaction_session_timeout=0 -c transaction_timeout=0'));
    PERFORM dblink_connect('e2e75_origin', format(
        'host=localhost port=%s dbname=_e2e75_origin user=postgres application_name=e2e75_origin',
        current_setting('port')));
END $$;
SELECT dblink_exec('e2e75_origin', $remote$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    CREATE TABLE public.e2e75_effects (
        marker TEXT PRIMARY KEY,
        database_name TEXT NOT NULL DEFAULT current_database(),
        role_name TEXT NOT NULL DEFAULT current_user
    );
    GRANT SELECT, INSERT ON public.e2e75_effects TO df_e2e_user;
    SET SESSION AUTHORIZATION df_e2e_user;
$remote$);
INSERT INTO _e2e75_relations SELECT relation_id FROM dblink('e2e75_origin',
    'SELECT unnest(ARRAY[''df._installation''::regclass::oid,
        ''df.instances''::regclass::oid, ''df.nodes''::regclass::oid])') AS remote(relation_id OID);

CREATE TEMP VIEW _e2e75_waiters AS
SELECT activity.pid
FROM pg_stat_activity AS activity JOIN pg_locks AS locks USING (pid)
WHERE activity.datname = current_database()
    AND activity.usename = 'df_e2e_user'
    AND activity.application_name = 'pg_durable:worker:workflow-sql'
    AND activity.state = 'active' AND activity.wait_event_type = 'Lock'
    AND locks.locktype = 'advisory' AND locks.classid = 750075 AND locks.objid = 1
    AND locks.objsubid = 2 AND NOT locks.granted;

CREATE TEMP VIEW _e2e75_guards AS
SELECT activity.pid
FROM pg_stat_activity AS activity
WHERE activity.datid = (SELECT database_oid FROM _e2e75_old)
    AND activity.application_name = 'pg_durable:worker:management'
    AND activity.state = 'idle in transaction'
    AND (SELECT count(DISTINCT locks.relation) FROM pg_locks AS locks
        WHERE locks.pid = activity.pid AND locks.database = activity.datid
            AND locks.relation IN (SELECT relation_id FROM _e2e75_relations)
            AND locks.mode = 'AccessShareLock' AND locks.granted) = 3;

DO $$
BEGIN
    EXECUTE format($view$
        CREATE TEMP VIEW _e2e75_sql_history AS
        SELECT scheduled.instance_id, scheduled.execution_id, scheduled.event_id,
            outcome.event_data::jsonb->>'type' AS outcome_type,
            outcome.event_data::jsonb #>> '{details,Application,message}' AS error_message
        FROM %1$I.history AS scheduled JOIN _e2e75_old AS old
            ON split_part(scheduled.instance_id, '::', 1) = old.engine_id
        LEFT JOIN %1$I.history AS outcome
            ON outcome.instance_id = scheduled.instance_id
            AND outcome.execution_id = scheduled.execution_id
            AND outcome.event_data::jsonb->>'source_event_id' = scheduled.event_id::text
            AND outcome.event_data::jsonb->>'type' IN ('ActivityCompleted', 'ActivityFailed')
        WHERE scheduled.event_data::jsonb->>'type' = 'ActivityScheduled'
            AND scheduled.event_data::jsonb->>'name' = 'pg_durable::activity::execute-sql'
    $view$, df.duroxide_schema());
END $$;

-- One blocker fills the user semaphore but leaves the second activity worker free to route satellite SQL.
SELECT dblink_exec('e2e75_blocker',
    'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(750075, 1); END $hold$');
SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _e2e75_control SELECT df.start(
    'WITH gate AS MATERIALIZED (SELECT pg_advisory_xact_lock(750075, 1))
        INSERT INTO public.e2e75_effects (marker) SELECT ''control-1'' FROM gate',
    'e2e75-control-1'), 'control-1';
RESET SESSION AUTHORIZATION;
SELECT pg_temp.e2e75_wait('SELECT count(*) = 1 FROM _e2e75_waiters', 'control SQL permit occupied');

DO $$
DECLARE
    started_at TIMESTAMPTZ := clock_timestamp();
BEGIN
    INSERT INTO _e2e75_old (local_id, engine_id, database_oid, installation_id, submitted_at)
    SELECT remote.local_id, format('pgdf-%s-%s-%s', remote.database_oid,
        replace(remote.installation_id::text, '-', ''), remote.local_id),
        remote.database_oid, remote.installation_id, started_at
    FROM dblink('e2e75_origin', $remote$
        SELECT df.start('INSERT INTO public.e2e75_effects (marker) VALUES (''old'')', 'e2e75-old'),
            (SELECT oid FROM pg_database WHERE datname = current_database()),
            (SELECT id FROM df._installation WHERE singleton)
    $remote$) AS remote(local_id TEXT, database_oid OID, installation_id UUID);
END $$;
SELECT dblink_disconnect('e2e75_origin');

SELECT pg_temp.e2e75_wait($check$
    SELECT (SELECT count(*) FROM _e2e75_waiters) = 1
        AND (SELECT count(*) FROM _e2e75_guards) = 1
        AND NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e2e75_origin'
            AND application_name = 'pg_durable:worker:workflow-sql')
        AND (SELECT count(*) = 1 AND bool_and(outcome_type IS NULL) FROM _e2e75_sql_history)
$check$, 'old SQL scheduled with idle origin guard, before its user connection',
    (SELECT submitted_at + interval '10 seconds' FROM _e2e75_old));
UPDATE _e2e75_old SET guard_pid = (SELECT pid FROM _e2e75_guards);

-- Explicit cross-database control work retains the legacy name-only execution path.
SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _e2e75_unfenced SELECT df.start(
    'INSERT INTO public.e2e75_effects (marker) VALUES (''unfenced-old'')',
    'e2e75-unfenced-old', database => '_e2e75_origin');
RESET SESSION AUTHORIZATION;

-- FORCE kills the already-acquired guard; the next user connection resolves the reused name.
DROP DATABASE _e2e75_origin WITH (FORCE);
DO $$
BEGIN
    PERFORM pg_stat_clear_snapshot();
    IF EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = (SELECT guard_pid FROM _e2e75_old)) OR
        EXISTS (SELECT 1 FROM pg_database WHERE oid = (SELECT database_oid FROM _e2e75_old)) THEN
        RAISE EXCEPTION 'TEST FAILED [force drop]: old database or guard survived';
    END IF;
END $$;
CREATE DATABASE _e2e75_origin;
GRANT CONNECT ON DATABASE _e2e75_origin TO df_e2e_user;
DO $$
BEGIN
    PERFORM dblink_connect('e2e75_origin', format(
        'host=localhost port=%s dbname=_e2e75_origin user=postgres application_name=e2e75_origin',
        current_setting('port')));
END $$;
SELECT dblink_exec('e2e75_origin', $remote$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    CREATE TABLE public.e2e75_effects (
        marker TEXT PRIMARY KEY,
        database_name TEXT NOT NULL DEFAULT current_database(),
        role_name TEXT NOT NULL DEFAULT current_user
    );
    GRANT SELECT, INSERT ON public.e2e75_effects TO df_e2e_user;
    SET SESSION AUTHORIZATION df_e2e_user;
$remote$);
CREATE TEMP TABLE _e2e75_replacement AS
SELECT * FROM dblink('e2e75_origin', $remote$
    SELECT (SELECT oid FROM pg_database WHERE datname = current_database()),
        (SELECT id FROM df._installation WHERE singleton),
        (SELECT extversion FROM pg_extension WHERE extname = 'pg_durable')
$remote$) AS remote(database_oid OID, installation_id UUID, extension_version TEXT);

DO $$
BEGIN
    PERFORM pg_stat_clear_snapshot();
    IF (SELECT count(*) FROM _e2e75_waiters) <> 1 OR
        EXISTS (SELECT 1 FROM _e2e75_sql_history WHERE outcome_type IS NOT NULL) OR
        EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e2e75_origin'
            AND application_name = 'pg_durable:worker:workflow-sql') THEN
        RAISE EXCEPTION 'TEST FAILED [replacement setup]: user SQL was admitted before blocker release';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM _e2e75_replacement AS replacement CROSS JOIN _e2e75_old AS old
        WHERE replacement.database_oid <> old.database_oid
            AND replacement.installation_id <> old.installation_id
            AND replacement.extension_version = (SELECT extversion FROM pg_extension WHERE extname = 'pg_durable')) THEN
        RAISE EXCEPTION 'TEST FAILED [replacement identity]: expected new OID/UUID with current extension version';
    END IF;
END $$;
SELECT dblink_exec('e2e75_blocker', 'COMMIT');
UPDATE _e2e75_old SET released_at = clock_timestamp();
DO $$
BEGIN
    IF (SELECT released_at - submitted_at FROM _e2e75_old) >= interval '25 seconds' THEN
        RAISE EXCEPTION 'TEST FAILED [admission window]: blocker released too late for the 30s SQL deadline';
    END IF;
END $$;
SELECT dblink_disconnect('e2e75_blocker');

-- Inspect execute-sql itself: final status updates retry against the removed origin for ~90s.
SELECT pg_temp.e2e75_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e2e75_sql_history WHERE outcome_type IS NOT NULL)
$check$, 'old execute-sql outcome persisted',
    (SELECT released_at + interval '15 seconds' FROM _e2e75_old));
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM _e2e75_sql_history WHERE outcome_type = 'ActivityFailed'
        AND error_message = 'Origin installation removed or replaced') OR
        EXISTS (SELECT 1 FROM _e2e75_sql_history WHERE outcome_type = 'ActivityCompleted') THEN
        RAISE EXCEPTION 'TEST FAILED [N1 execution fence]: expected execute-sql ActivityFailed for identity replacement, history=%',
            (SELECT jsonb_agg(to_jsonb(history)) FROM _e2e75_sql_history AS history);
    END IF;
END $$;

CREATE TEMP TABLE _e2e75_fresh AS
SELECT * FROM dblink('e2e75_origin', $remote$
    SELECT df.start('INSERT INTO public.e2e75_effects (marker) VALUES (''fresh'')', 'e2e75-fresh')
$remote$) AS remote(local_id TEXT);
DO $$
DECLARE
    final_status TEXT;
    workflow RECORD;
BEGIN
    SELECT remote.status INTO final_status FROM dblink('e2e75_origin', format(
        'SELECT df.await_instance(%L, 30)', (SELECT local_id FROM _e2e75_fresh))) AS remote(status TEXT);
    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [fresh satellite]: status = %', final_status;
    END IF;
    final_status := df.await_instance((SELECT local_id FROM _e2e75_unfenced), 30);
    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [unfenced negative control]: status = %', final_status;
    END IF;
    FOR workflow IN SELECT * FROM _e2e75_control ORDER BY marker LOOP
        final_status := df.await_instance(workflow.local_id, 30);
        IF final_status IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', workflow.marker, final_status;
        END IF;
    END LOOP;
END $$;

SELECT pg_temp.e2e75_wait(format($check$
    SELECT EXISTS (SELECT 1 FROM %I.get_instance_info(%L)
        WHERE lower(status) IN ('completed', 'failed', 'cancelled'))
$check$, df.duroxide_schema(), engine_id), 'retained old engine reaches terminal status',
    released_at + interval '130 seconds') FROM _e2e75_old;
DO $$
DECLARE
    old_status TEXT;
BEGIN
    EXECUTE format('SELECT status FROM %I.get_instance_info($1)', df.duroxide_schema())
        INTO old_status USING (SELECT engine_id FROM _e2e75_old);
    IF lower(old_status) IS DISTINCT FROM 'failed' OR
        NOT EXISTS (SELECT 1 FROM _e2e75_sql_history WHERE outcome_type = 'ActivityFailed'
            AND error_message = 'Origin installation removed or replaced') OR
        EXISTS (SELECT 1 FROM _e2e75_sql_history WHERE outcome_type = 'ActivityCompleted') THEN
        RAISE EXCEPTION 'TEST FAILED [old engine]: expected retained failure and no SQL completion, status=%', old_status;
    END IF;
END $$;

SELECT dblink_exec('e2e75_origin', $remote$
    DO $check$
    BEGIN
        IF (SELECT count(*) FROM public.e2e75_effects) <> 2 OR NOT EXISTS (
            SELECT 1 FROM public.e2e75_effects WHERE marker = 'fresh'
                AND database_name = current_database() AND role_name = 'df_e2e_user') OR NOT EXISTS (
            SELECT 1 FROM public.e2e75_effects WHERE marker = 'unfenced-old'
                AND database_name = current_database() AND role_name = 'df_e2e_user') THEN
            RAISE EXCEPTION 'TEST FAILED [replacement effects]: expected fresh and unfenced-old only; identity-bound old SQL must never write';
        END IF;
    END $check$;
$remote$);
DO $$
BEGIN
    IF (SELECT count(*) FROM public.e2e75_effects) <> 1 OR
        EXISTS (SELECT 1 FROM _e2e75_control AS workflow WHERE NOT EXISTS (
            SELECT 1 FROM public.e2e75_effects AS effects WHERE effects.marker = workflow.marker
                AND effects.database_name = current_database() AND effects.role_name = 'df_e2e_user')) OR
        (SELECT count(*) FROM _e2e75_epoch) <> 1 OR
        (SELECT epoch_id FROM df._worker_epoch) IS DISTINCT FROM (SELECT epoch_id FROM _e2e75_epoch) THEN
        RAISE EXCEPTION 'TEST FAILED [control effects]: expected committed control marker and unchanged runtime epoch';
    END IF;
END $$;

SELECT dblink_disconnect('e2e75_origin');
DROP DATABASE _e2e75_origin WITH (FORCE);
BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (
    SELECT local_id FROM _e2e75_control UNION ALL SELECT local_id FROM _e2e75_unfenced);
DELETE FROM df.instances WHERE id IN (
    SELECT local_id FROM _e2e75_control UNION ALL SELECT local_id FROM _e2e75_unfenced);
COMMIT;
DROP TABLE public.e2e75_effects;
DROP VIEW _e2e75_sql_history, _e2e75_guards, _e2e75_waiters;
DROP TABLE _e2e75_control, _e2e75_unfenced, _e2e75_old, _e2e75_relations, _e2e75_epoch, _e2e75_replacement, _e2e75_fresh;
DROP FUNCTION pg_temp.e2e75_wait(TEXT, TEXT, TIMESTAMPTZ);

SELECT 'TEST PASSED: multi-database force drop execution fence' AS result;