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
    first_pid INT;
    first_query_start TIMESTAMPTZ;
    second_pid INT;
    second_query_start TIMESTAMPTZ;
    third_pid INT;
    third_query_start TIMESTAMPTZ;
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

    -- Identify the graph-probe backend by the query it is actually running
    -- (not just any lock-waiting management-pool backend, which could match
    -- an unrelated query) so we can recognize a genuinely new attempt.
    -- Match on the graph-probe's exact leading text ("SELECT root_node, ...
    -- AS submitted_by") rather than the generic "FROM df.instances"
    -- substring: the worker's periodic terminal-instance retention/cleanup
    -- query also reads df.instances and also blocks on this same lock, so a
    -- loose substring match can pick that unrelated backend instead.
    --
    -- We identify a genuinely NEW retry attempt by query_start advancing,
    -- not by the backend pid changing: the management pool may legitimately
    -- reuse the same physical connection across retries (a client-side
    -- timeout abandons a query without necessarily evicting/reopening the
    -- pooled connection), so requiring a different pid would wrongly fail
    -- even when the retry path is working correctly. query_start is set
    -- fresh each time a backend begins a new query - even one that
    -- immediately blocks acquiring a lock - so an advancing query_start on a
    -- matching row unambiguously proves a new attempt was submitted.
    --
    -- We key off state = 'active' rather than wait_event_type = 'Lock': a
    -- backend parked in the heavyweight lock manager only reports
    -- wait_event_type = 'Lock' for the brief instant it first enters the
    -- wait - PostgreSQL's periodic deadlock-check wakeup clears it back to
    -- NULL for most of the actual wait even though the backend is still
    -- blocked making no progress (state stays 'active', the query text is
    -- unchanged). Since our own transaction holds an ACCESS EXCLUSIVE lock
    -- on df.instances for this whole scenario, no backend anywhere can be
    -- genuinely, successfully executing this query against df.instances
    -- while we hold it, so "state = active" plus matching application_name
    -- and query text is an unambiguous, race-free signal that a backend is
    -- blocked behind our lock.
    -- pg_stat_activity's backing function takes a snapshot of all backend
    -- statuses that is cached for the lifetime of the current transaction;
    -- repeated reads within the same transaction (which this whole DO block
    -- runs in, since it holds the ACCESS EXCLUSIVE lock throughout) would
    -- otherwise silently return the same frozen point-in-time view forever.
    -- pg_stat_clear_snapshot() must be called before every poll so each
    -- iteration observes genuinely live backend state.
    attempts := 0;
    LOOP
        PERFORM pg_stat_clear_snapshot();
        SELECT pid, query_start INTO first_pid, first_query_start
        FROM pg_stat_activity
        WHERE application_name = 'pg_durable:worker:management'
          AND state = 'active'
          AND query ILIKE 'SELECT root_node,%submitted_by%FROM df.instances%'
        ORDER BY query_start
        LIMIT 1;
        EXIT WHEN first_pid IS NOT NULL OR attempts >= 400;
        PERFORM pg_sleep(0.05);
        attempts := attempts + 1;
    END LOOP;
    IF first_pid IS NULL THEN
        RAISE EXCEPTION
            'TEST FAILED [transient retry]: no blocked graph-probe backend found';
    END IF;
    IF NOT pg_terminate_backend(first_pid) THEN
        RAISE EXCEPTION
            'TEST FAILED [transient retry]: could not terminate graph-probe backend %',
            first_pid;
    END IF;

    -- Prove the connection-failure retry path actually ran: a fresh attempt
    -- with a later query_start must appear. Nothing else can make this
    -- query progress while the ACCESS EXCLUSIVE lock is held, so a new
    -- query_start can only appear because the terminated connection's error
    -- was classified transient and retried by the orchestration - not
    -- treated as a terminal activity failure.
    attempts := 0;
    LOOP
        PERFORM pg_stat_clear_snapshot();
        SELECT pid, query_start INTO second_pid, second_query_start
        FROM pg_stat_activity
        WHERE application_name = 'pg_durable:worker:management'
          AND state = 'active'
          AND query ILIKE 'SELECT root_node,%submitted_by%FROM df.instances%'
          AND query_start > first_query_start
        ORDER BY query_start
        LIMIT 1;
        EXIT WHEN second_pid IS NOT NULL OR attempts >= 400;
        PERFORM pg_sleep(0.05);
        attempts := attempts + 1;
    END LOOP;
    IF second_pid IS NULL THEN
        RAISE EXCEPTION
            'TEST FAILED [transient retry]: no retry attempt observed after terminating %; the connection-failure retry path did not execute',
            first_pid;
    END IF;

    -- Prove the *timeout* path also runs, independent of our explicit kill:
    -- nothing else can terminate the second attempt, so a third, later
    -- query_start can only appear once that attempt's own bounded
    -- client-side query timeout elapsed and the orchestration rescheduled
    -- it - proof that the timeout-retry path (not just the kill-retry path)
    -- actually executes before we release the lock.
    attempts := 0;
    LOOP
        PERFORM pg_stat_clear_snapshot();
        SELECT pid, query_start INTO third_pid, third_query_start
        FROM pg_stat_activity
        WHERE application_name = 'pg_durable:worker:management'
          AND state = 'active'
          AND query ILIKE 'SELECT root_node,%submitted_by%FROM df.instances%'
          AND query_start > second_query_start
        ORDER BY query_start
        LIMIT 1;
        EXIT WHEN third_pid IS NOT NULL OR attempts >= 400;
        PERFORM pg_sleep(0.05);
        attempts := attempts + 1;
    END LOOP;
    IF third_pid IS NULL THEN
        RAISE EXCEPTION
            'TEST FAILED [transient retry]: no timeout-driven retry observed after %; the bounded query-timeout path did not execute',
            second_pid;
    END IF;
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
       OR engine_output IS NULL
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
       OR engine_output IS NULL
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
