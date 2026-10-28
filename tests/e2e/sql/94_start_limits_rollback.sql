-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

DO $$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['quota_rollback_tx', 'quota_rollback_sp', 'quota_rollback_atomic'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('DROP OWNED BY %I', role_name);
            EXECUTE format('DROP ROLE %I', role_name);
        END IF;
    END LOOP;
END $$;
CREATE ROLE quota_rollback_tx LOGIN;
CREATE ROLE quota_rollback_sp LOGIN;
CREATE ROLE quota_rollback_atomic LOGIN;
SELECT df.grant_usage(role_name)
FROM (VALUES ('quota_rollback_tx'), ('quota_rollback_sp'), ('quota_rollback_atomic')) AS roles(role_name);
SELECT format('ALTER ROLE %I IN DATABASE %I SET df.max_concurrent_per_user = 2',
              role_name, current_database())
FROM (VALUES ('quota_rollback_tx'), ('quota_rollback_sp'), ('quota_rollback_atomic')) AS roles(role_name) \gexec
SELECT format('ALTER ROLE %I IN DATABASE %I SET df.max_instances_per_user = 3',
              role_name, current_database())
FROM (VALUES ('quota_rollback_tx'), ('quota_rollback_sp'), ('quota_rollback_atomic')) AS roles(role_name) \gexec

CREATE TEMP TABLE _rollback_ids (owner_name TEXT, id TEXT);

CREATE FUNCTION pg_temp.expect_rollback_quota(conn TEXT, kind TEXT, n INT, mode TEXT DEFAULT 'caller')
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM dblink_exec(conn, format($remote$
        DO $reject$
        DECLARE
            hint TEXT;
        BEGIN
            BEGIN
                PERFORM df.start('SELECT 1', 'quota-rollback-rejected', NULL, %1$L);
                RAISE EXCEPTION 'TEST FAILED: rollback bypassed %2$s quota';
            EXCEPTION WHEN configuration_limit_exceeded THEN
                GET STACKED DIAGNOSTICS hint = PG_EXCEPTION_HINT;
                IF SQLERRM NOT LIKE '%%has %3$s %2$s instances (limit %3$s)%%'
                   OR hint IS NULL OR hint = '' THEN
                    RAISE EXCEPTION 'TEST FAILED: unexpected quota diagnostics: %%, %%', SQLERRM, hint;
                END IF;
            END;
        END $reject$;
    $remote$, mode, kind, n));
END $$;

DO $$
DECLARE
    role_name TEXT;
    inst TEXT;
    mode TEXT;
    count_rows BIGINT;
    is_savepoint BOOLEAN;
    connbase TEXT := format('host=localhost dbname=%L port=%s',
                            current_database(), current_setting('port'));
BEGIN
    PERFORM dblink_connect('quota_rollback_fence', connbase || ' user=postgres');
    FOREACH role_name IN ARRAY ARRAY['quota_rollback_tx', 'quota_rollback_sp'] LOOP
        is_savepoint := role_name = 'quota_rollback_sp';
        PERFORM dblink_connect(role_name, connbase || ' user=' || role_name);
        PERFORM dblink_exec(role_name, 'SET statement_timeout = ''15s''');
        PERFORM dblink_exec('quota_rollback_fence', format(
            'BEGIN; LOCK TABLE %I.instances IN SHARE MODE', df.duroxide_schema()));
        IF is_savepoint THEN
            PERFORM dblink_exec(role_name, 'BEGIN');
        END IF;
        FOR attempt IN 1..2 LOOP
            PERFORM dblink_exec(role_name, CASE WHEN is_savepoint THEN 'SAVEPOINT submission' ELSE 'BEGIN' END);
            SELECT id INTO inst FROM dblink(role_name,
                'SELECT df.start(''SELECT 1'', ''quota-rollback-accepted'')') AS started(id TEXT);
            INSERT INTO _rollback_ids VALUES (role_name, inst);
            PERFORM dblink_exec(role_name, CASE WHEN is_savepoint
                THEN 'ROLLBACK TO submission; RELEASE submission' ELSE 'ROLLBACK' END);
        END LOOP;

        FOR attempt IN 1..3 LOOP
            PERFORM pg_temp.expect_rollback_quota(role_name, 'active', 2);
        END LOOP;
        IF is_savepoint THEN
            PERFORM dblink_exec(role_name, 'COMMIT');
        END IF;
        IF EXISTS (SELECT 1 FROM df.instances WHERE submitted_by = role_name::regrole) THEN
            RAISE EXCEPTION 'TEST FAILED: rollback left visible df rows';
        END IF;
        EXECUTE format('SELECT count(*) FROM %I._submissions WHERE submitted_by = $1', df.duroxide_schema())
            INTO count_rows USING role_name::regrole::oid;
        IF count_rows <> 2 THEN
            RAISE EXCEPTION 'TEST FAILED: expected two protected rollback charges, got %', count_rows;
        END IF;
        EXECUTE format('SELECT count(*) FROM %I.orchestrator_queue WHERE work_item LIKE $1', df.duroxide_schema())
            INTO count_rows USING '%quota-rollback-rejected%';
        IF count_rows <> 0 THEN
            RAISE EXCEPTION 'TEST FAILED: over-quota rollback attempt enqueued work';
        END IF;
        PERFORM dblink_exec('quota_rollback_fence', 'COMMIT');
        PERFORM public._e2e_wait_for_engine_terminal(id) FROM _rollback_ids AS saved WHERE saved.owner_name = role_name;

        -- Terminal orphan histories no longer use active capacity but still
        -- consume the retained quota, in both caller and separate-session mode.
        PERFORM dblink_exec(role_name, 'BEGIN');
        SELECT id INTO inst FROM dblink(role_name,
            'SELECT df.start(''SELECT 1'', ''quota-rollback-retained'')') AS started(id TEXT);
        INSERT INTO _rollback_ids VALUES (role_name, inst);
        PERFORM dblink_exec(role_name, 'ROLLBACK');
        PERFORM public._e2e_wait_for_engine_terminal(inst);
        FOREACH mode IN ARRAY ARRAY['caller', 'new'] LOOP
            FOR attempt IN 1..3 LOOP
                PERFORM pg_temp.expect_rollback_quota(role_name, 'retained', 3, mode);
            END LOOP;
        END LOOP;
        EXECUTE format('SELECT count(*) FROM %I._submissions WHERE submitted_by = $1', df.duroxide_schema())
            INTO count_rows USING role_name::regrole::oid;
        IF count_rows <> 3 THEN
            RAISE EXCEPTION 'TEST FAILED: rejected attempts altered protected accounting';
        END IF;
        PERFORM dblink_disconnect(role_name);
    END LOOP;

    -- An enqueue failure must roll back its ledger write on the same connection.
    PERFORM dblink_connect('quota_rollback_atomic', connbase || ' user=quota_rollback_atomic');
    PERFORM dblink_exec('quota_rollback_fence', format(
        'BEGIN; LOCK TABLE %I.orchestrator_queue IN SHARE MODE', df.duroxide_schema()));
    PERFORM dblink_exec('quota_rollback_atomic', $remote$
        DO $failure$
        BEGIN
            BEGIN
                PERFORM df.start('SELECT 1', 'quota-rollback-enqueue-failed');
                RAISE EXCEPTION 'TEST FAILED: enqueue fence did not block';
            EXCEPTION WHEN internal_error THEN
                IF SQLERRM NOT LIKE '%Failed to enqueue durable submission:%lock timeout%' THEN
                    RAISE;
                END IF;
            END;
        END $failure$;
    $remote$);
    PERFORM dblink_exec('quota_rollback_fence', 'COMMIT');
    EXECUTE format('SELECT count(*) FROM %I._submissions WHERE submitted_by = $1', df.duroxide_schema())
        INTO count_rows USING 'quota_rollback_atomic'::regrole::oid;
    IF count_rows <> 0 OR EXISTS (SELECT 1 FROM df.instances WHERE label = 'quota-rollback-enqueue-failed') THEN
        RAISE EXCEPTION 'TEST FAILED: failed enqueue retained accounting or metadata';
    END IF;
    SELECT id INTO inst FROM dblink('quota_rollback_atomic', 'SELECT df.start(''SELECT 1'')') AS started(id TEXT);
    PERFORM public._e2e_wait_for_engine_terminal(inst);
    PERFORM dblink_disconnect('quota_rollback_atomic');
    PERFORM dblink_disconnect('quota_rollback_fence');
END $$;

DO $$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['quota_rollback_tx', 'quota_rollback_sp', 'quota_rollback_atomic'] LOOP
        IF has_table_privilege(role_name, format('%I._submissions', df.duroxide_schema()),
                               'SELECT, INSERT, UPDATE, DELETE, TRUNCATE') THEN
            RAISE EXCEPTION 'TEST FAILED: ordinary user can access protected submission accounting';
        END IF;
    END LOOP;
END $$;
DROP TABLE _rollback_ids;
DROP FUNCTION pg_temp.expect_rollback_quota(TEXT, TEXT, INT, TEXT);
DROP OWNED BY quota_rollback_tx, quota_rollback_sp, quota_rollback_atomic;
DROP ROLE quota_rollback_tx, quota_rollback_sp, quota_rollback_atomic;
SELECT 'TEST PASSED' AS result;
