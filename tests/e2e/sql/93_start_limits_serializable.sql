-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

DO $$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['quota_ssi_a', 'quota_ssi_b'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('DROP OWNED BY %I', role_name);
            EXECUTE format('DROP ROLE %I', role_name);
        END IF;
    END LOOP;
END $$;
CREATE ROLE quota_ssi_a LOGIN;
CREATE ROLE quota_ssi_b LOGIN;
SELECT df.grant_usage('quota_ssi_a');
SELECT df.grant_usage('quota_ssi_b');
CREATE TEMP TABLE _quota_ssi (conn TEXT PRIMARY KEY, id TEXT, state TEXT);
INSERT INTO _quota_ssi (conn) VALUES ('quota_ssi_a'), ('quota_ssi_b');

DO $$
DECLARE
    session RECORD;
    commit_result TEXT;
    retry_count INTEGER := 0;
BEGIN
    FOR session IN SELECT * FROM _quota_ssi ORDER BY conn LOOP
        PERFORM dblink_connect(session.conn, format(
            'host=localhost dbname=%L port=%s user=%s',
            current_database(), current_setting('port'), session.conn));
        PERFORM dblink_exec(session.conn, $remote$
            SET statement_timeout = '15s';
            -- Exercise the scan fallback used by binary-only upgraded schemas.
            SET enable_indexscan = off;
            SET enable_indexonlyscan = off;
            SET enable_bitmapscan = off;
            CREATE FUNCTION pg_temp.quota_start()
            RETURNS TABLE (id TEXT, state TEXT) LANGUAGE plpgsql AS $start$
            BEGIN
                RETURN QUERY SELECT df.start(df.sleep(300)), '00000'::text;
            EXCEPTION WHEN serialization_failure THEN
                RETURN QUERY SELECT NULL::text, SQLSTATE;
            END $start$;
        $remote$);
        PERFORM dblink_exec(session.conn, 'BEGIN ISOLATION LEVEL SERIALIZABLE');
    END LOOP;

    -- Both transactions remain open through both starts. Their advisory keys
    -- differ, but PostgreSQL predicate locking can still require a retry.
    FOR session IN SELECT * FROM _quota_ssi ORDER BY conn LOOP
        UPDATE _quota_ssi
        SET id = started.id, state = started.state
        FROM dblink(session.conn, 'SELECT * FROM pg_temp.quota_start()')
             AS started(id TEXT, state TEXT)
        WHERE conn = session.conn;
    END LOOP;
    FOR session IN SELECT * FROM _quota_ssi ORDER BY conn LOOP
        IF session.state = '40001' THEN
            PERFORM dblink_exec(session.conn, 'ROLLBACK');
        ELSIF session.state = '00000' THEN
            commit_result := dblink_exec(session.conn, 'COMMIT', false);
            IF commit_result = 'ERROR' THEN
                IF dblink_error_message(session.conn) NOT LIKE '%could not serialize access%' THEN
                    RAISE EXCEPTION 'TEST FAILED: unexpected commit error: %',
                        dblink_error_message(session.conn);
                END IF;
                UPDATE _quota_ssi SET state = '40001' WHERE conn = session.conn;
                PERFORM dblink_exec(session.conn, 'ROLLBACK');
            ELSIF commit_result <> 'COMMIT' THEN
                RAISE EXCEPTION 'TEST FAILED: expected COMMIT, got %', commit_result;
            END IF;
        ELSE
            RAISE EXCEPTION 'TEST FAILED: unexpected start result: %', session.state;
        END IF;
    END LOOP;
    FOR session IN SELECT * FROM _quota_ssi WHERE state = '40001' ORDER BY conn LOOP
        retry_count := retry_count + 1;
        PERFORM dblink_exec(session.conn, 'BEGIN ISOLATION LEVEL SERIALIZABLE');
        UPDATE _quota_ssi
        SET id = started.id, state = started.state
        FROM dblink(session.conn, 'SELECT * FROM pg_temp.quota_start()')
             AS started(id TEXT, state TEXT)
        WHERE conn = session.conn;
        PERFORM dblink_exec(session.conn, 'COMMIT');
    END LOOP;
    FOR session IN SELECT * FROM _quota_ssi ORDER BY conn LOOP
        IF session.state IS DISTINCT FROM '00000' OR session.id IS NULL OR
           (SELECT count(*) FROM df.instances WHERE submitted_by = session.conn::regrole) <> 1 THEN
            RAISE EXCEPTION 'TEST FAILED: serializable retry left incorrect instance state: %', session;
        END IF;
        PERFORM df.cancel(session.id);
        PERFORM public._e2e_wait_for_engine_terminal(session.id);
        PERFORM dblink_disconnect(session.conn);
    END LOOP;
    RAISE NOTICE 'Two overlapping serializable starts completed with % transaction retries', retry_count;
END $$;

DROP TABLE _quota_ssi;
DROP OWNED BY quota_ssi_a, quota_ssi_b;
DROP ROLE quota_ssi_a, quota_ssi_b;
SELECT 'TEST PASSED' AS result;
