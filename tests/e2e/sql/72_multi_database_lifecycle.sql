-- === Setup: owned databases; administration as postgres, workloads as df_e2e_user ===

CREATE EXTENSION IF NOT EXISTS dblink;

DO $$
BEGIN
    IF current_database() IS DISTINCT FROM df.target_database() THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: run lifecycle tests in the control database';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user' AND (rolsuper OR rolbypassrls)) THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: df_e2e_user must not bypass RLS';
    END IF;
END $$;

BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT id FROM df.instances WHERE label = 'e2e72-shadow');
DELETE FROM df.instances WHERE label = 'e2e72-shadow';
COMMIT;

DROP DATABASE IF EXISTS _e2e72_origin WITH (FORCE);
DROP DATABASE IF EXISTS "_e2e72 satellite ""peer""" WITH (FORCE);
DROP DATABASE IF EXISTS _e2e72_target WITH (FORCE);
CREATE DATABASE _e2e72_origin;
CREATE DATABASE "_e2e72 satellite ""peer""";
CREATE DATABASE _e2e72_target;

CREATE TEMP TABLE _e2e72_databases (connection_name TEXT PRIMARY KEY, database_name TEXT NOT NULL);
INSERT INTO _e2e72_databases VALUES
    ('e2e72_origin', '_e2e72_origin'),
    ('e2e72_peer', '_e2e72 satellite "peer"'),
    ('e2e72_target', '_e2e72_target');
CREATE TEMP TABLE _e2e72_epoch AS SELECT epoch_id FROM df._worker_epoch;

DROP TABLE IF EXISTS public.e2e72_log;
CREATE TABLE public.e2e72_log (
    marker TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    database_name TEXT NOT NULL DEFAULT current_database(),
    role_name TEXT NOT NULL DEFAULT current_user
);
GRANT SELECT, INSERT ON public.e2e72_log TO df_e2e_user;

DO $$
DECLARE
    remote_db RECORD;
BEGIN
    FOR remote_db IN SELECT * FROM _e2e72_databases ORDER BY connection_name LOOP
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO df_e2e_user', remote_db.database_name);
        PERFORM dblink_connect(remote_db.connection_name, format(
            'host=localhost dbname=%L port=%s user=postgres',
            remote_db.database_name, current_setting('port')
        ));
        IF remote_db.connection_name <> 'e2e72_target' THEN
            PERFORM dblink_exec(remote_db.connection_name, 'CREATE EXTENSION pg_durable');
            PERFORM dblink_exec(remote_db.connection_name,
                'DO $grant$ BEGIN PERFORM df.grant_usage(''df_e2e_user''); END $grant$');
        END IF;
        PERFORM dblink_exec(remote_db.connection_name, $remote$
            CREATE TABLE public.e2e72_log (
                marker TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                database_name TEXT NOT NULL DEFAULT current_database(),
                role_name TEXT NOT NULL DEFAULT current_user
            );
            GRANT SELECT, INSERT ON public.e2e72_log TO df_e2e_user;
            SET SESSION AUTHORIZATION df_e2e_user;
            CREATE TEMP TABLE e2e72_state (scenario TEXT PRIMARY KEY, instance_id TEXT NOT NULL);
        $remote$);
    END LOOP;
END $$;

-- === Explicit third target from a satellite; quoted satellite name on the SQLx route ===

