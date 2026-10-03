CREATE EXTENSION IF NOT EXISTS dblink;

DO $$
BEGIN
    IF current_database() IS DISTINCT FROM df.target_database() OR
        current_setting('pg_durable.retention_days') <> '0' OR
        current_setting('pg_durable.reconcile_interval') <> '2' THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: use the reconcile phase';
    END IF;
    IF (SELECT atttypid FROM pg_attribute
        WHERE attrelid = format('%I.instances', df.duroxide_schema())::regclass
            AND attname = 'created_at') IS DISTINCT FROM 'timestamptz'::regtype::oid OR
        (SELECT atttypid FROM pg_attribute
        WHERE attrelid = format('%I.executions', df.duroxide_schema())::regclass
            AND attname = 'completed_at') IS DISTINCT FROM 'timestamptz'::regtype::oid OR
        (SELECT atttypid FROM pg_attribute
        WHERE attrelid = format('%I.executions', df.duroxide_schema())::regclass
            AND attname = 'status') IS DISTINCT FROM 'text'::regtype::oid THEN
        RAISE EXCEPTION 'TEST FAILED [provider types]: expected timestamptz timestamps and text status';
    END IF;
END $$;

DROP DATABASE IF EXISTS _e2e73_origin WITH (FORCE);
DROP DATABASE IF EXISTS _e2e73_peer WITH (FORCE);
DROP DATABASE IF EXISTS _e2e73_removed WITH (FORCE);
CREATE DATABASE _e2e73_origin;
CREATE DATABASE _e2e73_peer;
CREATE DATABASE _e2e73_removed;

CREATE TEMP TABLE _e2e73_ids (
    origin TEXT,
    scenario TEXT,
    local_id TEXT NOT NULL,
    engine_id TEXT NOT NULL,
    PRIMARY KEY (origin, scenario)
);

DO $$
DECLARE
    origin_name TEXT;
BEGIN
    FOREACH origin_name IN ARRAY ARRAY['_e2e73_origin', '_e2e73_peer', '_e2e73_removed'] LOOP
        PERFORM dblink_connect(origin_name, format(
            'host=localhost port=%s dbname=%L user=postgres', current_setting('port'), origin_name));
        PERFORM dblink_exec(origin_name, $remote$
            CREATE EXTENSION pg_durable;
            CREATE TEMP TABLE test_state (scenario TEXT PRIMARY KEY, local_id TEXT);
            CREATE FUNCTION public.e2e73_hold_metadata() RETURNS trigger LANGUAGE plpgsql AS $hold$
            BEGIN
                IF NEW.label LIKE 'e2e73-held-%' THEN
                    NEW.created_at := clock_timestamp() + interval '31 days';
                    IF NEW.status IN ('completed', 'failed', 'cancelled') THEN
                        NEW.completed_at := clock_timestamp() + interval '31 days';
                    END IF;
                END IF;
                RETURN NEW;
            END $hold$;
            CREATE TRIGGER e2e73_hold_metadata BEFORE INSERT OR UPDATE ON df.instances
                FOR EACH ROW EXECUTE FUNCTION public.e2e73_hold_metadata();
        $remote$);
    END LOOP;
END $$;

