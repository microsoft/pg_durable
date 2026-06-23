-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.wait_for_schedule() computes the next cron tick at *execution time*
--        (issue #130), not at df.start() time.
--
-- Design: two df.wait_for_schedule('* * * * *') in a row. The cron '* * * * *'
--         (via the internal "0 ..." seconds field) fires at second :00 of every
--         minute, so a correct implementation makes BOTH waits land on a minute
--         boundary.
--
--     NEW (execution-time):  the second wait is recomputed after the first one
--                            completes, so it targets the *next* :00 boundary ->
--                            both fires land within a few seconds of :00.
--     OLD (df.start()-time): both nodes bake wait_seconds = (60 - start_second)
--                            at parse time. The first wait fires at :00, but the
--                            second reuses that stale offset starting *from* :00,
--                            firing at second ~= (60 - start_second) -- well off
--                            the boundary.
--
--   Asserting that BOTH fires land within 5s of *successive* minute boundaries
--   (i.e. each near :00 and exactly one minute apart) therefore PASSES on the new
--   implementation and FAILS on the old one.
--
--   Pre-start guard: if df.start() runs within ~5s of a minute boundary, the old
--   implementation's second fire (60 - start_second) would itself be near :00 and
--   spuriously pass. We wait until the start second is in a safe window so the
--   "fails on old" property is deterministic.
--
-- Runtime: up to ~2 minutes (two minute-boundary waits).

DROP TABLE IF EXISTS wait_sched_exec_test;
CREATE TABLE wait_sched_exec_test (id SERIAL, fired_at TIMESTAMPTZ);

-- Keep the start second away from the minute boundary (see header).
DO $$
BEGIN
    WHILE date_part('second', clock_timestamp()) < 5
       OR date_part('second', clock_timestamp()) > 50 LOOP
        PERFORM pg_sleep(0.5);
    END LOOP;
END $$;

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.wait_for_schedule('* * * * *')
        ~> 'INSERT INTO wait_sched_exec_test (fired_at) VALUES (clock_timestamp())'
        ~> df.wait_for_schedule('* * * * *')
        ~> 'INSERT INTO wait_sched_exec_test (fired_at) VALUES (clock_timestamp())',
    'test-wait-schedule-exec-time'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    cnt INT;
    f1 TIMESTAMPTZ;
    f2 TIMESTAMPTZ;
    b1 TIMESTAMPTZ;
    b2 TIMESTAMPTZ;
    off1 NUMERIC;
    off2 NUMERIC;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;

    -- Two minute-boundary waits (up to ~60s each) plus scheduling latency.
    SELECT df.await_instance(inst_id, 180) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;

    SELECT count(*) INTO cnt FROM wait_sched_exec_test;
    IF cnt <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 2 fired rows, got %', cnt;
    END IF;

    SELECT fired_at INTO f1 FROM wait_sched_exec_test ORDER BY id LIMIT 1;
    SELECT fired_at INTO f2 FROM wait_sched_exec_test ORDER BY id DESC LIMIT 1;

    -- Nearest minute boundary to each fire (round to nearest minute: add 30s,
    -- then truncate down). Works whether a fire lands just after :00 or just
    -- before the next :00.
    b1 := date_trunc('minute', f1 + interval '30 seconds');
    b2 := date_trunc('minute', f2 + interval '30 seconds');
    off1 := abs(extract(epoch FROM (f1 - b1)));
    off2 := abs(extract(epoch FROM (f2 - b2)));

    RAISE NOTICE 'fire 1 at % (% s from boundary %)', f1, round(off1, 1), b1;
    RAISE NOTICE 'fire 2 at % (% s from boundary %)', f2, round(off2, 1), b2;

    -- (1) Each wait must fire within 5s of a minute boundary. The new code lands
    -- near :00 for both; the old start-time code fires the second wait at
    -- second ~= (60 - start_second), well outside this window.
    IF off1 > 5 THEN
        RAISE EXCEPTION
            'TEST FAILED: first wait_for_schedule fired % s from the minute boundary, expected '
            'within 5s. Cron wait appears computed at df.start() time, not execution time (#130).',
            round(off1, 1);
    END IF;
    IF off2 > 5 THEN
        RAISE EXCEPTION
            'TEST FAILED: second wait_for_schedule fired % s from the minute boundary, expected '
            'within 5s. Cron wait appears computed at df.start() time, not execution time (#130).',
            round(off2, 1);
    END IF;

    -- (2) The two waits must land on *successive* minute boundaries (60s apart),
    -- confirming the second wait advanced to the next tick rather than repeating
    -- or skipping a boundary.
    IF b2 - b1 <> interval '1 minute' THEN
        RAISE EXCEPTION
            'TEST FAILED: waits fired at boundaries % and %, expected successive minutes (60s '
            'apart).', b1, b2;
    END IF;

    RAISE NOTICE 'TEST PASSED: both waits fired within 5s of successive minute boundaries';
END $$;

DROP TABLE _test_state;
DROP TABLE wait_sched_exec_test;
SELECT 'TEST PASSED' AS result;
