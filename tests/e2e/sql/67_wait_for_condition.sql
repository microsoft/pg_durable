-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: df.wait_for_condition()
-- Verifies that a predicate that is already true fires immediately, that one
-- that becomes true later fires on the interval backstop, that a pg_notify on
-- the declared notify_key beats a long backstop, that a second notification is
-- still delivered after the first one was consumed, that the waiter registry is
-- populated while parked and cleared afterwards, and that a predicate with
-- side effects fails instead of writing.

DROP TABLE IF EXISTS test_cond_gate;
CREATE TABLE test_cond_gate (name TEXT PRIMARY KEY, ready BOOLEAN NOT NULL);
INSERT INTO test_cond_gate VALUES ('already', true), ('later', false), ('notified', false), ('twice', false);

DROP TABLE IF EXISTS test_cond_done;
CREATE TABLE test_cond_done (name TEXT PRIMARY KEY);

CREATE TEMP TABLE _cond_state (name TEXT PRIMARY KEY, instance_id TEXT, elapsed NUMERIC);

-- ---------------------------------------------------------------------------
-- 1. Already true: fires without waiting out the interval.
-- ---------------------------------------------------------------------------
INSERT INTO _cond_state (name, instance_id)
SELECT 'already', df.start(
    df.wait_for_condition(
        'SELECT ready FROM test_cond_gate WHERE name = ''already''',
        '30s'
    ) ~> 'INSERT INTO test_cond_done VALUES (''already'')',
    'test-cond-already'
);

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    started  TIMESTAMPTZ := clock_timestamp();
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_state WHERE name = 'already';
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (already true): status = %', status;
    END IF;

    -- A full interval is 30s; anything under that proves the first evaluation
    -- fired rather than the backstop.
    UPDATE _cond_state
       SET elapsed = extract(epoch FROM clock_timestamp() - started)
     WHERE name = 'already';

    IF (SELECT elapsed FROM _cond_state WHERE name = 'already') > 20 THEN
        RAISE EXCEPTION 'TEST FAILED (already true): waited % seconds, expected immediate',
            (SELECT elapsed FROM _cond_state WHERE name = 'already');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM test_cond_done WHERE name = 'already') THEN
        RAISE EXCEPTION 'TEST FAILED (already true): body did not run';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Becomes true later, no notification: the interval backstop fires it.
-- ---------------------------------------------------------------------------
INSERT INTO _cond_state (name, instance_id)
SELECT 'later', df.start(
    df.wait_for_condition(
        'SELECT ready FROM test_cond_gate WHERE name = ''later''',
        '1s'
    ) ~> 'INSERT INTO test_cond_done VALUES (''later'')',
    'test-cond-later'
);

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_state WHERE name = 'later';

    -- Let it park on a false predicate first, so this is not case 1 again.
    PERFORM pg_sleep(2);
    SELECT s INTO status FROM df.status(inst_id) s;
    IF lower(status) NOT IN ('pending', 'running') THEN
        RAISE EXCEPTION 'TEST FAILED (becomes true): instance left the wait early, status = %', status;
    END IF;
END $$;

-- Must be its own statement: a write inside the polling block would not be
-- visible to the worker's separate connection until that block committed.
UPDATE test_cond_gate SET ready = true WHERE name = 'later';

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_state WHERE name = 'later';
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (becomes true): status = %', status;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM test_cond_done WHERE name = 'later') THEN
        RAISE EXCEPTION 'TEST FAILED (becomes true): body did not run';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Notification beats a 5-minute backstop, and the waiter registry is
--    populated while parked and cleared once the predicate fires.
-- ---------------------------------------------------------------------------
INSERT INTO _cond_state (name, instance_id)
SELECT 'notified', df.start(
    df.wait_for_condition(
        'SELECT ready FROM test_cond_gate WHERE name = ''notified''',
        '5min',
        notify_key => 'test_cond_key'
    ) ~> 'INSERT INTO test_cond_done VALUES (''notified'')',
    'test-cond-notified'
);

DO $$
DECLARE
    inst_id  TEXT;
    attempts INT := 0;
    waiters  INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_state WHERE name = 'notified';

    -- Wait for the node to register before notifying.
    LOOP
        SELECT count(*) INTO waiters
          FROM df.condition_waiters
         WHERE notify_key = 'test_cond_key'
           AND split_part(instance_id, '::', 1) = inst_id;
        EXIT WHEN waiters > 0 OR attempts > 200;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF waiters = 0 THEN
        RAISE EXCEPTION 'TEST FAILED (notify): no waiter row registered for %', inst_id;
    END IF;
END $$;

