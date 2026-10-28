-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Runs with retention_days = 0 and reconcile_interval = 2.
DROP DATABASE IF EXISTS _quota_metadata_origin;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'quota_metadata_user') THEN
        DROP OWNED BY quota_metadata_user;
        DROP ROLE quota_metadata_user;
    END IF;
END $$;
CREATE ROLE quota_metadata_user LOGIN;
CREATE DATABASE _quota_metadata_origin;

DO $$
DECLARE
    conn TEXT;
    database_name TEXT;
    origin_key TEXT;
    instance TEXT;
    canary TEXT;
    replacement TEXT;
    attempted BOOLEAN;
    present BOOLEAN;
    base_conn TEXT := format('host=localhost port=%s user=postgres', current_setting('port'));
BEGIN
    FOREACH database_name IN ARRAY ARRAY[current_database(), '_quota_metadata_origin'] LOOP
        conn := 'quota_metadata_probe';
        PERFORM dblink_connect(conn, base_conn || format(' dbname=%L', database_name));
        IF database_name <> current_database() THEN
            PERFORM dblink_exec(conn, 'CREATE EXTENSION pg_durable');
        END IF;
        PERFORM dblink_exec(conn, $remote$
            DO $grant$ BEGIN PERFORM df.grant_usage('quota_metadata_user'); END $grant$;
            SET df.max_concurrent_per_user = 1;
            SET df.max_instances_per_user = 0;
            SET lock_timeout = '10s';
            DROP TRIGGER IF EXISTS quota_metadata_block ON df.instances;
            DROP FUNCTION IF EXISTS public.quota_metadata_block_delete();
            DROP SEQUENCE IF EXISTS public.quota_metadata_delete_attempt;
            CREATE SEQUENCE public.quota_metadata_delete_attempt;
            CREATE FUNCTION public.quota_metadata_block_delete() RETURNS trigger
            LANGUAGE plpgsql AS $trigger$
            BEGIN
                PERFORM nextval('public.quota_metadata_delete_attempt');
                RAISE EXCEPTION 'quota test: metadata deletion blocked';
            END $trigger$;
            CREATE TRIGGER quota_metadata_block
                BEFORE DELETE ON df.instances FOR EACH ROW
                WHEN (OLD.label = 'quota-metadata-preserve')
                EXECUTE FUNCTION public.quota_metadata_block_delete();
            SET ROLE quota_metadata_user;
        $remote$);
        SELECT prefix INTO origin_key FROM dblink(conn, $remote$
            SELECT CASE WHEN current_database() = current_setting('pg_durable.database') THEN ''
                        ELSE format('pgdf-%s-%s-',
                            (SELECT oid FROM pg_database WHERE datname = current_database()),
                            replace(id::text, '-', '')) END
            FROM df._installation
        $remote$) AS origin(prefix TEXT);
        SELECT id INTO instance FROM dblink(conn,
            'SELECT df.start(''SELECT 1'', ''quota-metadata-preserve'')') AS started(id TEXT);
        PERFORM dblink_exec(conn, 'RESET ROLE');
        FOR attempt IN 1..600 LOOP
            SELECT is_called INTO attempted FROM dblink(conn,
                'SELECT is_called FROM public.quota_metadata_delete_attempt') AS observed(is_called BOOLEAN);
            EXIT WHEN attempted;
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF NOT attempted THEN
            RAISE EXCEPTION 'TEST FAILED: metadata deletion was not attempted in %', database_name;
        END IF;

        -- Removing a later orphan's ledger entry proves accounting cleanup ran
        -- after the failed metadata deletion, without relying on a fixed sleep.
        PERFORM dblink_exec(conn, 'BEGIN');
        SELECT id INTO canary FROM dblink(conn,
            'SELECT df.start(''SELECT 1'', ''quota-metadata-canary'')') AS started(id TEXT);
        PERFORM dblink_exec(conn, 'ROLLBACK');
        FOR attempt IN 1..600 LOOP
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I._submissions WHERE instance_id = $1)',
                           df.duroxide_schema()) INTO present USING origin_key || canary;
            EXIT WHEN NOT present;
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF present THEN
            RAISE EXCEPTION 'TEST FAILED: accounting cleanup did not process the canary';
        END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.instances WHERE instance_id = $1)',
                       df.duroxide_schema()) INTO present USING origin_key || instance;
        IF present THEN
            RAISE EXCEPTION 'TEST FAILED: engine retirement did not precede failed metadata cleanup';
        END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I._submissions WHERE instance_id = $1)',
                       df.duroxide_schema()) INTO present USING origin_key || instance;
        IF NOT present THEN
            RAISE EXCEPTION 'TEST FAILED: failed metadata cleanup lost trusted retirement accounting';
        END IF;
        SELECT observed.found INTO present FROM dblink(conn, format(
            'SELECT EXISTS (SELECT 1 FROM df.instances WHERE id = %L)', instance)) AS observed(found BOOLEAN);
        IF NOT present THEN
            RAISE EXCEPTION 'TEST FAILED: metadata deletion unexpectedly succeeded';
        END IF;

        PERFORM dblink_exec(conn, 'SET ROLE quota_metadata_user');
        SELECT id INTO replacement FROM dblink(conn,
            'SELECT df.start(df.sleep(300), ''quota-metadata-replacement'')') AS started(id TEXT);
        PERFORM * FROM dblink(conn, format('SELECT df.cancel(%L)', replacement)) AS cancelled(message TEXT);
        PERFORM dblink_exec(conn, $remote$
            RESET ROLE;
            DROP TRIGGER quota_metadata_block ON df.instances;
            DROP FUNCTION public.quota_metadata_block_delete();
            DROP SEQUENCE public.quota_metadata_delete_attempt;
        $remote$);
        FOR attempt IN 1..600 LOOP
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I._submissions WHERE instance_id = $1)',
                           df.duroxide_schema()) INTO present USING origin_key || instance;
            EXIT WHEN NOT present;
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF present THEN
            RAISE EXCEPTION 'TEST FAILED: accounting was not released after metadata cleanup recovered';
        END IF;
        SELECT observed.found INTO present FROM dblink(conn, format(
            'SELECT EXISTS (SELECT 1 FROM df.instances WHERE id = %L)', instance)) AS observed(found BOOLEAN);
        IF present THEN
            RAISE EXCEPTION 'TEST FAILED: accounting was released before metadata removal';
        END IF;
        PERFORM dblink_disconnect(conn);
    END LOOP;
END $$;
DROP DATABASE _quota_metadata_origin;
DROP OWNED BY quota_metadata_user;
DROP ROLE quota_metadata_user;
SELECT 'TEST PASSED' AS result;
