-- Short metadata transactions must not pin DDL across user SQL.
CREATE EXTENSION IF NOT EXISTS dblink;
DO $$ BEGIN
    IF current_setting('server_version_num')::int < 170000
        OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user' AND rolcanlogin
            AND NOT rolsuper AND NOT rolbypassrls) THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires PG17+ and unprivileged df_e2e_user';
    END IF;
END $$;
DROP DATABASE IF EXISTS _e2e74_origin WITH (FORCE);
CREATE DATABASE _e2e74_origin;
CREATE TEMP TABLE _e74_epoch AS SELECT epoch_id FROM df._worker_epoch;
CREATE TEMP TABLE _e74_connections(name text PRIMARY KEY, pid int);
CREATE TEMP TABLE _e74_cases(label text PRIMARY KEY, id text, engine_id text);
CREATE TEMP TABLE _e74_relations(oid oid PRIMARY KEY);
DO $$
DECLARE name text; database_name text;
BEGIN
    FOREACH name IN ARRAY ARRAY['e74admin', 'e74submit', 'e74ddl', 'e74gate', 'e74ready'] LOOP
        database_name := CASE WHEN name IN ('e74gate', 'e74ready') THEN current_database() ELSE '_e2e74_origin' END;
        PERFORM dblink_connect(name, format(
            'host=localhost port=%s dbname=%L user=postgres application_name=%s options=%L',
            current_setting('port'), database_name, name,
            '-c statement_timeout=20000 -c lock_timeout=0 -c idle_in_transaction_session_timeout=0 -c transaction_timeout=0'));
        INSERT INTO _e74_connections SELECT name, pid FROM dblink(name, 'SELECT pg_backend_pid()') AS remote(pid int);
    END LOOP;
    PERFORM dblink_exec('e74admin', $sql$
        CREATE EXTENSION pg_durable;
        DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    $sql$);
    PERFORM dblink_exec('e74submit', 'SET SESSION AUTHORIZATION df_e2e_user');
END $$;
INSERT INTO _e74_relations SELECT oid FROM dblink('e74admin',
    'SELECT unnest(ARRAY[''df._installation''::regclass::oid, ''df.instances''::regclass::oid, ''df.nodes''::regclass::oid])')
    AS remote(oid oid);

