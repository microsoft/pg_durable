-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- A loop that loses a RACE is cancelled by duroxide when its durable future is
-- dropped. The parent must record that cancellation on the LOOP node so
-- df.instance_nodes() and df.explain() do not leave it running.
SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _race_losing_loop_instance AS
SELECT df.start(
    df.race(
        df.sleep(1),
        df.loop(df.sleep(30))
    ),
    'test-race-losing-loop-cancelled'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    loop_status TEXT;
    loop_inferred_status TEXT;
    loop_stamp TEXT;
BEGIN
    SELECT i.instance_id INTO instance_id FROM _race_losing_loop_instance i;
    SELECT df.await_instance(instance_id, 30) INTO final_status;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [race-losing-loop]: expected completed instance, got %', final_status;
    END IF;

    SELECT n.status, n.inferred_status, n.status_details::jsonb->>'execution_id'
    INTO loop_status, loop_inferred_status, loop_stamp
    FROM df.instance_nodes(instance_id) n
    WHERE n.node_type = 'LOOP';

    IF loop_status IS DISTINCT FROM 'failed' OR loop_inferred_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [race-losing-loop]: expected terminal failed LOOP node, got physical %, inferred %',
            loop_status, loop_inferred_status;
    END IF;

    IF loop_stamp !~ ('^' || instance_id || '::1::[0-9a-f]{8}::1$') THEN
        RAISE EXCEPTION 'TEST FAILED [race-losing-loop]: unexpected LOOP child stamp %', loop_stamp;
    END IF;

    IF df.explain(instance_id) LIKE '%LOOP%running%' OR df.explain(instance_id) LIKE '%LOOP%pending%' THEN
        RAISE EXCEPTION 'TEST FAILED [race-losing-loop]: df.explain() left LOOP node non-terminal: %',
            df.explain(instance_id);
    END IF;
END $$;

DROP TABLE _race_losing_loop_instance;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
