-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Runs with retention_days = 0 and reconcile_interval = 2.
DROP DATABASE IF EXISTS _quota_cleanup_origin;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'quota_cleanup_user') THEN
        DROP OWNED BY quota_cleanup_user;
        DROP ROLE quota_cleanup_user;
    END IF;
END $$;
CREATE ROLE quota_cleanup_user LOGIN;
SELECT df.grant_usage('quota_cleanup_user');
ALTER ROLE quota_cleanup_user SET df.max_concurrent_per_user = 0;
ALTER ROLE quota_cleanup_user SET df.max_instances_per_user = 1;
CREATE DATABASE _quota_cleanup_origin;

DO $$
DECLARE
    connbase TEXT := format('host=localhost port=%s', current_setting('port'));
    connection TEXT;
    local_id TEXT;
    count_rows BIGINT;
BEGIN
    PERFORM dblink_connect('quota_cleanup_control', connbase || format(' dbname=%L user=quota_cleanup_user', current_database()));
    PERFORM dblink_connect('quota_cleanup_origin', connbase || ' dbname=_quota_cleanup_origin user=postgres');
    PERFORM dblink_exec('quota_cleanup_origin', $remote$
        CREATE EXTENSION pg_durable;
        DO $grant$ BEGIN PERFORM df.grant_usage('quota_cleanup_user'); END $grant$;
    $remote$);
    PERFORM dblink_disconnect('quota_cleanup_origin');
    PERFORM dblink_connect('quota_cleanup_origin', connbase || ' dbname=_quota_cleanup_origin user=quota_cleanup_user');
    PERFORM dblink_connect('quota_cleanup_fence', connbase || format(' dbname=%L user=postgres', current_database()));
    PERFORM dblink_exec('quota_cleanup_fence', format(
        'BEGIN; LOCK TABLE %I.instances IN SHARE MODE', df.duroxide_schema()));

    -- One role may submit in both origins, but cannot discard either origin's
    -- accounting by rolling back its local metadata.
    FOREACH connection IN ARRAY ARRAY['quota_cleanup_control', 'quota_cleanup_origin'] LOOP
        PERFORM dblink_exec(connection, 'BEGIN');
        SELECT id INTO local_id FROM dblink(connection,
            'SELECT df.start(''SELECT 1'', ''quota-cleanup-rollback'')') AS started(id TEXT);
        PERFORM dblink_exec(connection, 'ROLLBACK');
        PERFORM dblink_exec(connection, $remote$
            DO $reject$
            BEGIN
                BEGIN
                    PERFORM df.start('SELECT 1');
                    RAISE EXCEPTION 'TEST FAILED: rollback released retained quota';
                EXCEPTION WHEN configuration_limit_exceeded THEN
                    IF SQLERRM NOT LIKE '%has 1 retained instances (limit 1)%' THEN RAISE; END IF;
                END;
            END $reject$;
        $remote$);
    END LOOP;
    PERFORM pg_sleep(3);
    EXECUTE format('SELECT count(*) FROM %I._submissions WHERE submitted_by = $1', df.duroxide_schema())
        INTO count_rows USING 'quota_cleanup_user'::regrole::oid;
    IF count_rows <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: reconciliation removed queued accounting: %', count_rows;
    END IF;
    PERFORM dblink_exec('quota_cleanup_fence', 'COMMIT');

    FOR attempt IN 1..600 LOOP
        EXECUTE format('SELECT count(*) FROM %I._submissions WHERE submitted_by = $1', df.duroxide_schema())
            INTO count_rows USING 'quota_cleanup_user'::regrole::oid;
        EXIT WHEN count_rows = 0;
        PERFORM pg_sleep(0.1);
    END LOOP;
    IF count_rows <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: reconciled rollback accounting still consumes quota: %', count_rows;
    END IF;
    FOREACH connection IN ARRAY ARRAY['quota_cleanup_control', 'quota_cleanup_origin'] LOOP
        SELECT id INTO local_id FROM dblink(connection,
            'SELECT df.start(df.sleep(300), ''quota-cleanup-replacement'', transaction_mode => ''new'')') AS started(id TEXT);
        PERFORM * FROM dblink(connection, format('SELECT df.cancel(%L)', local_id)) AS cancelled(message TEXT);
        PERFORM dblink_disconnect(connection);
    END LOOP;
    PERFORM dblink_disconnect('quota_cleanup_fence');
END $$;
DROP DATABASE _quota_cleanup_origin;
DROP OWNED BY quota_cleanup_user;
DROP ROLE quota_cleanup_user;
SELECT 'TEST PASSED' AS result;
