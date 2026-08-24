-- ============================================================================
-- E2E Test: df.instance_activity()
--
-- Answers "is this workflow actually doing anything?". A long-running instance
-- is indistinguishable from a wedged one by status alone -- both read
-- 'running' -- so this reports when each instance last transitioned a node and
-- how long it has been quiet since.
--
-- The report is about work *in progress*, so every assertion about a listed
-- instance has to be made while that instance is still non-terminal.
-- ============================================================================

DROP TABLE IF EXISTS test_activity_log;

CREATE TABLE test_activity_log (id SERIAL PRIMARY KEY, note TEXT);

-- ---------------------------------------------------------------------------
-- Case 1: a working instance reports recent activity and a small idle time.
-- The instance sleeps between two nodes, so there is a wide window in which it
-- is unambiguously alive.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _ia_busy AS
SELECT df.start(
    $$INSERT INTO test_activity_log (note) VALUES ('first')$$
    ~> df.sleep(8)
    ~> $$INSERT INTO test_activity_log (note) VALUES ('second')$$,
    'test-activity-busy'
) AS instance_id;

DO $$
DECLARE
    inst TEXT;
    idle_seconds DOUBLE PRECISION;
    last_activity TIMESTAMPTZ;
    row_count INT;
    attempts INT := 0;
BEGIN
    SELECT i.instance_id INTO inst FROM _ia_busy i;

    -- Wait until the worker has actually picked the instance up, so the
    -- assertions below describe a running instance rather than a queued one.
    LOOP
        EXIT WHEN lower(df.status(inst)) = 'running' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    SELECT count(*) INTO row_count
    FROM df.instance_activity() a
    WHERE a.instance_id = inst;

    IF row_count <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED [busy]: expected the running instance to be listed once, got % rows', row_count;
    END IF;

    SELECT a.last_activity_at, a.idle_for_seconds
      INTO last_activity, idle_seconds
    FROM df.instance_activity() a
    WHERE a.instance_id = inst;

    IF last_activity IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [busy]: last_activity_at must not be NULL';
    END IF;

    IF idle_seconds IS NULL OR idle_seconds < 0 THEN
        RAISE EXCEPTION 'TEST FAILED [busy]: idle_for_seconds must be non-negative, got %', idle_seconds;
    END IF;

    -- ---------------------------------------------------------------------
    -- Case 2: the idle-threshold filter, asserted on this same live instance.
    -- It has been active seconds ago, so an hour-long threshold must exclude
    -- it while a zero threshold must include it.
    -- ---------------------------------------------------------------------
    SELECT count(*) INTO row_count
    FROM df.instance_activity('1 hour') a
    WHERE a.instance_id = inst;

    IF row_count <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED [threshold]: an instance active seconds ago must not be reported idle for 1 hour, got % rows', row_count;
    END IF;

    SELECT count(*) INTO row_count
    FROM df.instance_activity('0 seconds') a
    WHERE a.instance_id = inst;

    IF row_count <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED [threshold]: a zero threshold must report a running instance, got % rows', row_count;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Case 3: the report distinguishes a live instance from a wedged one. A loop
-- whose body always fails under on_failure => 'continue' keeps its status at
-- 'running' forever, which is exactly the case status alone cannot diagnose.
-- It must be listed with its failing node's error.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _ia_wedged AS
SELECT df.start(
    df.loop(
        $$SELECT 1 / 0$$,
        'SELECT true'
    ),
    'test-activity-wedged',
    max_attempts => 1,
    on_failure => 'continue'
) AS instance_id;

DO $$
DECLARE
    inst TEXT;
    status TEXT;
    failed_nodes BIGINT;
    last_error TEXT;
    attempts INT := 0;
BEGIN
    SELECT i.instance_id INTO inst FROM _ia_wedged i;

    -- Wait for the loop to abandon at least one iteration.
    LOOP
        SELECT a.failed_node_count, a.last_error
          INTO failed_nodes, last_error
        FROM df.instance_activity('0 seconds') a
        WHERE a.instance_id = inst;

        EXIT WHEN COALESCE(failed_nodes, 0) > 0 OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF COALESCE(failed_nodes, 0) = 0 THEN
        RAISE EXCEPTION 'TEST FAILED [wedged]: expected a failed node to be reported, got %', failed_nodes;
    END IF;

    IF last_error IS NULL OR last_error NOT LIKE '%division by zero%' THEN
        RAISE EXCEPTION 'TEST FAILED [wedged]: expected the division error to be surfaced, got %', last_error;
    END IF;

    -- The instance is still 'running', which is the whole point: status alone
    -- says healthy, the activity report says otherwise.
    SELECT df.status(inst) INTO status;
    IF lower(status) NOT IN ('running', 'pending') THEN
        RAISE EXCEPTION 'TEST FAILED [wedged]: expected the wedged loop to still be running, got %', status;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Case 4: the report respects row-level security. Asserted while both
-- instances are still non-terminal, so a clean result means RLS filtered them
-- and not that they had already dropped out of the report.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ia_other_user') THEN
        CREATE ROLE ia_other_user LOGIN;
    END IF;
END $$;

SELECT df.grant_usage('ia_other_user');

DO $$
DECLARE
    visible INT;
    leaked INT;
BEGIN
    -- Precondition: as the owner, both instances are in the report right now.
    SELECT count(*) INTO visible
    FROM df.instance_activity('0 seconds') a
    WHERE a.label IN ('test-activity-busy', 'test-activity-wedged');

    IF visible <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED [rls]: expected the owner to see both live instances, got %', visible;
    END IF;

    SET LOCAL ROLE ia_other_user;

    SELECT count(*) INTO leaked
    FROM df.instance_activity('0 seconds') a
    WHERE a.label IN ('test-activity-busy', 'test-activity-wedged');

    IF leaked <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED [rls]: another user saw % of our instances', leaked;
    END IF;
END $$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- Case 5: a terminal instance is not reported. The report is about work in
-- progress, so once the busy instance completes it must drop out entirely,
-- even under a zero threshold.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    inst TEXT;
    final_status TEXT;
    found INT;
BEGIN
    SELECT i.instance_id INTO inst FROM _ia_busy i;

    SELECT df.await_instance(inst, 60) INTO final_status;
    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [terminal]: expected completed, got %', final_status;
    END IF;

    SELECT count(*) INTO found
    FROM df.instance_activity('0 seconds') a
    WHERE a.instance_id = inst;

    IF found <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED [terminal]: a completed instance must not be reported, got % rows', found;
    END IF;
END $$;

-- Cleanup
DO $$
DECLARE
    inst TEXT;
BEGIN
    SELECT i.instance_id INTO inst FROM _ia_wedged i;
    PERFORM df.cancel(inst);
    PERFORM df.await_instance(inst, 60);
END $$;

DROP TABLE _ia_busy;
DROP TABLE _ia_wedged;
DROP TABLE test_activity_log;
SELECT df.revoke_usage('ia_other_user');
DROP ROLE IF EXISTS ia_other_user;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
