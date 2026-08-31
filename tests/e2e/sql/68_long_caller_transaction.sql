-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- A caller-mode df.start() persists its graph in the caller's transaction but
-- hands the orchestration to duroxide on a separate committed connection. The
-- worker must follow the originating transaction rather than treating a legal
-- transaction lasting more than five seconds as a rollback.

CREATE TEMP TABLE _long_tx_state (instance_id TEXT, scenario TEXT);
DROP TABLE IF EXISTS long_tx_effects;
CREATE TABLE long_tx_effects (
    instance_id TEXT NOT NULL,
    scenario TEXT NOT NULL,
    PRIMARY KEY (instance_id, scenario)
);

CREATE OR REPLACE FUNCTION pg_temp.engine_info(p_instance_id TEXT)
RETURNS TABLE(status TEXT, output TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    provider_schema TEXT := df.duroxide_schema();
BEGIN
    RETURN QUERY EXECUTE format(
        'SELECT i.status, i.output FROM %I.get_instance_info($1) i',
        provider_schema
    ) USING p_instance_id;
END
$$;

-- A long transaction that commits must still execute exactly once.
BEGIN;
INSERT INTO _long_tx_state
SELECT df.start(
    'INSERT INTO long_tx_effects(instance_id, scenario)
     VALUES (''{sys_instance_id}'', ''committed'')',
    'long-caller-transaction'
), 'committed';

DO $$
DECLARE
    v_instance_id TEXT;
    engine_status TEXT;
    attempts INT := 0;
BEGIN
    SELECT s.instance_id INTO v_instance_id
    FROM _long_tx_state s
    WHERE s.scenario = 'committed';
    LOOP
        SELECT i.status INTO engine_status
        FROM pg_temp.engine_info(v_instance_id) i;
        EXIT WHEN lower(COALESCE(engine_status, '')) = 'running' OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(COALESCE(engine_status, '')) != 'running' THEN
        RAISE EXCEPTION
            'TEST FAILED [long commit]: engine did not start while caller transaction was open (status=%)',
            engine_status;
    END IF;

    -- Exceed the legacy fixed graph-visibility timeout after the engine is
    -- definitely running.
    PERFORM pg_sleep(6);
END
$$;
COMMIT;

DO $$
DECLARE
    v_instance_id TEXT;
    final_status TEXT;
    effect_count INT;
BEGIN
    SELECT s.instance_id INTO v_instance_id
    FROM _long_tx_state s
    WHERE s.scenario = 'committed';
    SELECT df.await_instance(v_instance_id, 30) INTO final_status;
    SELECT count(*) INTO effect_count
    FROM long_tx_effects e
    WHERE e.instance_id = v_instance_id
      AND e.scenario = 'committed';

    IF final_status IS DISTINCT FROM 'completed' OR effect_count != 1 THEN
        RAISE EXCEPTION
            'TEST FAILED [long commit]: status=%, effects=% (expected completed/1)',
            final_status, effect_count;
    END IF;
END
$$;

-- A transient management-connection failure while probing an uncommitted graph
-- must be retried durably rather than recorded as a terminal activity failure.
BEGIN;
LOCK TABLE df.instances IN ACCESS EXCLUSIVE MODE;
INSERT INTO _long_tx_state
SELECT df.start(
    'INSERT INTO long_tx_effects(instance_id, scenario)
     VALUES (''{sys_instance_id}'', ''transient-retry'')',
    'graph-probe-transient-retry'
), 'transient-retry';

DO $$
DECLARE
    v_instance_id TEXT;
    engine_status TEXT;
    target_pid INT;
    attempts INT := 0;
BEGIN
    SELECT s.instance_id INTO v_instance_id
    FROM _long_tx_state s
    WHERE s.scenario = 'transient-retry';

    LOOP
        SELECT i.status INTO engine_status
        FROM pg_temp.engine_info(v_instance_id) i;
        EXIT WHEN lower(COALESCE(engine_status, '')) = 'running' OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF lower(COALESCE(engine_status, '')) != 'running' THEN
        RAISE EXCEPTION
            'TEST FAILED [transient retry]: engine did not start (status=%)',
            engine_status;
    END IF;

    attempts := 0;
    LOOP
        SELECT pid INTO target_pid
        FROM pg_stat_activity
        WHERE application_name = 'pg_durable:worker:management'
          AND wait_event_type = 'Lock'
        ORDER BY pid
        LIMIT 1;
        EXIT WHEN target_pid IS NOT NULL OR attempts >= 300;
        PERFORM pg_sleep(0.05);
        attempts := attempts + 1;
    END LOOP;
    IF target_pid IS NULL THEN
        RAISE EXCEPTION
            'TEST FAILED [transient retry]: no blocked graph-probe backend found';
    END IF;
    IF NOT pg_terminate_backend(target_pid) THEN
        RAISE EXCEPTION
            'TEST FAILED [transient retry]: could not terminate graph-probe backend %',
            target_pid;
    END IF;

    -- Leave time for the killed query to return Retry and the next lock-blocked
    -- probe to hit its bounded query timeout before releasing the table lock.
    PERFORM pg_sleep(3);
END
$$;
COMMIT;

DO $$
DECLARE
    v_instance_id TEXT;
    final_status TEXT;
    effect_count INT;
BEGIN
    SELECT s.instance_id INTO v_instance_id
    FROM _long_tx_state s
    WHERE s.scenario = 'transient-retry';
    SELECT df.await_instance(v_instance_id, 30) INTO final_status;
    SELECT count(*) INTO effect_count
    FROM long_tx_effects e
    WHERE e.instance_id = v_instance_id
      AND e.scenario = 'transient-retry';

    IF final_status IS DISTINCT FROM 'completed' OR effect_count != 1 THEN
        RAISE EXCEPTION
            'TEST FAILED [transient retry]: status=%, effects=% (expected completed/1)',
            final_status, effect_count;
    END IF;
END
$$;

-- A whole-transaction rollback has an aborted originating xid. It must fail
-- without running SQL and without leaving a df.instances row.
BEGIN;
INSERT INTO _long_tx_state
SELECT df.start(
    'INSERT INTO long_tx_effects(instance_id, scenario)
     VALUES (''{sys_instance_id}'', ''whole-rollback'')',
    'whole-transaction-rollback'
) AS instance_id, 'whole-rollback-open'
RETURNING instance_id AS whole_rollback_id \gset

DO $$
DECLARE
    v_instance_id TEXT;
    engine_status TEXT;
    attempts INT := 0;
BEGIN
    SELECT s.instance_id INTO v_instance_id
    FROM _long_tx_state s
    WHERE s.scenario = 'whole-rollback-open';

    LOOP
        SELECT i.status INTO engine_status
        FROM pg_temp.engine_info(v_instance_id) i;
        EXIT WHEN lower(COALESCE(engine_status, '')) = 'running' OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(COALESCE(engine_status, '')) != 'running' THEN
        RAISE EXCEPTION
            'TEST FAILED [whole rollback]: engine did not start while caller transaction was open (status=%)',
            engine_status;
    END IF;

    -- The transaction remains legal and in progress past the old timeout. The
    -- transaction-aware path must keep waiting until the rollback below.
    PERFORM pg_sleep(6);
END
$$;
ROLLBACK;

INSERT INTO _long_tx_state VALUES (:'whole_rollback_id', 'whole-rollback');

DO $$
DECLARE
    v_instance_id TEXT;
    engine_status TEXT;
    engine_output TEXT;
    attempts INT := 0;
BEGIN
    SELECT s.instance_id INTO v_instance_id
    FROM _long_tx_state s
    WHERE s.scenario = 'whole-rollback';

    LOOP
        SELECT i.status, i.output INTO engine_status, engine_output
        FROM pg_temp.engine_info(v_instance_id) i;
        EXIT WHEN lower(COALESCE(engine_status, '')) = 'failed' OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(COALESCE(engine_status, '')) != 'failed'
       OR engine_output NOT LIKE '%origin transaction%aborted%' THEN
        RAISE EXCEPTION
            'TEST FAILED [whole rollback]: engine status=%, output=%',
            engine_status, engine_output;
    END IF;
    IF EXISTS (SELECT 1 FROM df.instances i WHERE i.id = v_instance_id)
       OR EXISTS (SELECT 1 FROM long_tx_effects e WHERE e.instance_id = v_instance_id) THEN
        RAISE EXCEPTION
            'TEST FAILED [whole rollback]: rolled-back df row or side effect exists for %',
            v_instance_id;
    END IF;
END
$$;

-- Rolling back only the start's savepoint leaves the top-level xid committed
-- but the graph absent. This must be distinguished from an in-progress commit.
BEGIN;
SAVEPOINT before_start;
SELECT df.start(
    'INSERT INTO long_tx_effects(instance_id, scenario)
     VALUES (''{sys_instance_id}'', ''savepoint-rollback'')',
    'savepoint-rollback'
) AS savepoint_rollback_id \gset
ROLLBACK TO SAVEPOINT before_start;
COMMIT;

INSERT INTO _long_tx_state VALUES (:'savepoint_rollback_id', 'savepoint-rollback');

DO $$
DECLARE
    v_instance_id TEXT;
    engine_status TEXT;
    engine_output TEXT;
    attempts INT := 0;
BEGIN
    SELECT s.instance_id INTO v_instance_id
    FROM _long_tx_state s
    WHERE s.scenario = 'savepoint-rollback';

    LOOP
        SELECT i.status, i.output INTO engine_status, engine_output
        FROM pg_temp.engine_info(v_instance_id) i;
        EXIT WHEN lower(COALESCE(engine_status, '')) = 'failed' OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(COALESCE(engine_status, '')) != 'failed'
       OR engine_output NOT LIKE '%committed%graph%absent%' THEN
        RAISE EXCEPTION
            'TEST FAILED [savepoint rollback]: engine status=%, output=%',
            engine_status, engine_output;
    END IF;
    IF EXISTS (SELECT 1 FROM df.instances i WHERE i.id = v_instance_id)
       OR EXISTS (SELECT 1 FROM long_tx_effects e WHERE e.instance_id = v_instance_id) THEN
        RAISE EXCEPTION
            'TEST FAILED [savepoint rollback]: rolled-back df row or side effect exists for %',
            v_instance_id;
    END IF;
END
$$;

DROP TABLE _long_tx_state;
DROP TABLE long_tx_effects;
SELECT 'TEST PASSED: long caller transaction handoff' AS result;
