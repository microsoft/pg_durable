-- Test: Worker heartbeat liveness (last_seen_at advances over time)
-- Validates that the background worker updates df._worker_epoch.last_seen_at
-- on each poll tick (~5 seconds).
-- Requires superuser: reads internal df._worker_epoch table.

DO $$
DECLARE
    ts1 TIMESTAMPTZ;
    ts2 TIMESTAMPTZ;
    attempts INT := 0;
BEGIN
    -- Wait for sentinel row to appear (worker may still be initializing)
    LOOP
        SELECT last_seen_at INTO ts1 FROM df._worker_epoch LIMIT 1;
        EXIT WHEN ts1 IS NOT NULL OR attempts >= 150;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF ts1 IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: no sentinel row after 15s — worker not running';
    END IF;

    -- Wait for last_seen_at to advance (poll tick is ~5s, allow up to 15s)
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
