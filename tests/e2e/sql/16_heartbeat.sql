-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- From: 35_heartbeat_liveness
-- Tests: worker heartbeat liveness (last_seen_at advances over time)
-- Requires superuser: reads internal df._worker_epoch table

DO $$
DECLARE
    ts1 TIMESTAMPTZ;
    ts2 TIMESTAMPTZ;
    attempts INT := 0;
BEGIN
    LOOP
        SELECT last_seen_at INTO ts1 FROM df._worker_epoch LIMIT 1;
        EXIT WHEN ts1 IS NOT NULL OR attempts >= 150;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF ts1 IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: no sentinel row after 15s — worker not running';
    END IF;
    attempts := 0;
    LOOP
        PERFORM pg_sleep(1);
        attempts := attempts + 1;
        SELECT last_seen_at INTO ts2 FROM df._worker_epoch LIMIT 1;
        EXIT WHEN ts2 > ts1 OR attempts >= 15;
    END LOOP;
    IF ts2 <= ts1 THEN
        RAISE EXCEPTION 'TEST FAILED: last_seen_at did not advance after 15s (ts1=%, ts2=%)', ts1, ts2;
    END IF;
    RAISE NOTICE 'PASSED: last_seen_at advanced from % to % after % seconds', ts1, ts2, attempts;
END $$;

SELECT 'TEST PASSED' AS result;
