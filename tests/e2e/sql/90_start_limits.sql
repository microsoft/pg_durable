-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

DROP SCHEMA IF EXISTS start_limits_test CASCADE;
DO $$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['start_limits_user', 'start_limits_new_user'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('DROP OWNED BY %I', role_name);
            EXECUTE format('DROP ROLE %I', role_name);
        END IF;
    END LOOP;
END $$;
CREATE ROLE start_limits_user LOGIN;
CREATE ROLE start_limits_new_user LOGIN;
SELECT df.grant_usage('start_limits_user');
SELECT df.grant_usage('start_limits_new_user');
CREATE SCHEMA start_limits_test;
GRANT USAGE ON SCHEMA start_limits_test TO start_limits_user, start_limits_new_user;
CREATE TABLE start_limits_test.ids (kind TEXT, id TEXT);
GRANT SELECT, INSERT ON start_limits_test.ids TO start_limits_user, start_limits_new_user;

CREATE FUNCTION start_limits_test.expect_rejected(kind TEXT, n BIGINT, mode TEXT DEFAULT 'caller')
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    hint TEXT;
    instance_count BIGINT := (SELECT count(*) FROM df.instances);
    node_count BIGINT := (SELECT count(*) FROM df.nodes);
    guc TEXT := CASE WHEN kind = 'active' THEN 'df.max_concurrent_per_user'
                    ELSE 'df.max_instances_per_user' END;
BEGIN
    BEGIN
        PERFORM df.start('SELECT 1', 'start-limits-rejected', transaction_mode => mode);
        RAISE EXCEPTION 'TEST FAILED: over-quota start succeeded';
    EXCEPTION WHEN configuration_limit_exceeded THEN
        GET STACKED DIAGNOSTICS hint = PG_EXCEPTION_HINT;
        IF position(format('user "%s" has %s %s instances (limit %s)', current_user, n, kind, n)
                    IN SQLERRM) = 0 OR position(guc IN hint) = 0 OR hint IS NULL THEN
            RAISE EXCEPTION 'TEST FAILED: incorrect quota diagnostics: %, hint %', SQLERRM, hint;
        END IF;
    END;
    IF (SELECT count(*) FROM df.instances) <> instance_count OR
       (SELECT count(*) FROM df.nodes) <> node_count THEN
        RAISE EXCEPTION 'TEST FAILED: rejected start persisted metadata';
    END IF;
END $$;

DO $$
DECLARE
    setting RECORD;
BEGIN
    FOR setting IN SELECT name, boot_val, context, min_val, max_val FROM pg_settings
                   WHERE name IN ('df.max_concurrent_per_user', 'df.max_instances_per_user')
    LOOP
        IF setting.context <> 'superuser' OR setting.min_val <> '0' OR
           setting.max_val <> '2147483647' OR setting.boot_val <>
           (CASE setting.name WHEN 'df.max_concurrent_per_user' THEN '100' ELSE '10000' END) THEN
            RAISE EXCEPTION 'TEST FAILED: incorrect quota GUC definition: %', setting;
        END IF;
        BEGIN
            PERFORM set_config(setting.name, '-1', true);
            RAISE EXCEPTION 'TEST FAILED: negative quota accepted';
        EXCEPTION WHEN invalid_parameter_value THEN NULL;
        END;
    END LOOP;
    IF (SELECT count(*) FROM pg_settings
        WHERE name IN ('df.max_concurrent_per_user', 'df.max_instances_per_user')) <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: quota GUC missing';
    END IF;
END $$;

SET df.max_concurrent_per_user = 2;
SET df.max_instances_per_user = 0;
SET ROLE start_limits_user;
DO $$
DECLARE
    guc TEXT;
BEGIN
    FOREACH guc IN ARRAY ARRAY['df.max_concurrent_per_user', 'df.max_instances_per_user'] LOOP
        BEGIN
            PERFORM set_config(guc, '0', false);
            RAISE EXCEPTION 'TEST FAILED: unprivileged role changed %', guc;
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
    END LOOP;
END $$;

-- Both calls share a transaction, so the second must count the first's rows.
INSERT INTO start_limits_test.ids
SELECT 'initial', df.start(df.sleep(300), 'start-limits-initial') FROM generate_series(1, 2);
RESET ROLE;

-- Enqueue remains possible, but acknowledgment cannot create an engine instance
-- and consume its queue item while this lock is held.
BEGIN;
DO $$
BEGIN
    EXECUTE format('LOCK TABLE %I.instances IN SHARE MODE', df.duroxide_schema());
END $$;
SET ROLE start_limits_user;
SELECT start_limits_test.expect_rejected('active', 2);
RESET ROLE;
DO $$
DECLARE
    actual BIGINT;
BEGIN
    EXECUTE format(
        'SELECT count(*) FROM %I.orchestrator_queue WHERE work_item LIKE $1',
        df.duroxide_schema()
    ) INTO actual USING '%start-limits-rejected%';
    IF actual <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: rejected start enqueued engine work';
    END IF;
END $$;
COMMIT;

SET ROLE start_limits_user;
DO $$
BEGIN
    PERFORM df.cancel((SELECT id FROM start_limits_test.ids WHERE kind = 'initial' LIMIT 1));
    PERFORM public._e2e_wait_for_engine_terminal(
        (SELECT id FROM start_limits_test.ids WHERE kind = 'initial' LIMIT 1));
    INSERT INTO start_limits_test.ids
    SELECT 'completed', df.start('SELECT 1', 'start-limits-replacement');
END $$;
DO $$
BEGIN
    IF df.await_instance((SELECT id FROM start_limits_test.ids WHERE kind = 'completed'), 30)
       IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: replacement did not complete';
    END IF;
END $$;
SELECT public._e2e_wait_for_engine_terminal(id) FROM start_limits_test.ids WHERE kind = 'completed';
INSERT INTO start_limits_test.ids SELECT 'after-completion', df.start(df.sleep(300));
SELECT start_limits_test.expect_rejected('active', 2);
SELECT df.cancel(id) FROM df.instances WHERE status IN ('pending', 'running');
RESET ROLE;

-- All four retained rows are terminal; completing/cancelling does not free storage quota.
SET df.max_concurrent_per_user = 0;
SET df.max_instances_per_user = 4;
SET ROLE start_limits_user;
SELECT start_limits_test.expect_rejected('retained', 4);
RESET ROLE;

CREATE FUNCTION start_limits_test.start_as_owner() RETURNS TEXT
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$ SELECT df.start('SELECT 1') $$;
ALTER FUNCTION start_limits_test.start_as_owner() OWNER TO start_limits_user;
SET ROLE start_limits_new_user;
DO $$
BEGIN
    BEGIN
        PERFORM start_limits_test.start_as_owner();
        RAISE EXCEPTION 'TEST FAILED: SECURITY DEFINER bypassed owner quota';
    EXCEPTION WHEN configuration_limit_exceeded THEN
        IF SQLERRM NOT LIKE '%user "start_limits_user" has 4 retained instances%' THEN
            RAISE;
        END IF;
    END;
END $$;
RESET ROLE;

-- The loopback session uses role/database defaults, not these caller SET values.
SELECT format('ALTER ROLE start_limits_new_user IN DATABASE %I SET df.max_concurrent_per_user = 1',
              current_database()) \gexec
SELECT format('ALTER ROLE start_limits_new_user IN DATABASE %I SET df.max_instances_per_user = 2',
              current_database()) \gexec
SET df.max_concurrent_per_user = 0;
SET df.max_instances_per_user = 0;
SET ROLE start_limits_new_user;
INSERT INTO start_limits_test.ids
SELECT 'new-sleep', df.start(df.sleep(300), transaction_mode => 'new');
SELECT start_limits_test.expect_rejected('active', 1, 'new');
SELECT df.cancel(id) FROM start_limits_test.ids WHERE kind = 'new-sleep';
SELECT public._e2e_wait_for_engine_terminal(id) FROM start_limits_test.ids WHERE kind = 'new-sleep';
INSERT INTO start_limits_test.ids
SELECT 'new-completed', df.start('SELECT 1', transaction_mode => 'new');
DO $$
BEGIN
    IF df.await_instance((SELECT id FROM start_limits_test.ids WHERE kind = 'new-completed'), 30)
       IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: new-transaction instance did not complete';
    END IF;
END $$;
SELECT public._e2e_wait_for_engine_terminal(id) FROM start_limits_test.ids WHERE kind = 'new-completed';
SELECT start_limits_test.expect_rejected('retained', 2, 'new');
RESET ROLE;

-- Zero disables both limits, including admission locking.
SET ROLE start_limits_user;
BEGIN;
INSERT INTO start_limits_test.ids
SELECT 'unlimited', df.start(df.sleep(300)) FROM generate_series(1, 3);
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_locks WHERE pid = pg_backend_pid()
               AND locktype = 'advisory' AND classid = x'50474451'::int AND objsubid = 3) THEN
        RAISE EXCEPTION 'TEST FAILED: unlimited starts acquired a quota lock';
    END IF;
END $$;
COMMIT;
RESET ROLE;

SET df.max_concurrent_per_user = 1;
SET df.max_instances_per_user = 1;
INSERT INTO start_limits_test.ids
SELECT 'superuser', df.start(df.sleep(300)) FROM generate_series(1, 3);

SELECT df.cancel(id) FROM start_limits_test.ids;
DROP SCHEMA start_limits_test CASCADE;
DROP OWNED BY start_limits_user, start_limits_new_user;
DROP ROLE start_limits_user, start_limits_new_user;
RESET df.max_concurrent_per_user;
RESET df.max_instances_per_user;
SELECT 'TEST PASSED' AS result;
