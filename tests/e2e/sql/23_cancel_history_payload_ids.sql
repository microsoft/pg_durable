-- Regression test: cancellation terminal history payload must preserve identifiers

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _payload_cancel_instance (instance_id TEXT);

INSERT INTO _payload_cancel_instance
SELECT df.start(
    df.sleep(300),
    'cancel-history-payload-ids'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _payload_cancel_instance;

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'running' OR attempts > 200;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) <> 'running' THEN
        RAISE EXCEPTION 'TEST FAILED: instance did not reach running state before cancellation (status=%)', status;
    END IF;

    PERFORM df.cancel(inst_id, 'payload-id-regression-check');

    attempts := 0;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('cancelled', 'failed') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
END $$;

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    bad_rows INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _payload_cancel_instance;

    SELECT COUNT(*)
    INTO bad_rows
    FROM duroxide.history h
    WHERE h.instance_id = inst_id
      AND (h.event_data::JSONB ? 'instance_id' OR h.event_data::JSONB ? 'execution_id')
      AND (
            (h.event_data::JSONB ? 'instance_id'
             AND COALESCE(h.event_data::JSONB->>'instance_id', '') <> h.instance_id)
         OR (h.event_data::JSONB ? 'execution_id'
             AND (
                 COALESCE(h.event_data::JSONB->>'execution_id', '') !~ '^[0-9]+$'
                 OR (h.event_data::JSONB->>'execution_id')::BIGINT <> h.execution_id
             ))
      );

    IF bad_rows > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: found % history events with payload identifiers that do not match row identifiers for instance %',
            bad_rows, inst_id;
    END IF;

    RAISE NOTICE 'TEST PASSED: cancellation history payload identifiers match row identifiers';
END $$;

SELECT 'TEST PASSED: cancel history payload identifiers' AS result;