SELECT dblink_exec('e2e72_peer', $remote$
    DO $setvar$ BEGIN PERFORM df.setvar('e2e72_value', 'satellite-captured'); END $setvar$;
$remote$);
SELECT dblink_exec('e2e72_peer', $remote$
    INSERT INTO e2e72_state SELECT 'third-target', df.start(
        'INSERT INTO public.e2e72_log (marker, value) VALUES (''third-first'', ''{e2e72_value}'')'
        ~> 'INSERT INTO public.e2e72_log (marker, value) VALUES (''third-second'', current_database())',
        'e2e72-third-target', database => '_e2e72_target'
    );
    INSERT INTO e2e72_state SELECT 'quoted-local', df.start(
        'INSERT INTO public.e2e72_log (marker, value) VALUES (''quoted-local'', current_database())',
        'e2e72-quoted-local'
    );
$remote$);
SELECT dblink_exec('e2e72_peer', $remote$
    DO $await$
    DECLARE
        workflow RECORD;
        final_status TEXT;
    BEGIN
        FOR workflow IN SELECT * FROM e2e72_state LOOP
            final_status := df.await_instance(workflow.instance_id, 30);
            IF final_status IS DISTINCT FROM 'completed' THEN
                RAISE EXCEPTION 'TEST FAILED [routing %]: status = %', workflow.scenario, final_status;
            END IF;
        END LOOP;
    END $await$;
$remote$);
SELECT dblink_exec('e2e72_peer', $remote$
    DO $check$
    DECLARE
        target_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'third-target');
        local_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'quoted-local');
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM df.instances WHERE id = target_id AND database = '_e2e72_target') OR
            NOT EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = target_id) OR
            EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = target_id AND
                (database IS DISTINCT FROM '_e2e72_target' OR status IS DISTINCT FROM 'completed')) THEN
            RAISE EXCEPTION 'TEST FAILED [third target]: origin metadata missing or misrouted';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM df.instance_info(target_id) WHERE status = 'completed') OR
            NOT EXISTS (SELECT 1 FROM df.instance_executions(target_id)) OR
            NOT EXISTS (SELECT 1 FROM df.instance_info(local_id) WHERE status = 'completed') THEN
            RAISE EXCEPTION 'TEST FAILED [quoted origin]: provider lookup failed';
        END IF;
        IF (SELECT count(*) FROM public.e2e72_log) <> 1 OR NOT EXISTS (
            SELECT 1 FROM public.e2e72_log WHERE marker = 'quoted-local'
                AND value = current_database() AND database_name = current_database()
                AND role_name = 'df_e2e_user'
        ) THEN
            RAISE EXCEPTION 'TEST FAILED [quoted origin]: third-target writes leaked into origin';
        END IF;
    END $check$;
$remote$);
SELECT dblink_exec('e2e72_target', $remote$
    DO $check$
    BEGIN
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_durable') OR
            (SELECT count(*) FROM public.e2e72_log) <> 2 OR
            NOT EXISTS (SELECT 1 FROM public.e2e72_log
                WHERE marker = 'third-first' AND value = 'satellite-captured') OR
            NOT EXISTS (SELECT 1 FROM public.e2e72_log
                WHERE marker = 'third-second' AND value = current_database()) OR
            EXISTS (SELECT 1 FROM public.e2e72_log
                WHERE database_name <> current_database() OR role_name <> 'df_e2e_user') THEN
            RAISE EXCEPTION 'TEST FAILED [third target]: wrong writes, variables, or execution identity';
        END IF;
    END $check$;
$remote$);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.e2e72_log) OR
        EXISTS (SELECT 1 FROM df.instances WHERE label IN ('e2e72-third-target', 'e2e72-quoted-local')) OR
        EXISTS (SELECT 1 FROM df.vars WHERE name = 'e2e72_value') THEN
        RAISE EXCEPTION 'TEST FAILED [control isolation]: satellite state leaked into control';
    END IF;
END $$;

-- === Same local ID in two satellites and control; metadata-only shadows, no engine forgery ===

SELECT dblink_exec('e2e72_origin', $remote$
    INSERT INTO e2e72_state SELECT 'collision', df.start(
        (df.wait_for_signal('e2e72-release', 120) |=> 'payload')
        ~> 'INSERT INTO public.e2e72_log (marker, value) VALUES (''released'', $payload::jsonb->''data''->>''source'')',
        'e2e72-collision-owner'
    );
$remote$);
SELECT dblink_exec('e2e72_origin', $remote$
    DO $wait$
    DECLARE
        local_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'collision');
        waiting BOOLEAN := false;
    BEGIN
        FOR attempt IN 1..300 LOOP
            SELECT EXISTS (SELECT 1 FROM df.nodes
                WHERE instance_id = local_id AND node_type = 'SIGNAL' AND status = 'running') INTO waiting;
            EXIT WHEN waiting;
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF NOT waiting OR df.status(local_id) IS DISTINCT FROM 'running' THEN
            RAISE EXCEPTION 'TEST FAILED [collision setup]: owner did not reach signal wait';
        END IF;
    END $wait$;