-- Own statements again: both the gate write and the notification are only
-- visible/delivered at commit.
UPDATE test_cond_gate SET ready = true WHERE name = 'notified';
SELECT pg_notify('pg_durable_condition', 'test_cond_key');

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    started  TIMESTAMPTZ := clock_timestamp();
    attempts INT := 0;
    waiters  INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_state WHERE name = 'notified';

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (notify): status = %', status;
    END IF;

    -- The backstop is 5 minutes, so completing at all within the 30s poll
    -- budget proves the notification woke it.
    IF extract(epoch FROM clock_timestamp() - started) > 30 THEN
        RAISE EXCEPTION 'TEST FAILED (notify): took % seconds, backstop must not have been beaten',
            extract(epoch FROM clock_timestamp() - started);
    END IF;

    SELECT count(*) INTO waiters
      FROM df.condition_waiters
     WHERE split_part(instance_id, '::', 1) = inst_id;
    IF waiters > 0 THEN
        RAISE EXCEPTION 'TEST FAILED (notify): % waiter row(s) left registered', waiters;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. A second notification is still delivered after the first was consumed.
--    The node parks on one subscription, wakes on notification #1 with the
--    predicate still false, and must re-subscribe so notification #2 lands.
--    The backstop is 5 minutes, so only the notification path can complete it.
-- ---------------------------------------------------------------------------
INSERT INTO _cond_state (name, instance_id)
SELECT 'twice', df.start(
    df.wait_for_condition(
        'SELECT ready FROM test_cond_gate WHERE name = ''twice''',
        '5min',
        notify_key => 'test_cond_key2'
    ) ~> 'INSERT INTO test_cond_done VALUES (''twice'')',
    'test-cond-twice'
);

DO $$
DECLARE
    inst_id  TEXT;
    attempts INT := 0;
    waiters  INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_state WHERE name = 'twice';

    LOOP
        SELECT count(*) INTO waiters
          FROM df.condition_waiters
         WHERE notify_key = 'test_cond_key2'
           AND split_part(instance_id, '::', 1) = inst_id;
        EXIT WHEN waiters > 0 OR attempts > 200;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF waiters = 0 THEN
        RAISE EXCEPTION 'TEST FAILED (twice): no waiter row registered for %', inst_id;
    END IF;
END $$;

-- Notification #1: the gate is still false, so this only burns the node's
-- current subscription.
SELECT pg_notify('pg_durable_condition', 'test_cond_key2');

-- Give the node time to consume #1, re-check, and re-subscribe. This also
-- clears the listener's per-key suppression window so #2 is not deduplicated.
SELECT pg_sleep(3);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_state WHERE name = 'twice';
    SELECT s INTO status FROM df.status(inst_id) s;
    IF lower(status) != 'running' THEN
        RAISE EXCEPTION 'TEST FAILED (twice): woke early on notification #1, status = %', status;
    END IF;
END $$;

-- Notification #2, now with the predicate satisfiable.
UPDATE test_cond_gate SET ready = true WHERE name = 'twice';
SELECT pg_notify('pg_durable_condition', 'test_cond_key2');

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    started  TIMESTAMPTZ := clock_timestamp();
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_state WHERE name = 'twice';

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (twice): status = %', status;
    END IF;

    IF extract(epoch FROM clock_timestamp() - started) > 30 THEN
        RAISE EXCEPTION 'TEST FAILED (twice): took % seconds, notification #2 was not delivered',
            extract(epoch FROM clock_timestamp() - started);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM test_cond_done WHERE name = 'twice') THEN
        RAISE EXCEPTION 'TEST FAILED (twice): body did not run';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. A predicate with side effects fails the node instead of writing.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS test_cond_sideeffect;
CREATE TABLE test_cond_sideeffect (n INT);

CREATE TEMP TABLE _cond_write AS
SELECT df.start(
    df.wait_for_condition(
        'SELECT true FROM (INSERT INTO test_cond_sideeffect VALUES (1) RETURNING n) w',
        '1s'
    ),
    'test-cond-readonly'
) AS instance_id;

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_write;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED (read-only): expected failed, got %', status;
    END IF;

    IF EXISTS (SELECT 1 FROM test_cond_sideeffect) THEN
        RAISE EXCEPTION 'TEST FAILED (read-only): predicate wrote a row';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 6. A non-boolean predicate is rejected rather than coerced.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _cond_count AS
SELECT df.start(
    df.wait_for_condition('SELECT count(*) FROM test_cond_gate', '1s'),
    'test-cond-count'
) AS instance_id;

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _cond_count;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED (non-boolean): expected failed, got %', status;
    END IF;
END $$;

-- Cleanup
DROP TABLE _cond_state;
DROP TABLE _cond_write;
DROP TABLE _cond_count;
DROP TABLE test_cond_gate;
DROP TABLE test_cond_done;
DROP TABLE test_cond_sideeffect;

SELECT 'TEST PASSED' AS result;
