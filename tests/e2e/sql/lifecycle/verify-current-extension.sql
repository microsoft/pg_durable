-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

CREATE TEMP TABLE lifecycle_recovery_state (instance_id TEXT);
INSERT INTO lifecycle_recovery_state
SELECT df.start('SELECT 404 AS recovered', 'lifecycle-clean-recovery');

DO $$
DECLARE
    recovered_id TEXT;
    recovered_status TEXT;
    recovered_result TEXT;
BEGIN
    SELECT instance_id INTO recovered_id FROM lifecycle_recovery_state;
    recovered_status := df.await_instance(recovered_id, 30);
    SELECT r INTO recovered_result FROM df.result(recovered_id) r;

    IF recovered_status <> 'completed' OR recovered_result NOT LIKE '%404%' THEN
        RAISE EXCEPTION 'TEST FAILED: clean extension did not recover (status=%, result=%)',
            recovered_status, recovered_result;
    END IF;
END $$;

SELECT 'TEST PASSED: current extension recovered after rejected lifecycle' AS result;