$remote$);

CREATE TEMP TABLE _e2e72_collision AS
SELECT instance_id FROM dblink('e2e72_origin',
    'SELECT instance_id FROM e2e72_state WHERE scenario = ''collision''') AS remote(instance_id TEXT);
GRANT SELECT ON _e2e72_collision TO df_e2e_user;

DO $$
DECLARE
    local_id TEXT := (SELECT instance_id FROM _e2e72_collision);
BEGIN
    IF local_id IS NULL OR local_id !~ '^[0-9a-f]{8}$' THEN
        RAISE EXCEPTION 'TEST FAILED [collision setup]: missing public local ID';
    END IF;
    INSERT INTO df.instances (id, root_node, submitted_by, status, label)
        VALUES (local_id, '00000072', 'df_e2e_user'::regrole, 'completed', 'e2e72-shadow');
    INSERT INTO df.nodes (id, instance_id, node_type, query, submitted_by, status, result)
        VALUES ('00000072', local_id, 'SQL', 'SELECT ''control-shadow''',
            'df_e2e_user'::regrole, 'completed', '"control-shadow"'::jsonb);
    PERFORM dblink_exec('e2e72_peer', 'RESET SESSION AUTHORIZATION');
    PERFORM dblink_exec('e2e72_peer', format($remote$
        BEGIN;
        INSERT INTO e2e72_state VALUES ('shadow', %1$L);
        INSERT INTO df.instances (id, root_node, submitted_by, status, label)
            VALUES (%1$L, '00000072', 'postgres'::regrole, 'completed', 'e2e72-shadow');
        INSERT INTO df.nodes (id, instance_id, node_type, query, submitted_by, status, result)
            VALUES ('00000072', %1$L, 'SQL', 'SELECT ''peer-shadow''',
                'postgres'::regrole, 'completed', '"peer-shadow"'::jsonb);
        COMMIT;
        SET SESSION AUTHORIZATION df_e2e_user;
    $remote$, local_id));
END $$;

SELECT dblink_exec('e2e72_peer', $remote$
    DO $check$
    DECLARE
        local_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'shadow');
        denied BOOLEAN := false;
    BEGIN
        IF EXISTS (SELECT 1 FROM df.instances WHERE id = local_id) OR
            EXISTS (SELECT 1 FROM df.nodes WHERE instance_id = local_id) OR
            EXISTS (SELECT 1 FROM df.instance_info(local_id)) OR
            EXISTS (SELECT 1 FROM df.instance_executions(local_id)) OR
            EXISTS (SELECT 1 FROM df.list_instances() WHERE instance_id = local_id) OR
            df.status(local_id) IS NOT NULL OR df.result(local_id) IS NOT NULL THEN
            RAISE EXCEPTION 'TEST FAILED [satellite RLS]: unowned metadata or provider history leaked';
        END IF;
        BEGIN
            PERFORM df.signal(local_id, 'e2e72-release', '{"source":"rls-denied"}');
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM IS DISTINCT FROM 'Instance not found or access denied: ' || local_id THEN
                RAISE;
            END IF;
            denied := true;
        END;
        IF NOT denied THEN
            RAISE EXCEPTION 'TEST FAILED [satellite RLS]: unowned signal accepted';
        END IF;
        denied := false;
        BEGIN
            PERFORM df.cancel(local_id, 'e2e72 RLS probe');
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM IS DISTINCT FROM 'Instance not found or access denied: ' || local_id THEN
                RAISE;
            END IF;
            denied := true;
        END;
        IF NOT denied THEN
            RAISE EXCEPTION 'TEST FAILED [satellite RLS]: unowned cancellation accepted';
        END IF;
    END $check$;
$remote$);

