-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: transaction_mode => 'new' launch admission control
-- Requires: pg_durable.max_new_transaction_starts = 2,
--           pg_durable.new_transaction_start_timeout = 2
-- Verifies that concurrent 'new' launches use at most 2 loopback sessions,
-- timed-out callers get an actionable error, and rejected launches leave no df
-- or engine-visible work behind.

DROP TABLE IF EXISTS test_new_txn_launch_log;
CREATE TABLE test_new_txn_launch_log (label TEXT PRIMARY KEY);

CREATE TEMP TABLE _launch_conn (
    connname TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    outcome TEXT,
    detail TEXT,
    instance_id TEXT
);

INSERT INTO _launch_conn (connname, label)
VALUES
    ('new_start_conn_1', 'test-new-start-1'),
    ('new_start_conn_2', 'test-new-start-2'),
    ('new_start_conn_3', 'test-new-start-3'),
    ('new_start_conn_4', 'test-new-start-4');

CREATE TEMP TABLE _dblink_conn AS
SELECT format('host=localhost dbname=postgres port=%s user=postgres', current_setting('port')) AS connstr;

BEGIN;
LOCK TABLE df.instances IN ACCESS EXCLUSIVE MODE;

DO $$
DECLARE
    rec             RECORD;
    connstr         TEXT;
    launch_sessions INT;
    attempts        INT := 0;
BEGIN
    SELECT c.connstr INTO connstr FROM _dblink_conn c;

    FOR rec IN SELECT connname, label FROM _launch_conn ORDER BY connname LOOP
        PERFORM dblink_connect(rec.connname, connstr);
        PERFORM dblink_send_query(
            rec.connname,
            format(
                $sql$
                SELECT df.start(
                    'INSERT INTO test_new_txn_launch_log (label) VALUES (%L)',
                    %L,
                    NULL,
                    'new'
                )
                $sql$,
                rec.label,
                rec.label
            )
        );
    END LOOP;

    LOOP
        SELECT count(*)
        INTO launch_sessions
        FROM pg_stat_activity
        WHERE application_name = 'pg_durable:new-transaction-start'
          AND pid <> pg_backend_pid();

        EXIT WHEN launch_sessions = 2 OR attempts >= 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF launch_sessions <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 2 admitted new-transaction launch sessions, got %', launch_sessions;
    END IF;

    -- Hold the lock past pg_durable.new_transaction_start_timeout so the excess
    -- callers must time out in admission control instead of opening more
    -- loopback sessions.
    PERFORM pg_sleep(3);

    SELECT count(*)
    INTO launch_sessions
    FROM pg_stat_activity
    WHERE application_name = 'pg_durable:new-transaction-start'
      AND pid <> pg_backend_pid();

    IF launch_sessions <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: launch session count grew beyond the configured limit, got %', launch_sessions;
    END IF;

    RAISE NOTICE 'PASSED [admission_limit]: concurrent new-transaction launch sessions capped at %', launch_sessions;
END $$;

COMMIT;

DO $$
DECLARE
    rec             RECORD;
    busy            INT;
    remote_err      TEXT;
    status          TEXT;
    success_count   INT := 0;
    failure_count   INT := 0;
    total_rows      INT;
    launch_sessions INT;
    attempts        INT;
BEGIN
    FOR rec IN SELECT connname, label FROM _launch_conn ORDER BY connname LOOP
        attempts := 0;
        LOOP
            SELECT dblink_is_busy(rec.connname) INTO busy;
            EXIT WHEN busy = 0 OR attempts >= 300;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;

        IF busy <> 0 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: dblink query never became idle', rec.label;
        END IF;

        UPDATE _launch_conn
        SET instance_id = r.instance_id
        FROM dblink_get_result(rec.connname, false) AS r(instance_id TEXT)
        WHERE connname = rec.connname;

        SELECT dblink_error_message(rec.connname) INTO remote_err;

        IF COALESCE(remote_err, 'OK') <> 'OK' THEN
            failure_count := failure_count + 1;
            UPDATE _launch_conn
            SET outcome = 'failure',
                detail = remote_err
            WHERE connname = rec.connname;
        ELSE
            success_count := success_count + 1;
            UPDATE _launch_conn
            SET outcome = 'success',
                detail = instance_id
            WHERE connname = rec.connname;
        END IF;

        PERFORM dblink_disconnect(rec.connname);
    END LOOP;

    IF success_count <> 2 OR failure_count <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 2 successful and 2 rejected launches, got % successful and % rejected',
            success_count, failure_count;
    END IF;

    FOR rec IN SELECT label, detail FROM _launch_conn WHERE outcome = 'failure' LOOP
        IF rec.detail NOT LIKE '%max_new_transaction_starts=2%' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: rejection missing configured limit: %', rec.label, rec.detail;
        END IF;
        IF rec.detail NOT LIKE '%Timed out after 2s waiting for a launch slot%' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: rejection missing wait duration: %', rec.label, rec.detail;
        END IF;
        IF EXISTS (SELECT 1 FROM df.instances WHERE label = rec.label) THEN
            RAISE EXCEPTION 'TEST FAILED [%]: rejected launch left a df.instances row behind', rec.label;
        END IF;
        IF EXISTS (SELECT 1 FROM test_new_txn_launch_log WHERE label = rec.label) THEN
            RAISE EXCEPTION 'TEST FAILED [%]: rejected launch executed work', rec.label;
        END IF;
    END LOOP;

    FOR rec IN SELECT label, instance_id FROM _launch_conn WHERE outcome = 'success' LOOP
        IF rec.instance_id IS NULL OR length(rec.instance_id) <> 8 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected an 8-char instance id, got %',
                rec.label, COALESCE(rec.instance_id, '<null>');
        END IF;

        SELECT df.await_instance(rec.instance_id, 30) INTO status;
        IF status <> 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: admitted launch status = %', rec.label, status;
        END IF;
    END LOOP;

    SELECT count(*)
    INTO launch_sessions
    FROM pg_stat_activity
    WHERE application_name = 'pg_durable:new-transaction-start'
      AND pid <> pg_backend_pid();

    IF launch_sessions <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: expected all launch sessions to exit, still saw %', launch_sessions;
    END IF;

    SELECT count(*) INTO total_rows
    FROM df.instances
    WHERE label LIKE 'test-new-start-%';

    IF total_rows <> success_count THEN
        RAISE EXCEPTION 'TEST FAILED: expected % surviving df.instances rows, found %',
            success_count, total_rows;
    END IF;

    SELECT count(*) INTO total_rows FROM test_new_txn_launch_log;
    IF total_rows <> success_count THEN
        RAISE EXCEPTION 'TEST FAILED: expected % executed rows, found %', success_count, total_rows;
    END IF;

    RAISE NOTICE 'PASSED [rejection_cleanup]: rejected launches left no runnable or orphaned work';
END $$;

DROP TABLE _dblink_conn;
DROP TABLE _launch_conn;
DROP TABLE test_new_txn_launch_log;

SELECT 'TEST PASSED' AS result;
