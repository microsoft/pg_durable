CREATE EXTENSION IF NOT EXISTS dblink;
DROP DATABASE IF EXISTS _e87_origin WITH (FORCE);
CREATE DATABASE _e87_origin;
SELECT dblink_connect('e87source', format('host=localhost port=%s dbname=_e87_origin user=postgres', current_setting('port')));
SELECT dblink_connect('e87ddl', format('host=localhost port=%s dbname=_e87_origin user=postgres', current_setting('port')));
SELECT dblink_exec('e87source', 'CREATE EXTENSION pg_durable');
SELECT dblink_exec('e87source', 'BEGIN');
CREATE TEMP TABLE _e87_state AS SELECT * FROM dblink('e87source', $sql$
    SELECT df.start('SELECT 87 AS value', 'e87-retry'),
        'pgdf-' || (SELECT oid FROM pg_database WHERE datname = current_database())
            || '-' || (SELECT replace(id::text, '-', '') FROM df._installation) || '-'
$sql$) AS source(id text, prefix text);
CREATE FUNCTION pg_temp.e87_wait(check_sql text, assertion text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + interval '20 seconds'; ok bool;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE check_sql INTO ok;
        IF ok IS TRUE THEN RETURN; END IF;
        IF clock_timestamp() > deadline THEN RAISE EXCEPTION 'TEST FAILED: %', assertion; END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;
DO $$ BEGIN
    EXECUTE format($view$
        CREATE TEMP VIEW _e87_probe AS
        SELECT h.event_data::jsonb AS event FROM %I.history h
        JOIN _e87_state s ON h.instance_id = s.prefix || s.id
    $view$, df.duroxide_schema());
END $$;
SELECT pg_temp.e87_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e87_probe WHERE event->>'type' = 'ActivityCompleted'
        AND event->>'result' LIKE '%%in_progress%%')
$check$, 'graph probe observes the uncommitted caller');
-- Queue the DDL before releasing the caller's AccessShare lock, then keep the
-- installation locked across a full route admission timeout.
SELECT dblink_send_query('e87ddl', 'BEGIN; LOCK TABLE df._installation IN ACCESS EXCLUSIVE MODE');
SELECT pg_temp.e87_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_locks l JOIN pg_stat_activity a USING(pid)
        WHERE a.datname = '_e87_origin' AND l.mode = 'AccessExclusiveLock' AND NOT l.granted)
$check$, 'installation lock queued');
SELECT dblink_exec('e87source', 'COMMIT');
SELECT pg_temp.e87_wait('SELECT dblink_is_busy(''e87ddl'') = 0', 'DDL owns installation lock');
SELECT * FROM dblink_get_result('e87ddl') AS ddl(status text);
SELECT * FROM dblink_get_result('e87ddl') AS ddl(status text);
SELECT * FROM dblink_get_result('e87ddl') AS ddl(status text);
SELECT pg_temp.e87_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e87_probe WHERE event->>'type' = 'ActivityCompleted'
        AND event->>'result' LIKE '%%retry%%')
        AND NOT EXISTS (SELECT 1 FROM _e87_probe WHERE event->>'type' = 'ActivityFailed')
$check$, 'wrapper returns typed retry rather than terminal activity error');
SELECT dblink_exec('e87ddl', 'ROLLBACK');
DO $$
DECLARE status text; result jsonb;
BEGIN
    SELECT s INTO status FROM dblink('e87source', format('SELECT df.await_instance(%L, 30)',
        (SELECT id FROM _e87_state))) AS source(s text);
    SELECT r INTO result FROM dblink('e87source', format('SELECT df.result(%L)::jsonb',
        (SELECT id FROM _e87_state))) AS source(r jsonb);
    IF status <> 'completed' OR result #>> '{rows,0,value}' <> '87' THEN
        RAISE EXCEPTION 'TEST FAILED: graph did not recover after routing contention: %, %', status, result;
    END IF;
END $$;
-- The same wrapper must not retry a confirmed installation replacement.
DELETE FROM _e87_state;
SELECT dblink_exec('e87source', 'BEGIN');
INSERT INTO _e87_state SELECT * FROM dblink('e87source', $sql$
    SELECT df.start('SELECT 88 AS value', 'e87-replaced'),
        'pgdf-' || (SELECT oid FROM pg_database WHERE datname = current_database())
            || '-' || (SELECT replace(id::text, '-', '') FROM df._installation) || '-'
$sql$) AS source(id text, prefix text);
SELECT pg_temp.e87_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e87_probe WHERE event->>'type' = 'ActivityCompleted'
        AND event->>'result' LIKE '%%in_progress%%')
$check$, 'replacement case observes uncommitted caller');
SELECT dblink_send_query('e87ddl', 'BEGIN; LOCK TABLE df._installation IN ACCESS EXCLUSIVE MODE');
SELECT pg_temp.e87_wait($check$
    SELECT EXISTS (SELECT 1 FROM pg_locks l JOIN pg_stat_activity a USING(pid)
        WHERE a.datname = '_e87_origin' AND l.mode = 'AccessExclusiveLock' AND NOT l.granted)
$check$, 'replacement DDL queued');
SELECT dblink_exec('e87source', 'COMMIT');
SELECT pg_temp.e87_wait('SELECT dblink_is_busy(''e87ddl'') = 0', 'replacement DDL owns lock');
SELECT * FROM dblink_get_result('e87ddl') AS ddl(status text);
SELECT * FROM dblink_get_result('e87ddl') AS ddl(status text);
SELECT * FROM dblink_get_result('e87ddl') AS ddl(status text);
SELECT dblink_exec('e87ddl', 'DROP EXTENSION pg_durable CASCADE; CREATE EXTENSION pg_durable; COMMIT');
SELECT pg_temp.e87_wait($check$
    SELECT EXISTS (SELECT 1 FROM _e87_probe WHERE event->>'type' = 'ActivityFailed'
        AND event #>> '{details,Application,message}' LIKE '%Origin installation removed or replaced%')
$check$, 'confirmed replacement is a permanent activity failure');
SELECT dblink_disconnect('e87source');
SELECT dblink_disconnect('e87ddl');
DROP DATABASE _e87_origin WITH (FORCE);
DROP VIEW _e87_probe;
DROP TABLE _e87_state;
DROP FUNCTION pg_temp.e87_wait(text, text);
SELECT 'TEST PASSED: transaction-aware routing retries transient lock contention' AS result;
