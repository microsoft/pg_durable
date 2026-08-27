-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- The host-guc phase starts PostgreSQL with an invalid PGHOST while setting
-- pg_durable.host to the server's Unix-socket directory. Worker readiness
-- proves URL-based pool connections use the GUC; this workflow proves the
-- direct per-user connection path uses it too.

DO $$
BEGIN
    IF current_setting('pg_durable.host') != current_setting('unix_socket_directories') THEN
        RAISE EXCEPTION 'TEST FAILED: pg_durable.host is not the configured socket directory';
    END IF;
END $$;

DROP TABLE IF EXISTS host_guc_log;
CREATE TABLE host_guc_log (
    submitted_by TEXT NOT NULL,
    connection_path TEXT NOT NULL
);
GRANT INSERT, SELECT ON host_guc_log TO df_e2e_user;

CREATE TEMP TABLE _test_state (
    instance_id TEXT,
    connection_path TEXT
);
GRANT INSERT ON _test_state TO df_e2e_user;

SET ROLE df_e2e_user;
INSERT INTO _test_state
SELECT df.start(
    'INSERT INTO host_guc_log VALUES (current_user, ''workflow-sql'')',
    'host-guc-precedence'
), 'workflow-sql';

INSERT INTO _test_state
SELECT df.start(
    'INSERT INTO host_guc_log VALUES (current_user, ''new-transaction'')',
    'host-guc-new-transaction',
    transaction_mode => 'new'
), 'new-transaction';
RESET ROLE;

DO $$
DECLARE
    test_state RECORD;
    status TEXT;
BEGIN
    FOR test_state IN SELECT * FROM _test_state LOOP
        SELECT df.await_instance(test_state.instance_id, 30) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: % status = %', test_state.connection_path, status;
        END IF;
    END LOOP;

    IF (SELECT count(*) FROM host_guc_log WHERE submitted_by = 'df_e2e_user') != 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected both connection paths to execute as df_e2e_user';
    END IF;
END $$;

DROP TABLE _test_state;
DROP TABLE host_guc_log;
SELECT 'TEST PASSED' AS result;
