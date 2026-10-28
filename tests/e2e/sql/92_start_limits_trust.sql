-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

DO $$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['quota_trust_user', 'quota_trust_attacker'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('DROP OWNED BY %I', role_name);
            EXECUTE format('DROP ROLE %I', role_name);
        END IF;
    END LOOP;
END $$;
CREATE ROLE quota_trust_user LOGIN;
CREATE ROLE quota_trust_attacker LOGIN;
SELECT df.grant_usage('quota_trust_user');
SELECT format('ALTER ROLE quota_trust_user IN DATABASE %I SET df.max_concurrent_per_user = 1',
              current_database()) \gexec
SELECT format('ALTER ROLE quota_trust_user IN DATABASE %I SET df.max_instances_per_user = 0',
              current_database()) \gexec
SELECT format('ALTER ROLE quota_trust_user IN DATABASE %I SET lock_timeout = ''500ms''',
              current_database()) \gexec

DO $$
DECLARE
    base_conn TEXT := format('host=localhost dbname=%L port=%s',
                             current_database(), current_setting('port'));
    instance TEXT;
    replacement TEXT;
    mode TEXT;
    forged_status TEXT;
    engine_status TEXT;
    victim_oid OID := 'quota_trust_user'::regrole;
BEGIN
    PERFORM dblink_connect('quota_trust_user', base_conn || ' user=quota_trust_user');
    PERFORM dblink_connect('quota_trust_attacker', base_conn || ' user=quota_trust_attacker');
    PERFORM dblink_connect('quota_trust_fence', base_conn || ' user=postgres');
    PERFORM dblink_exec('quota_trust_attacker', format($remote$
        DO $lock$
        BEGIN
            IF has_schema_privilege(current_user, 'df', 'USAGE') THEN
                RAISE EXCEPTION 'TEST SETUP ERROR: attacker must not have df usage';
            END IF;
            PERFORM pg_advisory_lock(x'50474451'::int, %1$s::int);
            PERFORM pg_advisory_lock((x'50474451'::bigint << 32) | %1$s::bigint);
        END $lock$;
    $remote$, victim_oid));

    FOREACH mode IN ARRAY ARRAY['caller', 'new'] LOOP
        PERFORM dblink_exec('quota_trust_fence', format(
            'BEGIN; LOCK TABLE %I.instances IN SHARE MODE', df.duroxide_schema()
        ));
        SELECT id INTO instance FROM dblink('quota_trust_user', format(
            'SELECT df.start(df.sleep(300), ''quota-trust-live'', NULL, %L)', mode
        )) AS started(id TEXT);
        EXECUTE format('SELECT status FROM %I.get_instance_info($1)', df.duroxide_schema())
            INTO engine_status USING instance;
        IF engine_status IS NOT NULL THEN
            RAISE EXCEPTION 'TEST FAILED: acknowledgment fence did not hold queued start';
        END IF;
        PERFORM dblink_exec('quota_trust_user', format($remote$
            DO $reject$
            BEGIN
                BEGIN
                    PERFORM df.start('SELECT 1', 'quota-trust-queued', NULL, %L);
                    RAISE EXCEPTION 'TEST FAILED: queued instance did not consume capacity';
                EXCEPTION WHEN configuration_limit_exceeded THEN NULL;
                END;
            END $reject$;
        $remote$, mode));
        PERFORM dblink_exec('quota_trust_fence', 'COMMIT');
        FOR attempt IN 1..300 LOOP
            EXECUTE format('SELECT status FROM %I.get_instance_info($1)', df.duroxide_schema())
                INTO engine_status USING instance;
            EXIT WHEN engine_status = 'Running';
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF engine_status IS DISTINCT FROM 'Running' THEN
            RAISE EXCEPTION 'TEST FAILED: % start blocked or did not run: %', mode, engine_status;
        END IF;

        FOREACH forged_status IN ARRAY ARRAY['completed', 'failed', 'cancelled'] LOOP
            PERFORM dblink_exec('quota_trust_user', format(
                'UPDATE df.instances SET status = %L WHERE id = %L', forged_status, instance
            ));
            PERFORM dblink_exec('quota_trust_user', format($remote$
                DO $reject$
                BEGIN
                    BEGIN
                        PERFORM df.start('SELECT 1', 'quota-trust-rejected', NULL, %L);
                        RAISE EXCEPTION 'TEST FAILED: forged status bypassed active quota';
                    EXCEPTION WHEN configuration_limit_exceeded THEN
                        IF SQLERRM NOT LIKE '%%has 1 active instances (limit 1)%%' THEN
                            RAISE;
                        END IF;
                    END;
                END $reject$;
            $remote$, mode));
            EXECUTE format('SELECT status FROM %I.get_instance_info($1)', df.duroxide_schema())
                INTO engine_status USING instance;
            IF engine_status IS DISTINCT FROM 'Running' THEN
                RAISE EXCEPTION 'TEST FAILED: forged display status changed live engine state';
            END IF;
        END LOOP;

        PERFORM dblink_exec('quota_trust_fence', format(
            'BEGIN; LOCK TABLE %I.executions IN ACCESS EXCLUSIVE MODE', df.duroxide_schema()
        ));
        PERFORM dblink_exec('quota_trust_user', format($remote$
            DO $unavailable$
            BEGIN
                BEGIN
                    PERFORM df.start('SELECT 1', 'quota-trust-unavailable', NULL, %L);
                    RAISE EXCEPTION 'TEST FAILED: unavailable engine accounting admitted work';
                EXCEPTION WHEN internal_error THEN
                    IF SQLERRM NOT LIKE '%%quota check failed:%%lock timeout%%' THEN
                        RAISE;
                    END IF;
                END;
            END $unavailable$;
        $remote$, mode));
        PERFORM pg_stat_clear_snapshot();
        IF EXISTS (
            SELECT 1 FROM pg_stat_activity
            WHERE state = 'idle in transaction (aborted)' AND query LIKE '%AS requested(id)%'
        ) THEN
            RAISE EXCEPTION 'TEST FAILED: failed quota lookup left an aborted provider transaction';
        END IF;
        PERFORM dblink_exec('quota_trust_fence', 'COMMIT');

        -- Hold engine acknowledgment, not enqueue, so cancellation is definitely
        -- requested but not yet terminal when admission is checked.
        PERFORM dblink_exec('quota_trust_fence', format(
            'BEGIN; LOCK TABLE %I.executions IN SHARE MODE', df.duroxide_schema()
        ));
        PERFORM * FROM dblink('quota_trust_user',
            format('SELECT df.cancel(%L)', instance)) AS cancelled(message TEXT);
        PERFORM dblink_exec('quota_trust_user', format($remote$
            DO $reject$
            BEGIN
                BEGIN
                    PERFORM df.start('SELECT 1', 'quota-trust-cancelling', NULL, %L);
                    RAISE EXCEPTION 'TEST FAILED: unprocessed cancellation freed capacity';
                EXCEPTION WHEN configuration_limit_exceeded THEN NULL;
                END;
            END $reject$;
        $remote$, mode));
        PERFORM dblink_exec('quota_trust_fence', 'COMMIT');
        PERFORM public._e2e_wait_for_engine_terminal(instance);

        SELECT id INTO replacement FROM dblink('quota_trust_user', format(
            'SELECT df.start(''SELECT 1'', ''quota-trust-replacement'', NULL, %L)', mode
        )) AS started(id TEXT);
        IF public._e2e_wait_for_engine_terminal(replacement) <> 'Completed' THEN
            RAISE EXCEPTION 'TEST FAILED: capacity did not recover after cancellation';
        END IF;
    END LOOP;
    PERFORM dblink_disconnect('quota_trust_user');
    PERFORM dblink_disconnect('quota_trust_attacker');
    PERFORM dblink_disconnect('quota_trust_fence');
END $$;

DROP OWNED BY quota_trust_user, quota_trust_attacker;
DROP ROLE quota_trust_user, quota_trust_attacker;
SELECT 'TEST PASSED' AS result;