SELECT dblink_exec('e2e72_peer', $remote$
    RESET SESSION AUTHORIZATION;
    BEGIN;
    UPDATE df.instances SET submitted_by = 'df_e2e_user'::regrole WHERE label = 'e2e72-shadow';
    UPDATE df.nodes SET submitted_by = 'df_e2e_user'::regrole
        WHERE instance_id = (SELECT instance_id FROM e2e72_state WHERE scenario = 'shadow');
    COMMIT;
    SET SESSION AUTHORIZATION df_e2e_user;
$remote$);
SELECT dblink_exec('e2e72_peer', $remote$
    DO $check$
    DECLARE
        local_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'shadow');
        cancel_result TEXT;
    BEGIN
        IF df.status(local_id) IS DISTINCT FROM 'completed' OR
            df.result(local_id)::jsonb IS DISTINCT FROM '"peer-shadow"'::jsonb THEN
            RAISE EXCEPTION 'TEST FAILED [peer shadow]: local metadata/result did not stay local';
        END IF;
        IF EXISTS (SELECT 1 FROM df.instance_info(local_id)) OR
            EXISTS (SELECT 1 FROM df.instance_executions(local_id)) THEN
            RAISE EXCEPTION 'TEST FAILED [peer shadow]: resolved another installation engine';
        END IF;
        PERFORM df.signal(local_id, 'e2e72-release', '{"source":"wrong-peer"}');
        cancel_result := df.cancel(local_id, 'e2e72 peer shadow cancellation');
        IF cancel_result IS DISTINCT FROM format('Instance %s cancelled: e2e72 peer shadow cancellation', local_id) THEN
            RAISE EXCEPTION 'TEST FAILED [peer shadow cancellation]: %', cancel_result;
        END IF;
    END $check$;
$remote$);

SET SESSION AUTHORIZATION df_e2e_user;
DO $$
DECLARE
    local_id TEXT := (SELECT instance_id FROM _e2e72_collision);
    cancel_result TEXT;
BEGIN
    IF df.status(local_id) IS DISTINCT FROM 'completed' OR
        df.result(local_id)::jsonb IS DISTINCT FROM '"control-shadow"'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED [control shadow]: local metadata/result did not stay local';
    END IF;
    IF EXISTS (SELECT 1 FROM df.instance_info(local_id)) OR
        EXISTS (SELECT 1 FROM df.instance_executions(local_id)) THEN
        RAISE EXCEPTION 'TEST FAILED [control shadow]: resolved a satellite engine';
    END IF;
    PERFORM df.signal(local_id, 'e2e72-release', '{"source":"wrong-control"}');
    cancel_result := df.cancel(local_id, 'e2e72 control shadow cancellation');
    IF cancel_result IS DISTINCT FROM format('Instance %s cancelled: e2e72 control shadow cancellation', local_id) THEN
        RAISE EXCEPTION 'TEST FAILED [control shadow cancellation]: %', cancel_result;
    END IF;
END $$;
RESET SESSION AUTHORIZATION;

SELECT dblink_exec('e2e72_origin', $remote$
    DO $release$
    DECLARE
        local_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'collision');
    BEGIN
        IF df.status(local_id) IS DISTINCT FROM 'running' OR
            NOT EXISTS (SELECT 1 FROM df.instance_info(local_id) WHERE status = 'running') THEN
            RAISE EXCEPTION 'TEST FAILED [owner isolation]: foreign shadow disturbed live owner';
        END IF;
        FOR attempt IN 1..300 LOOP
            EXIT WHEN df.status(local_id) IN ('completed', 'failed', 'cancelled');
            PERFORM df.signal(local_id, 'e2e72-release', '{"source":"owner"}');
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF df.await_instance(local_id, 10) IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [owner isolation]: foreign cancellation reached owner';
        END IF;
    END $release$;
$remote$);
SELECT dblink_exec('e2e72_origin', $remote$
    DO $check$
    DECLARE
        local_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'collision');
    BEGIN
        IF (SELECT count(*) FROM public.e2e72_log) <> 1 OR NOT EXISTS (
            SELECT 1 FROM public.e2e72_log WHERE marker = 'released' AND value = 'owner'
                AND database_name = current_database() AND role_name = 'df_e2e_user'
        ) OR NOT EXISTS (SELECT 1 FROM df.instance_info(local_id) WHERE status = 'completed') OR
            NOT EXISTS (SELECT 1 FROM df.instance_executions(local_id)) THEN
            RAISE EXCEPTION 'TEST FAILED [owner isolation]: wrong signal payload, effects, or engine history';
        END IF;
    END $check$;
$remote$);

