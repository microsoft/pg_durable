-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Correcting the installed version while PostgreSQL remains running must wake
-- the stood-down worker and initialize the provider without a server restart.
-- Restores the version captured by compatibility-rejection-setup.sql so this
-- file does not have to track the current release.

UPDATE pg_catalog.pg_extension e
SET extversion = s.original_version
FROM _duroxide.compat_fixture_state s
WHERE e.extname = 'pg_durable';

DO $$
DECLARE
    attempts INT := 0;
    ready BOOLEAN := FALSE;
BEGIN
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_durable') = '0.2.2-rc1' THEN
        RAISE EXCEPTION 'TEST FAILED: captured version was not restored';
    END IF;

    WHILE attempts < 100 LOOP
        SELECT EXISTS (
            SELECT 1 FROM _duroxide._worker_ready
            WHERE sentinel AND schema_version = 1
        ) INTO ready;
        EXIT WHEN ready;
        PERFORM pg_catalog.pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF NOT ready THEN
        RAISE EXCEPTION 'TEST FAILED: worker did not leave compatibility stand-down after version correction';
    END IF;
END $$;

CREATE TEMP TABLE compat_recovery_state (instance_id TEXT);
INSERT INTO compat_recovery_state
SELECT df.start('SELECT 606 AS recovered', 'compat-live-version-recovery');

DO $$
DECLARE
    recovered_id TEXT;
    recovered_status TEXT;
BEGIN
    SELECT instance_id INTO recovered_id FROM compat_recovery_state;
    recovered_status := df.await_instance(recovered_id, 30);
    IF recovered_status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: live version correction did not restore execution (status=%)',
            recovered_status;
    END IF;
END $$;

DROP TABLE compat_recovery_state;

SELECT 'TEST PASSED: provider compatibility live recovery' AS result;
