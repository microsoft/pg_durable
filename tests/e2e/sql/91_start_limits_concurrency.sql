-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

DO $$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['start_limits_race', 'start_limits_other'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('DROP OWNED BY %I', role_name);
            EXECUTE format('DROP ROLE %I', role_name);
        END IF;
    END LOOP;
END $$;
CREATE ROLE start_limits_race LOGIN;
CREATE ROLE start_limits_other LOGIN;
SELECT df.grant_usage('start_limits_race');
SELECT df.grant_usage('start_limits_other');
SELECT format('ALTER ROLE start_limits_race IN DATABASE %I SET df.max_concurrent_per_user = 1',
              current_database()) \gexec
SELECT format('ALTER ROLE start_limits_race IN DATABASE %I SET df.max_instances_per_user = 0',
              current_database()) \gexec

CREATE FUNCTION pg_temp.quota_wait_for_lock(waiter INTEGER) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    FOR attempt IN 1..300 LOOP
        IF EXISTS (SELECT 1 FROM pg_locks WHERE pid = waiter AND locktype = 'advisory'
                   AND classid = x'50474451'::int AND objsubid = 2 AND NOT granted) THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    RAISE EXCEPTION 'TEST FAILED: concurrent start never waited for admission';
END $$;

CREATE FUNCTION pg_temp.quota_finish(conn TEXT, rejected BOOLEAN) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    instance TEXT;
    message TEXT;
BEGIN
    FOR attempt IN 1..300 LOOP
        EXIT WHEN dblink_is_busy(conn) = 0;
        PERFORM pg_sleep(0.1);
    END LOOP;
    IF dblink_is_busy(conn) <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: concurrent start never finished';
    END IF;
    SELECT id INTO instance FROM dblink_get_result(conn, false) AS r(id TEXT);
    message := dblink_error_message(conn);
    PERFORM * FROM dblink_get_result(conn, false) AS r(id TEXT);
    IF rejected THEN
        IF message NOT LIKE '%has 1 active instances (limit 1)%' OR instance IS NOT NULL THEN
            RAISE EXCEPTION 'TEST FAILED: concurrent start did not reject: %', message;
        END IF;
    ELSIF message <> 'OK' OR instance IS NULL OR length(instance) <> 8 THEN
        RAISE EXCEPTION 'TEST FAILED: concurrent start did not succeed: %', message;
    END IF;
    RETURN instance;
END $$;

DO $$
DECLARE
    connstr TEXT := format('host=localhost dbname=%L port=%s user=start_limits_race',
                           current_database(), current_setting('port'));
    waiter INTEGER;
    isolation TEXT;
    rollback_command TEXT;
    instance TEXT;
    message TEXT;
BEGIN
    PERFORM dblink_connect('quota_holder', connstr);
    PERFORM dblink_connect('quota_waiter', connstr);
    PERFORM dblink_exec('quota_holder', 'SET statement_timeout = ''15s''');
    PERFORM dblink_exec('quota_waiter', 'SET statement_timeout = ''15s''');
    SELECT pid INTO waiter FROM dblink('quota_waiter', 'SELECT pg_backend_pid()') AS r(pid INTEGER);

    FOREACH isolation IN ARRAY ARRAY['READ COMMITTED', 'REPEATABLE READ', 'SERIALIZABLE'] LOOP
        PERFORM dblink_exec('quota_holder', $sql$
            DO $cancel$ BEGIN
                PERFORM df.cancel(id) FROM df.instances WHERE status IN ('pending', 'running');
            END $cancel$;
        $sql$);
        PERFORM dblink_exec('quota_waiter', 'BEGIN ISOLATION LEVEL ' || isolation);
        -- Establish the waiter's snapshot before the other transaction inserts.
        PERFORM * FROM dblink('quota_waiter', 'SELECT count(*) FROM df.instances') AS r(n BIGINT);
        PERFORM dblink_exec('quota_holder', 'BEGIN');
        PERFORM * FROM dblink('quota_holder',
            $sql$SELECT df.start(df.sleep(300), 'start-limits-holder')$sql$) AS r(id TEXT);
        IF dblink_send_query('quota_waiter',
            $sql$SELECT df.start(df.sleep(300), 'start-limits-waiter')$sql$) <> 1 THEN
            RAISE EXCEPTION 'TEST FAILED: could not send concurrent start';
        END IF;
        PERFORM pg_temp.quota_wait_for_lock(waiter);

        IF isolation = 'READ COMMITTED' THEN
            PERFORM dblink_connect('quota_other', format(
                'host=localhost dbname=%L port=%s user=start_limits_other',
                current_database(), current_setting('port')));
            PERFORM dblink_exec('quota_other', 'SET statement_timeout = ''5s''');
            PERFORM * FROM dblink('quota_other',
                'SELECT df.start(df.sleep(300))') AS r(id TEXT);
            PERFORM dblink_disconnect('quota_other');
        END IF;

        PERFORM dblink_exec('quota_holder', 'COMMIT');
        PERFORM pg_temp.quota_finish('quota_waiter', true);
        PERFORM dblink_exec('quota_waiter', 'ROLLBACK');
        IF (SELECT count(*) FROM df.instances WHERE submitted_by = 'start_limits_race'::regrole
            AND status IN ('pending', 'running')) <> 1 THEN
            RAISE EXCEPTION 'TEST FAILED: concurrent starts exceeded the cap under %', isolation;
        END IF;
    END LOOP;

    FOREACH rollback_command IN ARRAY ARRAY['ROLLBACK', 'ROLLBACK TO SAVEPOINT quota_start'] LOOP
        PERFORM dblink_exec('quota_holder', $sql$
            DO $cancel$ BEGIN
                PERFORM df.cancel(id) FROM df.instances WHERE status IN ('pending', 'running');
            END $cancel$;
        $sql$);
        PERFORM dblink_exec('quota_holder', 'BEGIN');
        PERFORM dblink_exec('quota_holder', 'SAVEPOINT quota_start');
        SELECT id INTO instance FROM dblink('quota_holder',
            'SELECT df.start(df.sleep(300))') AS r(id TEXT);
        IF dblink_send_query('quota_waiter', 'SELECT df.start(df.sleep(300))') <> 1 THEN
            RAISE EXCEPTION 'TEST FAILED: could not send rollback waiter';
        END IF;
        PERFORM pg_temp.quota_wait_for_lock(waiter);
        PERFORM dblink_exec('quota_holder', rollback_command);
        PERFORM pg_temp.quota_finish('quota_waiter', false);
        IF rollback_command <> 'ROLLBACK' THEN
            PERFORM dblink_exec('quota_holder', 'COMMIT');
        END IF;
        IF EXISTS (SELECT 1 FROM df.instances WHERE id = instance) OR
           EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = instance) THEN
            RAISE EXCEPTION 'TEST FAILED: rolled-back start retained metadata';
        END IF;
    END LOOP;

    PERFORM dblink_exec('quota_holder', $sql$
        DO $cancel$ BEGIN
            PERFORM df.cancel(id) FROM df.instances WHERE status IN ('pending', 'running');
        END $cancel$;
    $sql$);
    PERFORM dblink_exec('quota_holder', 'BEGIN');
    PERFORM * FROM dblink('quota_holder', 'SELECT df.start(df.sleep(300))') AS r(id TEXT);
    PERFORM dblink_exec('quota_waiter', 'SET lock_timeout = ''100ms''');
    PERFORM * FROM dblink('quota_waiter', 'SELECT df.start(df.sleep(300))', false) AS r(id TEXT);
    message := dblink_error_message('quota_waiter');
    IF message NOT LIKE '%lock timeout%' THEN
        RAISE EXCEPTION 'TEST FAILED: admission ignored lock_timeout: %', message;
    END IF;
    PERFORM dblink_exec('quota_holder', 'ROLLBACK');
    PERFORM dblink_disconnect('quota_holder');
    PERFORM dblink_disconnect('quota_waiter');
END $$;

SELECT df.cancel(id) FROM df.instances
WHERE submitted_by IN ('start_limits_race'::regrole, 'start_limits_other'::regrole);
DROP FUNCTION pg_temp.quota_wait_for_lock(INTEGER), pg_temp.quota_finish(TEXT, BOOLEAN);
DROP OWNED BY start_limits_race, start_limits_other;
DROP ROLE start_limits_race, start_limits_other;
SELECT 'TEST PASSED' AS result;