BEGIN;
DELETE FROM df.nodes WHERE instance_id IN (SELECT instance_id FROM _e2e72_collision);
DELETE FROM df.instances WHERE id IN (SELECT instance_id FROM _e2e72_collision) AND label = 'e2e72-shadow';
COMMIT;
SELECT dblink_exec('e2e72_peer', $remote$
    RESET SESSION AUTHORIZATION;
    BEGIN;
    DELETE FROM df.nodes WHERE instance_id = (SELECT instance_id FROM e2e72_state WHERE scenario = 'shadow');
    DELETE FROM df.instances WHERE label = 'e2e72-shadow';
    COMMIT;
    SET SESSION AUTHORIZATION df_e2e_user;
$remote$);

-- === Reinstall during a persisted timer: cached old graph must not reach the replacement ===

SELECT dblink_exec('e2e72_origin', $remote$
    INSERT INTO e2e72_state SELECT 'old-timer', df.start(
        'INSERT INTO public.e2e72_log (marker, value) VALUES (''armed'', ''old-installation'')'
        ~> df.sleep(10)
        ~> 'INSERT INTO public.e2e72_log (marker, value) VALUES (''stale-write'', ''old-installation'')',
        'e2e72-old-timer'
    );
$remote$);
SELECT dblink_exec('e2e72_origin', $remote$
    DO $wait$
    DECLARE
        local_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'old-timer');
        waiting BOOLEAN := false;
    BEGIN
        FOR attempt IN 1..300 LOOP
            SELECT EXISTS (SELECT 1 FROM df.nodes
                WHERE instance_id = local_id AND node_type = 'SLEEP' AND status = 'running') INTO waiting;
            EXIT WHEN waiting;
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF NOT waiting OR df.status(local_id) IS DISTINCT FROM 'running' THEN
            RAISE EXCEPTION 'TEST FAILED [reinstall setup]: old graph did not reach its timer';
        END IF;
    END $wait$;
$remote$);
SELECT dblink_exec('e2e72_origin', $remote$
    DO $check$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM public.e2e72_log WHERE marker = 'armed' AND value = 'old-installation') OR
            EXISTS (SELECT 1 FROM public.e2e72_log WHERE marker = 'stale-write') THEN
            RAISE EXCEPTION 'TEST FAILED [reinstall setup]: old graph not armed before replacement';
        END IF;
    END $check$;
    CREATE TEMP TABLE e2e72_old AS
    SELECT to_jsonb(instance) AS instance_row,
        (SELECT jsonb_agg(to_jsonb(node) ORDER BY node.id) FROM df.nodes AS node
            WHERE node.instance_id = instance.id) AS node_rows,
        (SELECT id FROM df._installation WHERE singleton) AS installation_id,
        (SELECT oid FROM pg_database WHERE datname = current_database()) AS database_oid
    FROM df.instances AS instance
    WHERE id = (SELECT instance_id FROM e2e72_state WHERE scenario = 'old-timer');
$remote$);

CREATE TEMP TABLE _e2e72_old AS
SELECT *, NULL::TEXT AS engine_id FROM dblink('e2e72_origin',
    'SELECT instance_row->>''id'', installation_id, database_oid FROM e2e72_old'
) AS remote(local_id TEXT, installation_id UUID, database_oid OID);

DO $$
DECLARE
    old_identity RECORD;
    provider_schema TEXT := df.duroxide_schema();
    actual_engine_id TEXT;
    timer_waiting BOOLEAN := false;
BEGIN
    SELECT * INTO STRICT old_identity FROM _e2e72_old;
    FOR attempt IN 1..300 LOOP
        EXECUTE format('SELECT instance_id FROM %I.instances WHERE instance_id = $1', provider_schema)
            INTO actual_engine_id USING format('pgdf-%s-%s-%s', old_identity.database_oid,
                replace(old_identity.installation_id::text, '-', ''), old_identity.local_id);
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %1$I.history WHERE instance_id = $1
                AND event_data::jsonb->>''type'' = ''TimerCreated'')
                AND NOT EXISTS (SELECT 1 FROM %1$I.history WHERE instance_id = $1
                AND event_data::jsonb->>''type'' = ''TimerFired'')', provider_schema
        ) INTO timer_waiting USING actual_engine_id;
        EXIT WHEN actual_engine_id IS NOT NULL AND timer_waiting;
        PERFORM pg_sleep(0.1);
    END LOOP;
    IF actual_engine_id IS NULL OR NOT timer_waiting THEN
        RAISE EXCEPTION 'TEST FAILED [reinstall setup]: no persisted unfired timer for old engine';
    END IF;
    UPDATE _e2e72_old SET engine_id = actual_engine_id;
