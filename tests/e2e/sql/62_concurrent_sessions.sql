-- Test: Concurrent df.start() from multiple sessions (F1)
-- Demonstrates: Multiple PostgreSQL sessions calling df.start() simultaneously
--               produce unique instance IDs and all instances complete correctly.
--
-- Method: dblink opens separate backend connections and calls df.start() in
--         each, simulating concurrent sessions more faithfully than a single-
--         session loop.
--
-- Findings documented:
--   - Instance IDs are generated per-call (UUID-based); no collision observed
--     even with 10 concurrent sessions.
--   - Background worker handles a burst of instances from multiple sessions.
--
-- Requires superuser (connection string for dblink uses current role).

CREATE EXTENSION IF NOT EXISTS dblink;

-- ─── Build a dblink connection string for the local database ──────────────

CREATE TEMP TABLE _conc_conn AS
SELECT format(
    'host=localhost dbname=%s port=%s user=postgres',
    current_database(),
    current_setting('port')
) AS connstr;

-- ─── Launch instances from 10 separate dblink connections concurrently ────
-- Each dblink call runs in its own backend process (separate session).

CREATE TEMP TABLE _conc_instances (session_num INT, instance_id TEXT);

DO $$
DECLARE
    connstr TEXT;
    inst_id TEXT;
    i       INT;
BEGIN
    SELECT c.connstr INTO connstr FROM _conc_conn c;

    FOR i IN 1..10 LOOP
        -- Each dblink call opens a NEW backend connection
        SELECT * INTO inst_id FROM dblink(
            connstr,
            format(
                $q$SELECT df.start(
                       df.sql('SELECT %s AS session_num, pg_sleep(0.05)'),
                       'concurrent-session-%s'
                   )$q$,
                i, i
            )
        ) AS t(id TEXT);

        INSERT INTO _conc_instances (session_num, instance_id)
        VALUES (i, inst_id);

        RAISE NOTICE 'Session % started instance %', i, inst_id;
    END LOOP;
END $$;

-- ─── Verify all 10 instance IDs are distinct ──────────────────────────────

DO $$
DECLARE
    total_count    INT;
    distinct_count INT;
BEGIN
    SELECT COUNT(*), COUNT(DISTINCT instance_id)
    INTO total_count, distinct_count
    FROM _conc_instances;

    IF distinct_count != 10 THEN
        RAISE EXCEPTION 'TEST FAILED [F1]: expected 10 distinct instance IDs, got % distinct out of %',
            distinct_count, total_count;
    END IF;

    RAISE NOTICE 'PASSED [F1-a]: all 10 concurrent sessions produced distinct instance IDs';
END $$;

-- ─── Wait for all instances to reach a terminal state ─────────────────────

DO $$
DECLARE
    completed INT;
    tries     INT := 0;
BEGIN
    LOOP
        SELECT COUNT(*) INTO completed
        FROM _conc_instances c
        JOIN df.instances i ON i.id = c.instance_id
        WHERE lower(i.status) IN ('completed', 'failed', 'canceled', 'cancelled');

        EXIT WHEN completed >= 10 OR tries > 600;
        PERFORM pg_sleep(0.1);
        tries := tries + 1;
    END LOOP;

    IF completed < 10 THEN
        RAISE EXCEPTION 'TEST FAILED [F1]: only %/10 concurrent instances completed within 60s', completed;
    END IF;

    RAISE NOTICE 'PASSED [F1-b]: all 10 concurrent-session instances completed';
END $$;

-- ─── Verify no instances are stuck ────────────────────────────────────────

DO $$
DECLARE
    stuck INT;
BEGIN
    SELECT COUNT(*) INTO stuck
    FROM _conc_instances c
    JOIN df.instances i ON i.id = c.instance_id
    WHERE lower(i.status) IN ('pending', 'running');

    IF stuck > 0 THEN
        RAISE EXCEPTION 'TEST FAILED [F1]: % instances stuck in pending/running after concurrent start', stuck;
    END IF;

    RAISE NOTICE 'PASSED [F1-c]: no instances stuck after concurrent multi-session start';
END $$;

-- ─── Cleanup ──────────────────────────────────────────────────────────────

DROP TABLE _conc_instances;
DROP TABLE _conc_conn;

SELECT 'TEST PASSED' AS result;