CREATE FUNCTION pg_temp.e74_wait(check_sql text, assertion text, seconds int DEFAULT 10)
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
DROP FUNCTION IF EXISTS public.e74_effect(int);
DROP TABLE IF EXISTS public.e74_effects;
CREATE TABLE public.e74_effects(marker int PRIMARY KEY, role_name text DEFAULT current_user);
GRANT INSERT, SELECT ON public.e74_effects TO df_e2e_user;
CREATE FUNCTION public.e74_effect(marker int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(740074, marker);
    INSERT INTO public.e74_effects VALUES (marker, current_user);
    RETURN marker;
END $$;
CREATE FUNCTION pg_temp.e74_start(label text, marker int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _e74_cases SELECT label, id, prefix || id FROM dblink('e74submit', format($sql$
        SELECT df.start(%L, %L, database => %L),
            'pgdf-' || (SELECT oid FROM pg_database WHERE datname = current_database()) ||
            '-' || (SELECT replace(id::text, '-', '') FROM df._installation) || '-'
    $sql$, format('SELECT public.e74_effect(%s)', marker), label, current_database())) AS remote(id text, prefix text);
END $$;
CREATE FUNCTION pg_temp.e74_sql_waiting(marker int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.e74_wait(format($check$
        SELECT EXISTS (SELECT 1 FROM pg_stat_activity a JOIN pg_locks l USING (pid)
            WHERE a.datname = current_database() AND a.usename = 'df_e2e_user'
              AND a.application_name = 'pg_durable:worker:workflow-sql'
              AND l.locktype = 'advisory' AND l.classid = 740074 AND l.objid = %s AND NOT l.granted)
    $check$, marker), 'user SQL reached barrier');
    IF EXISTS (SELECT 1 FROM pg_stat_activity a JOIN pg_locks l USING (pid)
        WHERE a.datname = '_e2e74_origin' AND a.application_name = 'pg_durable:worker:management'
            AND l.relation IN (SELECT oid FROM _e74_relations) AND l.granted) THEN
        RAISE EXCEPTION 'TEST FAILED: metadata relation lock retained across remote SQL';
    END IF;
END $$;
CREATE FUNCTION pg_temp.e74_completed(label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.e74_wait(format(
        'SELECT EXISTS (SELECT 1 FROM %I.get_instance_info(%L) WHERE status = ''Completed'')',
        df.duroxide_schema(), (SELECT c.engine_id FROM _e74_cases c WHERE c.label = e74_completed.label)),
        label || ': engine complete', 20);
END $$;
CREATE FUNCTION pg_temp.e74_drain() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.e74_wait($check$
        SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '_e2e74_origin'
            AND application_name = 'pg_durable:worker:management')
    $check$, 'origin metadata connections drained', 15);
END $$;

-- Activity first, DDL second: DDL must finish BEFORE releasing user SQL.
SELECT dblink_exec('e74gate', 'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(740074, 1); END $hold$');
SELECT pg_temp.e74_start('activity-first', 1);
SELECT pg_temp.e74_sql_waiting(1);
SELECT dblink_send_query('e74ddl', 'ALTER TABLE df.nodes ADD COLUMN e74_probe int');
SELECT pg_temp.e74_wait('SELECT dblink_is_busy(''e74ddl'') = 0', 'DDL is not blocked by a separate route guard');
SELECT * FROM dblink_get_result('e74ddl') AS ddl(status text);
SELECT * FROM dblink_get_result('e74ddl') AS ddl(status text);
SELECT dblink_exec('e74gate', 'COMMIT');
SELECT pg_temp.e74_completed('activity-first');
SELECT pg_temp.e74_drain();

-- DDL first, completion metadata second: validation waits on the SAME connection
-- as the eventual update, and continues when the independent DDL owner commits.
SELECT dblink_exec('e74gate', 'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(740074, 2); END $hold$');
SELECT pg_temp.e74_start('ddl-first', 2);
SELECT pg_temp.e74_sql_waiting(2);
SELECT dblink_exec('e74ddl', 'BEGIN; LOCK TABLE df.nodes IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('e74gate', 'COMMIT');
SELECT pg_temp.e74_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.datname = '_e2e74_origin'
        AND a.application_name = 'pg_durable:worker:management'
        AND a.query LIKE 'LOCK TABLE df._installation, df.instances, df.nodes%'
        AND a.wait_event_type = 'Lock'
        AND (SELECT pid FROM _e74_connections WHERE name = 'e74ddl') = ANY(pg_blocking_pids(a.pid)))
$check$, 'metadata validation waits behind DDL');
SELECT dblink_exec('e74ddl', 'COMMIT');
SELECT pg_temp.e74_completed('ddl-first');
SELECT pg_temp.e74_drain();

-- Cancel while completion metadata waits on the caller's row lock. A bounded
-- metadata operation must release its connection without rolling back committed SQL.
SELECT dblink_exec('e74gate', 'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(740074, 3); END $hold$');
SELECT pg_temp.e74_start('cancel-drain', 3);
SELECT pg_temp.e74_sql_waiting(3);
SELECT dblink_exec('e74submit', format(
    'BEGIN; DO $hold$ BEGIN PERFORM id FROM df.instances WHERE id = %L FOR UPDATE; END $hold$',
    id)) FROM _e74_cases WHERE label = 'cancel-drain';
SELECT dblink_exec('e74gate', 'COMMIT');
SELECT pg_temp.e74_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.datname = '_e2e74_origin'
        AND a.application_name = 'pg_durable:worker:management' AND a.query LIKE 'UPDATE df.instances%'
        AND a.wait_event_type = 'Lock'
        AND (SELECT pid FROM _e74_connections WHERE name = 'e74submit') = ANY(pg_blocking_pids(a.pid)))
$check$, 'completion update waits on caller row');
SELECT * FROM dblink('e74submit', format('SELECT df.cancel(%L, ''e74 cancel'')',
    (SELECT id FROM _e74_cases WHERE label = 'cancel-drain'))) AS remote(result text);
SELECT pg_temp.e74_drain();
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.e74_effects WHERE marker = 3)
        OR NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid =
            (SELECT pid FROM _e74_connections WHERE name = 'e74submit') AND state = 'idle in transaction') THEN
        RAISE EXCEPTION 'TEST FAILED: committed effect or caller lock lost during cancellation';
    END IF;
END $$;
SELECT dblink_exec('e74submit', 'COMMIT');
SELECT pg_temp.e74_start('after-cancel', 4);
SELECT pg_temp.e74_completed('after-cancel');
SELECT pg_temp.e74_drain();