END $$;

SELECT dblink_exec('e2e72_origin', $remote$
    RESET SESSION AUTHORIZATION;
    BEGIN;
    DROP EXTENSION pg_durable CASCADE;
    DROP TABLE public.e2e72_log;
    CREATE EXTENSION pg_durable;
    DO $grant$ BEGIN PERFORM df.grant_usage('df_e2e_user'); END $grant$;
    CREATE TABLE public.e2e72_log (
        marker TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        database_name TEXT NOT NULL DEFAULT current_database(),
        role_name TEXT NOT NULL DEFAULT current_user
    );
    GRANT SELECT, INSERT ON public.e2e72_log TO df_e2e_user;
    DO $identity$
    BEGIN
        IF (SELECT oid FROM pg_database WHERE datname = current_database()) IS DISTINCT FROM
            (SELECT database_oid FROM e2e72_old) OR
            (SELECT id FROM df._installation WHERE singleton) IS NOT DISTINCT FROM
            (SELECT installation_id FROM e2e72_old) THEN
            RAISE EXCEPTION 'TEST FAILED [reinstall identity]: expected same database OID and new installation UUID';
        END IF;
    END $identity$;
    INSERT INTO df.instances
    SELECT (jsonb_populate_record(NULL::df.instances, instance_row || jsonb_build_object(
        'status', 'completed', 'label', 'e2e72-replacement-shadow',
        'created_at', now(), 'updated_at', now(), 'completed_at', now()
    ))).* FROM e2e72_old;
    INSERT INTO df.nodes
    SELECT (jsonb_populate_record(NULL::df.nodes, saved.node_row || jsonb_build_object(
        'status', 'completed', 'result', 'replacement-sentinel', 'error', NULL,
        'status_details', NULL, 'created_at', now(), 'updated_at', now()
    ))).* FROM e2e72_old CROSS JOIN LATERAL jsonb_array_elements(node_rows) AS saved(node_row);
    CREATE TEMP TABLE e2e72_replacement_snapshot AS
    SELECT to_jsonb(instance) AS instance_row,
        (SELECT jsonb_agg(to_jsonb(node) ORDER BY node.id) FROM df.nodes AS node
            WHERE node.instance_id = instance.id) AS node_rows
    FROM df.instances AS instance WHERE label = 'e2e72-replacement-shadow';
    GRANT SELECT ON e2e72_replacement_snapshot TO df_e2e_user;
    COMMIT;
    SET SESSION AUTHORIZATION df_e2e_user;
$remote$);

SELECT dblink_exec('e2e72_origin', $remote$
    INSERT INTO e2e72_state SELECT 'replacement-new', df.start(
        'INSERT INTO public.e2e72_log (marker, value) VALUES (''replacement-new'', ''new-installation'')',
        'e2e72-replacement-new'
    );
$remote$);
SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _e2e72_control AS SELECT df.start(
    'INSERT INTO public.e2e72_log (marker, value) VALUES (''control-new'', ''control'')',
    'e2e72-control-after-reinstall'
) AS instance_id;
DO $$
BEGIN
    IF df.await_instance((SELECT instance_id FROM _e2e72_control), 30) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [reinstall control]: control work did not complete';
    END IF;
END $$;
RESET SESSION AUTHORIZATION;
SELECT dblink_exec('e2e72_origin', $remote$
    DO $await$
    BEGIN
        IF df.await_instance((SELECT instance_id FROM e2e72_state WHERE scenario = 'replacement-new'), 30)
            IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [reinstall new work]: replacement work did not complete';
        END IF;
    END $await$;
$remote$);

DO $$
DECLARE
    old_engine_id TEXT := (SELECT engine_id FROM _e2e72_old);
    provider_schema TEXT := df.duroxide_schema();
    engine_status TEXT;
    engine_output TEXT;
    timer_fired BOOLEAN;