CREATE FUNCTION pg_temp.capture_ids(origin_name TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _e2e73_ids
        SELECT origin_name, remote.scenario, remote.local_id, remote.engine_id
        FROM dblink(origin_name, $remote$
            SELECT scenario, local_id,
                'pgdf-' || (SELECT oid::text FROM pg_database WHERE datname = current_database()) ||
                '-' || (SELECT replace(id::text, '-', '') FROM df._installation) || '-' || local_id
            FROM test_state
        $remote$) AS remote(scenario TEXT, local_id TEXT, engine_id TEXT)
        ON CONFLICT (origin, scenario) DO NOTHING;
END $$;

CREATE FUNCTION pg_temp.engine_status(engine_id TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    current_status TEXT;
BEGIN
    EXECUTE format('SELECT e.status FROM %1$I.instances i JOIN %1$I.executions e
        ON e.instance_id = i.instance_id AND e.execution_id = i.current_execution_id
        WHERE i.instance_id = $1', df.duroxide_schema()) INTO current_status USING engine_id;
    RETURN current_status;
END $$;

CREATE FUNCTION pg_temp.wait_engine(engine_id TEXT, expected TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    FOR attempt IN 1..600 LOOP
        IF pg_temp.engine_status(engine_id) IS NOT DISTINCT FROM expected THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    RAISE EXCEPTION 'TEST FAILED [engine wait]: % expected %, got %',
        engine_id, expected, pg_temp.engine_status(engine_id);
END $$;

CREATE FUNCTION pg_temp.wait_subscription(engine_id TEXT, signal_name TEXT) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    subscribed BOOLEAN;
BEGIN
    FOR attempt IN 1..300 LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %1$I.history h JOIN %1$I.instances i
            ON i.instance_id = h.instance_id AND i.current_execution_id = h.execution_id
            WHERE h.instance_id = $1 AND h.event_data::jsonb->>''type'' = ''ExternalSubscribed''
                AND h.event_data::jsonb->>''name'' = $2)', df.duroxide_schema())
            INTO subscribed USING engine_id, signal_name;
        IF subscribed THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    RAISE EXCEPTION 'TEST FAILED [subscription wait]: % never subscribed to % (engine status: %)',
        engine_id, signal_name, pg_temp.engine_status(engine_id);
END $$;

CREATE FUNCTION pg_temp.assert_engine_gone(engine_id TEXT) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    table_name TEXT;
    remaining BIGINT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['instances', 'executions', 'history',
        'orchestrator_queue', 'worker_queue', 'instance_locks'] LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I
            WHERE instance_id = $1 OR instance_id LIKE $1 || ''::%%''',
            df.duroxide_schema(), table_name) INTO remaining USING engine_id;
        IF remaining <> 0 THEN
            RAISE EXCEPTION 'TEST FAILED [engine cleanup]: % retains % rows for %', table_name, remaining, engine_id;
        END IF;
    END LOOP;
END $$;

SELECT dblink_exec('_e2e73_origin', $remote$
    INSERT INTO test_state VALUES ('completed', df.start('SELECT 73', 'e2e73-held-completed'));
    INSERT INTO test_state VALUES ('failed', df.start('SELECT 1 / 0', 'e2e73-held-failed'));
    INSERT INTO test_state VALUES ('cancelled', df.start(df.wait_for_signal('cancel-me'), 'e2e73-held-cancelled'));
    INSERT INTO test_state VALUES ('live', df.start(df.wait_for_signal('release'), 'e2e73-live'));
$remote$);
SELECT dblink_exec('_e2e73_peer', $remote$
    CREATE TABLE public._e2e73_success (marker TEXT PRIMARY KEY);
    INSERT INTO test_state VALUES ('failed', df.start('SELECT 1 / 0', 'e2e73-held-peer'));
    INSERT INTO test_state VALUES ('live', df.start(df.wait_for_signal('release')
        ~> 'INSERT INTO public._e2e73_success VALUES (''peer'') ON CONFLICT DO NOTHING', 'e2e73-peer-live'));
$remote$);
SELECT dblink_exec('_e2e73_removed', $remote$
    INSERT INTO test_state VALUES ('removed', df.start(
        'SELECT 73' ~> df.wait_for_signal('never-release'), 'e2e73-removed'));
$remote$);
SELECT pg_temp.capture_ids(origin_name)
FROM unnest(ARRAY['_e2e73_origin', '_e2e73_peer', '_e2e73_removed']) AS origins(origin_name);

SELECT pg_temp.wait_engine(engine_id, CASE WHEN scenario = 'completed' THEN 'Completed'
    WHEN scenario = 'failed' THEN 'Failed' ELSE 'Running' END) FROM _e2e73_ids;
SELECT dblink_exec('_e2e73_origin', $remote$
    DO $cancel$ BEGIN
        PERFORM df.cancel((SELECT local_id FROM test_state WHERE scenario = 'cancelled'), 'e2e73 cancellation');
    END $cancel$;
$remote$);
SELECT pg_temp.wait_engine(engine_id, 'Failed') FROM _e2e73_ids WHERE scenario = 'cancelled';

DO $$
DECLARE
    origin_name TEXT;
BEGIN
    FOREACH origin_name IN ARRAY ARRAY['_e2e73_origin', '_e2e73_peer', '_e2e73_removed'] LOOP
        PERFORM dblink_exec(origin_name, $remote$
            DO $waiting$
            BEGIN
                FOR attempt IN 1..300 LOOP
                    EXIT WHEN EXISTS (SELECT 1 FROM df.nodes WHERE node_type = 'SIGNAL' AND status = 'running');
                    PERFORM pg_sleep(0.1);
                END LOOP;
                IF NOT EXISTS (SELECT 1 FROM df.nodes WHERE node_type = 'SIGNAL' AND status = 'running') THEN
                    RAISE EXCEPTION 'TEST FAILED [setup]: no waiting signal';
                END IF;
                IF EXISTS (SELECT 1 FROM test_state s LEFT JOIN df.instances i ON i.id = s.local_id
                    WHERE s.scenario IN ('completed', 'failed', 'cancelled') AND
                        (i.status IS DISTINCT FROM s.scenario OR NOT EXISTS
                            (SELECT 1 FROM df.nodes n WHERE n.instance_id = s.local_id))) THEN
                    RAISE EXCEPTION 'TEST FAILED [terminal metadata]: missing or wrong terminal rows';
                END IF;
            END $waiting$;
        $remote$);
    END LOOP;
END $$;

-- A local-ID collision must not let satellite retention remove control metadata.
BEGIN;
INSERT INTO df.instances (id, root_node, submitted_by, status, label)
SELECT local_id, '00000073', 'postgres'::regrole, 'running', 'e2e73-shadow'
FROM _e2e73_ids WHERE origin = '_e2e73_origin' AND scenario = 'completed';
INSERT INTO df.nodes (id, instance_id, node_type, query, submitted_by, status)
SELECT '00000073', local_id, 'SQL', 'SELECT 73', 'postgres'::regrole, 'running'
FROM _e2e73_ids WHERE origin = '_e2e73_origin' AND scenario = 'completed';
COMMIT;

SELECT dblink_exec('_e2e73_origin', $remote$
    DROP TRIGGER e2e73_hold_metadata ON df.instances;
    UPDATE df.instances SET created_at = clock_timestamp() - interval '1 minute',
        completed_at = clock_timestamp() - interval '1 minute'
    WHERE label LIKE 'e2e73-held-%';
$remote$);
SELECT pg_temp.wait_engine(engine_id, NULL) FROM _e2e73_ids
WHERE origin = '_e2e73_origin' AND scenario IN ('completed', 'failed', 'cancelled');
SELECT dblink_exec('_e2e73_origin', $remote$
    DO $clean$
    BEGIN
        FOR attempt IN 1..300 LOOP
            EXIT WHEN NOT EXISTS (SELECT 1 FROM df.instances WHERE label LIKE 'e2e73-held-%');
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF EXISTS (SELECT 1 FROM df.instances WHERE label LIKE 'e2e73-held-%') OR
            EXISTS (SELECT 1 FROM df.nodes WHERE instance_id IN
                (SELECT local_id FROM test_state WHERE scenario IN ('completed', 'failed', 'cancelled'))) THEN
            RAISE EXCEPTION 'TEST FAILED [terminal retention]: satellite metadata survived';
        END IF;
    END $clean$;
$remote$);
SELECT pg_temp.assert_engine_gone(engine_id) FROM _e2e73_ids
WHERE origin = '_e2e73_origin' AND scenario IN ('completed', 'failed', 'cancelled');
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM df.instances WHERE label = 'e2e73-shadow' AND status = 'running') OR
        NOT EXISTS (SELECT 1 FROM df.nodes WHERE id = '00000073') OR
        EXISTS (SELECT 1 FROM df.instances WHERE label IN ('e2e73-live', 'e2e73-peer-live', 'e2e73-removed')) THEN
        RAISE EXCEPTION 'TEST FAILED [isolation]: satellite retention crossed into control';
    END IF;
END $$;

DROP TABLE IF EXISTS public._e2e73_success;
CREATE TABLE public._e2e73_success (marker TEXT PRIMARY KEY);
INSERT INTO _e2e73_ids
SELECT current_database(), 'control', local_id, local_id
FROM (SELECT df.start(df.wait_for_signal('release')
    ~> 'INSERT INTO public._e2e73_success VALUES (''control'') ON CONFLICT DO NOTHING',
    'e2e73-control') AS local_id) AS root;
SELECT pg_temp.wait_engine(engine_id, 'Running') FROM _e2e73_ids WHERE scenario = 'control';
SELECT pg_temp.wait_subscription(engine_id, 'release') FROM _e2e73_ids WHERE scenario = 'control';
SELECT df.signal(local_id, 'release') FROM _e2e73_ids WHERE scenario = 'control';
DO $$
DECLARE
    control_id TEXT := (SELECT local_id FROM _e2e73_ids WHERE scenario = 'control');
BEGIN
    FOR attempt IN 1..300 LOOP
        IF EXISTS (SELECT 1 FROM public._e2e73_success WHERE marker = 'control') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    RAISE EXCEPTION 'TEST FAILED [control release]: committed success marker missing (engine status: %)',
        pg_temp.engine_status(control_id);
END $$;
SELECT pg_temp.wait_engine(engine_id, NULL) FROM _e2e73_ids WHERE scenario = 'control';

SELECT dblink_exec('_e2e73_origin', 'BEGIN');
INSERT INTO _e2e73_ids
SELECT '_e2e73_origin', 'orphan', remote.local_id, remote.prefix || remote.local_id
FROM dblink('_e2e73_origin', $remote$
    SELECT df.start('SELECT 73', 'e2e73-rollback'),
        'pgdf-' || (SELECT oid::text FROM pg_database WHERE datname = current_database()) ||
        '-' || (SELECT replace(id::text, '-', '') FROM df._installation) || '-'
$remote$) AS remote(local_id TEXT, prefix TEXT);
SELECT pg_temp.wait_engine(engine_id, 'Running') FROM _e2e73_ids WHERE scenario = 'orphan';
SELECT dblink_exec('_e2e73_origin', 'ROLLBACK');
SELECT pg_temp.wait_engine(engine_id, NULL) FROM _e2e73_ids WHERE scenario = 'orphan';
SELECT pg_temp.assert_engine_gone(engine_id) FROM _e2e73_ids WHERE scenario = 'orphan';

ALTER DATABASE _e2e73_peer ALLOW_CONNECTIONS false;
SELECT dblink_exec('_e2e73_peer', $remote$
    DROP TRIGGER e2e73_hold_metadata ON df.instances;
    UPDATE df.instances SET created_at = clock_timestamp() - interval '1 minute',
        completed_at = clock_timestamp() - interval '1 minute' WHERE label = 'e2e73-held-peer';
$remote$);
SELECT pg_sleep(12);
DO $$
DECLARE
    workflow RECORD;
BEGIN
    FOR workflow IN SELECT * FROM _e2e73_ids WHERE origin = '_e2e73_peer' LOOP
        IF pg_temp.engine_status(workflow.engine_id) IS DISTINCT FROM
            (CASE WHEN workflow.scenario = 'failed' THEN 'Failed' ELSE 'Running' END) THEN
            RAISE EXCEPTION 'TEST FAILED [unreachable origin]: engine data changed for %', workflow.scenario;
        END IF;
    END LOOP;
    PERFORM dblink_exec('_e2e73_peer', $remote$
        DO $check$ BEGIN
            IF (SELECT count(*) FROM df.instances) <> 2 OR NOT EXISTS (SELECT 1 FROM df.nodes) THEN
                RAISE EXCEPTION 'TEST FAILED [unreachable origin]: metadata destroyed';
            END IF;
        END $check$;
    $remote$);
END $$;
ALTER DATABASE _e2e73_peer ALLOW_CONNECTIONS true;
SELECT pg_temp.wait_engine(engine_id, NULL) FROM _e2e73_ids
WHERE origin = '_e2e73_peer' AND scenario = 'failed';
SELECT pg_temp.assert_engine_gone(engine_id) FROM _e2e73_ids
WHERE origin = '_e2e73_peer' AND scenario = 'failed';

SELECT dblink_exec('_e2e73_peer', 'BEGIN; LOCK TABLE df._installation IN ACCESS EXCLUSIVE MODE');
DO $$
DECLARE
    saw_blocked_probe BOOLEAN := false;
    live_id TEXT := (SELECT engine_id FROM _e2e73_ids WHERE origin = '_e2e73_peer' AND scenario = 'live');
BEGIN
    FOR attempt IN 1..120 LOOP
        PERFORM pg_stat_clear_snapshot();
        saw_blocked_probe := saw_blocked_probe OR EXISTS (
            SELECT 1 FROM pg_stat_activity WHERE datname = '_e2e73_peer'
                AND application_name = 'pg_durable:worker:management' AND wait_event_type = 'Lock');
        IF (SELECT count(*) FROM pg_stat_activity WHERE datname IN
            ('_e2e73_origin', '_e2e73_peer', '_e2e73_removed')
            AND application_name LIKE 'pg_durable:worker:%') >
                current_setting('pg_durable.max_origin_connections')::int THEN
            RAISE EXCEPTION 'TEST FAILED [connection budget]: origin admission limit exceeded';
        END IF;
        IF pg_temp.engine_status(live_id) IS DISTINCT FROM 'Running' THEN
            RAISE EXCEPTION 'TEST FAILED [locked origin]: live root cancelled or deleted';
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    IF NOT saw_blocked_probe THEN
        RAISE EXCEPTION 'TEST FAILED [locked origin]: maintenance never attempted the locked origin';
    END IF;
END $$;
SELECT dblink_exec('_e2e73_peer', 'ROLLBACK');
DO $$
BEGIN
    FOR attempt IN 1..300 LOOP
        PERFORM pg_stat_clear_snapshot();
        IF NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname IN
            ('_e2e73_origin', '_e2e73_peer', '_e2e73_removed')
            AND application_name LIKE 'pg_durable:worker:%') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
    RAISE EXCEPTION 'TEST FAILED [connection cleanup]: origin connections did not drain';
END $$;

-- Future timestamps exercise the non-expired side of the retention boundary at retention_days=0.
-- Cancellation must ignore creation age; deletion must still honor completion age.
CREATE FUNCTION public.e2e73_hold_engine_terminal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.instance_id = TG_ARGV[0] AND NEW.status IN ('Completed', 'Failed') THEN
        NEW.completed_at := clock_timestamp() + interval '31 days';
    END IF;
    RETURN NEW;
END $$;
DO $$
DECLARE
    removed_id TEXT := (SELECT engine_id FROM _e2e73_ids WHERE scenario = 'removed');
BEGIN
    EXECUTE format('UPDATE %I.instances SET created_at = clock_timestamp() + interval ''31 days''
        WHERE instance_id = $1', df.duroxide_schema()) USING removed_id;
    EXECUTE format('CREATE TRIGGER e2e73_hold_terminal BEFORE UPDATE OF status ON %I.executions
        FOR EACH ROW EXECUTE FUNCTION public.e2e73_hold_engine_terminal(%L)', df.duroxide_schema(), removed_id);
END $$;
SELECT dblink_exec('_e2e73_removed', 'DROP EXTENSION pg_durable CASCADE');
SELECT pg_temp.wait_engine(engine_id, 'Failed') FROM _e2e73_ids WHERE scenario = 'removed';
SELECT pg_sleep(8);
DO $$
DECLARE
    removed_id TEXT := (SELECT engine_id FROM _e2e73_ids WHERE scenario = 'removed');
BEGIN
    IF pg_temp.engine_status(removed_id) IS DISTINCT FROM 'Failed' THEN
        RAISE EXCEPTION 'TEST FAILED [removed retention]: unexpired terminal data deleted';
    END IF;
    EXECUTE format('DROP TRIGGER e2e73_hold_terminal ON %I.executions', df.duroxide_schema());
    EXECUTE format('UPDATE %I.executions SET completed_at = clock_timestamp() - interval ''1 minute''
        WHERE instance_id = $1', df.duroxide_schema()) USING removed_id;
END $$;
DROP FUNCTION public.e2e73_hold_engine_terminal();
SELECT pg_temp.wait_engine(engine_id, NULL) FROM _e2e73_ids WHERE scenario = 'removed';
SELECT pg_temp.assert_engine_gone(engine_id) FROM _e2e73_ids WHERE scenario = 'removed';

DO $$
DECLARE
    workflow RECORD;
BEGIN
    FOR workflow IN SELECT * FROM _e2e73_ids WHERE scenario = 'live' LOOP
        IF pg_temp.engine_status(workflow.engine_id) IS DISTINCT FROM 'Running' THEN
            RAISE EXCEPTION 'TEST FAILED [live isolation]: running root % was lost', workflow.origin;
        END IF;
        IF workflow.origin = '_e2e73_peer' THEN
            PERFORM pg_temp.wait_subscription(workflow.engine_id, 'release');
            PERFORM dblink_exec(workflow.origin, format(
            'DO $signal$ BEGIN PERFORM df.signal(%L, ''release''); END $signal$;', workflow.local_id));
        END IF;
    END LOOP;
END $$;
SELECT dblink_exec('_e2e73_peer', $remote$
    DO $released$
    BEGIN
        FOR attempt IN 1..300 LOOP
            IF EXISTS (SELECT 1 FROM public._e2e73_success WHERE marker = 'peer') THEN
                RETURN;
            END IF;
            PERFORM pg_sleep(0.1);
        END LOOP;
        RAISE EXCEPTION 'TEST FAILED [peer release]: committed success marker missing';
    END $released$;
$remote$);
    SELECT dblink_disconnect('_e2e73_origin');
    DROP DATABASE _e2e73_origin WITH (FORCE);
SELECT pg_temp.wait_engine(engine_id, NULL) FROM _e2e73_ids WHERE scenario = 'live';
SELECT pg_temp.assert_engine_gone(engine_id) FROM _e2e73_ids;

BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT id FROM df.instances WHERE label = 'e2e73-shadow');
DELETE FROM df.instances WHERE label = 'e2e73-shadow';
COMMIT;
DROP TABLE public._e2e73_success;
SELECT dblink_exec('_e2e73_peer', 'DROP TABLE public._e2e73_success');
SELECT dblink_disconnect(origin_name)
FROM unnest(ARRAY['_e2e73_peer', '_e2e73_removed']) AS origins(origin_name);
DROP DATABASE _e2e73_peer;
DROP DATABASE _e2e73_removed;

SELECT 'TEST PASSED: multi-database reconciliation' AS result;