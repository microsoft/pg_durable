-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: transaction_mode => 'new' launch admission control
-- Requires: pg_durable.max_new_transaction_starts = 2,
--           pg_durable.new_transaction_start_timeout = 2
-- Verifies that concurrent 'new' launches use at most 2 loopback sessions,
-- timed-out callers get an actionable error, and rejected launches leave no df
-- or engine-visible work behind.

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
    blocked_launches INT;
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
                    'SELECT 1',
                    %L,
                    NULL,
                    'new'
                )
                $sql$,
                rec.label
            )
        );
    END LOOP;

    LOOP
        SELECT count(*)
        INTO blocked_launches
        FROM pg_locks l
        JOIN pg_catalog.pg_class c
          ON c.oid = l.relation
        JOIN pg_catalog.pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'df'
          AND c.relname = 'instances'
          AND NOT l.granted;

        EXIT WHEN blocked_launches = 2 OR attempts >= 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF blocked_launches <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 2 blocked loopback launch backends on df.instances, got %', blocked_launches;
    END IF;

    -- Hold the lock past pg_durable.new_transaction_start_timeout so the excess
    -- callers must time out in admission control instead of opening more
    -- loopback sessions.
    PERFORM pg_sleep(3);

    SELECT count(*)
    INTO blocked_launches
    FROM pg_locks l
    JOIN pg_catalog.pg_class c
      ON c.oid = l.relation
    JOIN pg_catalog.pg_namespace n
      ON n.oid = c.relnamespace
    WHERE n.nspname = 'df'
      AND c.relname = 'instances'
      AND NOT l.granted;

    IF blocked_launches <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: blocked loopback backend count grew beyond the configured limit, got %', blocked_launches;
    END IF;

    RAISE NOTICE 'PASSED [admission_limit]: blocked loopback launch backends capped at %', blocked_launches;
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
    blocked_launches INT;
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
    INTO blocked_launches
    FROM pg_locks l
    JOIN pg_catalog.pg_class c
      ON c.oid = l.relation
    JOIN pg_catalog.pg_namespace n
      ON n.oid = c.relnamespace
    WHERE n.nspname = 'df'
      AND c.relname = 'instances'
      AND NOT l.granted;

    IF blocked_launches <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: expected no blocked loopback backends after unlock, still saw %', blocked_launches;
    END IF;

    SELECT count(*) INTO total_rows
    FROM df.instances
    WHERE label LIKE 'test-new-start-%';

    IF total_rows <> success_count THEN
        RAISE EXCEPTION 'TEST FAILED: expected % surviving df.instances rows, found %',
            success_count, total_rows;
    END IF;

    RAISE NOTICE 'PASSED [rejection_cleanup]: rejected launches left no runnable or orphaned work';
END $$;

-- A launch that acquires an admission slot and then FAILS inside the loopback
-- session must still release its slot. This exercises the RAII guard's Drop on
-- the error path, which the concurrency assertions above never hit (their
-- rejected callers time out before acquiring a slot, so they hold nothing).
-- Regression guard for a slot leak on the acquired-then-failed path.
DO $$
DECLARE
    held_slots    INT;
    launch_failed BOOLEAN := false;
    recover_id    TEXT;
    status        TEXT;
BEGIN
    -- Target a database that does not exist so the loopback df.start fails only
    -- *after* the outer session has taken an admission slot.
    BEGIN
        PERFORM df.start('SELECT 1', 'test-new-start-fail', 'no_such_db_pg_durable', 'new');
    EXCEPTION WHEN OTHERS THEN
        launch_failed := true;
    END;

    IF NOT launch_failed THEN
        RAISE EXCEPTION 'TEST FAILED: launch against a missing database unexpectedly succeeded';
    END IF;

    -- Admission slots are two-int session advisory locks under class id
    -- 0x50474446 (1346982470). If the guard released the slot on the error path,
    -- none remain held anywhere in the cluster.
    SELECT count(*)
    INTO held_slots
    FROM pg_locks
    WHERE locktype = 'advisory'
      AND classid = 1346982470
      AND objsubid = 2;

    IF held_slots <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: % admission slot(s) leaked after a failed loopback launch', held_slots;
    END IF;

    -- Capacity must be fully restored: a normal 'new' launch still succeeds.
    recover_id := df.start('SELECT 1', 'test-new-start-recover', NULL, 'new');
    SELECT df.await_instance(recover_id, 30) INTO status;
    IF status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: post-failure launch status = %', status;
    END IF;

    RAISE NOTICE 'PASSED [slot_release_on_error]: failed loopback launch released its admission slot';
END $$;

DROP TABLE _dblink_conn;
DROP TABLE _launch_conn;

SELECT 'TEST PASSED' AS result;