BEGIN
    FOR attempt IN 1..1300 LOOP
        EXECUTE format('SELECT status, output FROM %I.get_instance_info($1)', provider_schema)
            INTO engine_status, engine_output USING old_engine_id;
        EXIT WHEN lower(engine_status) IN ('completed', 'failed', 'cancelled');
        PERFORM pg_sleep(0.1);
    END LOOP;
    IF lower(engine_status) IS DISTINCT FROM 'failed' OR
        position('Origin installation removed or replaced' IN coalesce(engine_output, '')) = 0 THEN
        RAISE EXCEPTION 'TEST FAILED [old engine]: expected replaced-installation failure for %, status=%, output=%',
            old_engine_id, engine_status, engine_output;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.history WHERE instance_id = $1
        AND event_data::jsonb->>''type'' = ''TimerFired'')', provider_schema)
        INTO timer_fired USING old_engine_id;
    IF NOT timer_fired THEN
        RAISE EXCEPTION 'TEST FAILED [old engine]: old cached graph never resumed after its timer';
    END IF;
END $$;

SELECT dblink_exec('e2e72_origin', $remote$
    DO $check$
    DECLARE
        old_id TEXT := (SELECT instance_row->>'id' FROM e2e72_old);
        new_id TEXT := (SELECT instance_id FROM e2e72_state WHERE scenario = 'replacement-new');
    BEGIN
        IF (SELECT count(*) FROM public.e2e72_log) <> 1 OR NOT EXISTS (
            SELECT 1 FROM public.e2e72_log WHERE marker = 'replacement-new' AND value = 'new-installation'
                AND database_name = current_database() AND role_name = 'df_e2e_user'
        ) THEN
            RAISE EXCEPTION 'TEST FAILED [replacement effects]: old graph touched the replacement table';
        END IF;
        IF (SELECT to_jsonb(instance) FROM df.instances AS instance WHERE id = old_id) IS DISTINCT FROM
                (SELECT instance_row FROM e2e72_replacement_snapshot) OR
            (SELECT jsonb_agg(to_jsonb(node) ORDER BY node.id) FROM df.nodes AS node WHERE instance_id = old_id)
                IS DISTINCT FROM (SELECT node_rows FROM e2e72_replacement_snapshot) THEN
            RAISE EXCEPTION 'TEST FAILED [replacement metadata]: old engine mutated new installation rows';
        END IF;
        IF EXISTS (SELECT 1 FROM df.instance_info(old_id)) OR
            EXISTS (SELECT 1 FROM df.instance_executions(old_id)) OR
            NOT EXISTS (SELECT 1 FROM df.instance_info(new_id) WHERE status = 'completed') THEN
            RAISE EXCEPTION 'TEST FAILED [replacement namespace]: lookup crossed installation UUIDs';
        END IF;
    END $check$;
$remote$);

DO $$
BEGIN
    IF (SELECT count(*) FROM public.e2e72_log) <> 1 OR NOT EXISTS (
        SELECT 1 FROM public.e2e72_log WHERE marker = 'control-new' AND value = 'control'
            AND database_name = current_database() AND role_name = 'df_e2e_user'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED [control effects]: satellite work touched control';
    END IF;
    IF (SELECT count(*) FROM _e2e72_epoch) <> 1 OR
        (SELECT epoch_id FROM df._worker_epoch) IS DISTINCT FROM (SELECT epoch_id FROM _e2e72_epoch) THEN
        RAISE EXCEPTION 'TEST FAILED [control epoch]: satellite reinstall restarted the control runtime';
    END IF;
END $$;

-- === Cleanup: only this file's fixtures ===

SELECT dblink_disconnect(connection_name) FROM _e2e72_databases;
DROP DATABASE _e2e72_origin WITH (FORCE);
DROP DATABASE "_e2e72 satellite ""peer""" WITH (FORCE);
DROP DATABASE _e2e72_target WITH (FORCE);
DROP TABLE public.e2e72_log;
DROP TABLE _e2e72_databases, _e2e72_epoch, _e2e72_collision, _e2e72_old, _e2e72_control;

SELECT 'TEST PASSED: multi-database lifecycle' AS result;