-- Ordinary source uninstall does not cancel an already admitted remote SQL
-- statement. It must NOT wait for the arbitrary user operation either.
SELECT dblink_exec('e74gate', 'BEGIN; DO $hold$ BEGIN PERFORM pg_advisory_xact_lock(740074, 5); END $hold$');
SELECT pg_temp.e74_start('ordinary-drop', 5);
SELECT pg_temp.e74_sql_waiting(5);
SELECT dblink_send_query('e74ddl', 'DROP EXTENSION pg_durable CASCADE');
SELECT pg_temp.e74_wait('SELECT dblink_is_busy(''e74ddl'') = 0', 'ordinary DROP does not wait across admitted remote SQL');
SELECT * FROM dblink_get_result('e74ddl') AS ddl(status text);
SELECT * FROM dblink_get_result('e74ddl') AS ddl(status text);
SELECT dblink_exec('e74admin', $sql$
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
$sql$);
SELECT dblink_exec('e74gate', 'COMMIT');
SELECT pg_temp.e74_wait('SELECT EXISTS (SELECT 1 FROM public.e74_effects WHERE marker = 5)',
    'already dispatched remote effect can commit after source DROP');
SELECT dblink_exec('e74admin', $sql$
    DO $check$ BEGIN
        IF EXISTS (SELECT 1 FROM df.instances) OR EXISTS (SELECT 1 FROM df.nodes) THEN
            RAISE EXCEPTION 'TEST FAILED: old work updated replacement metadata';
        END IF;
    END $check$;
$sql$);
SELECT pg_temp.e74_start('replacement', 6);
SELECT pg_temp.e74_completed('replacement');
SELECT pg_temp.e74_drain();

-- Keep the bounded readiness lookup regression from the original guard test.
SELECT dblink_exec('e74ready', format('BEGIN; LOCK TABLE %I._worker_ready IN ACCESS EXCLUSIVE MODE',
    df.duroxide_schema()));
SELECT dblink_send_query('e74submit', format('SELECT count(*)::text FROM df.instance_info(%L)',
    (SELECT id FROM _e74_cases WHERE label = 'replacement')));
SELECT pg_temp.e74_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.datname = current_database()
        AND a.query LIKE '%_worker_ready%' AND a.wait_event_type = 'Lock'
        AND (SELECT pid FROM _e74_connections WHERE name = 'e74ready') = ANY(pg_blocking_pids(a.pid)))
$check$, 'control readiness blocked', 2);
SELECT pg_temp.e74_wait('SELECT dblink_is_busy(''e74submit'') = 0', 'readiness deadline', 4);
DO $$
DECLARE message text; rows int;
BEGIN
    SELECT count(*) INTO rows FROM dblink_get_result('e74submit', false) AS remote(result text);
    message := dblink_error_message('e74submit');
    IF rows <> 0 OR message NOT LIKE '%control installation unavailable%'
        OR message !~ '(lock timeout|statement timeout)' THEN
        RAISE EXCEPTION 'TEST FAILED: bounded readiness error expected, got %', message;
    END IF;
    PERFORM result FROM dblink_get_result('e74submit', false) AS remote(result text);
END $$;
SELECT dblink_exec('e74ready', 'ROLLBACK');
SELECT pg_temp.e74_start('after-readiness', 7);
SELECT pg_temp.e74_completed('after-readiness');
SELECT pg_temp.e74_drain();
DO $$
BEGIN
    IF (SELECT count(*) FROM public.e74_effects) <> 7
        OR EXISTS (SELECT 1 FROM public.e74_effects WHERE role_name <> 'df_e2e_user')
        OR (SELECT epoch_id FROM _e74_epoch) IS DISTINCT FROM (SELECT epoch_id FROM df._worker_epoch) THEN
        RAISE EXCEPTION 'TEST FAILED: missing/incorrect effects or control epoch changed';
    END IF;
END $$;
SELECT dblink_disconnect(name) FROM _e74_connections;
DROP DATABASE _e2e74_origin WITH (FORCE);
DROP FUNCTION public.e74_effect(int);
DROP TABLE public.e74_effects;
DROP TABLE _e74_cases, _e74_connections, _e74_relations, _e74_epoch;
SELECT 'TEST PASSED: short metadata transactions, DDL ordering and admission-based removal' AS result;
