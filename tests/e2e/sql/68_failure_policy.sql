-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- df.start()'s node failure policy: max_attempts / max_backoff retry a failing
-- node, and on_failure decides what happens once the attempts are spent.
--
-- Attempts are counted with sequences rather than tables: nextval() is
-- non-transactional, so the count survives the rollback of the failed attempt
-- that produced it. Every case pins max_backoff to 1 second so the whole file
-- stays well inside the e2e time budget.
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_fp_loop_log;
DROP SEQUENCE IF EXISTS test_fp_transient_seq;
DROP SEQUENCE IF EXISTS test_fp_loop_seq;
DROP SEQUENCE IF EXISTS test_fp_no_loop_seq;
DROP SEQUENCE IF EXISTS test_fp_fail_seq;

CREATE TABLE test_fp_loop_log (id SERIAL PRIMARY KEY, note TEXT);
CREATE SEQUENCE test_fp_transient_seq;
CREATE SEQUENCE test_fp_loop_seq;
CREATE SEQUENCE test_fp_no_loop_seq;
CREATE SEQUENCE test_fp_fail_seq;

-- ---------------------------------------------------------------------------
-- Case 1: a transient failure is retried until it succeeds.
-- The node divides by zero on its first two attempts and succeeds on the third.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _fp_transient AS
SELECT df.start(
    $$SELECT 1 / (CASE WHEN nextval('test_fp_transient_seq') >= 3 THEN 1 ELSE 0 END)$$,
    'test-failure-policy-transient',
    max_attempts => 5,
    max_backoff => '1 second'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    attempts BIGINT;
BEGIN
    SELECT i.instance_id INTO instance_id FROM _fp_transient i;
    SELECT df.await_instance(instance_id, 60) INTO final_status;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [transient]: expected completed, got % (%)',
            final_status, (SELECT output FROM df.instance_info(instance_id));
    END IF;

    SELECT last_value INTO attempts FROM test_fp_transient_seq;
    IF attempts IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'TEST FAILED [transient]: expected exactly 3 attempts, got %', attempts;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Case 2: on_failure => 'continue' (the default) abandons the rest of the
-- failing iteration and runs the next one. The body fails through iteration 1
-- (attempts 1-2) and the first attempt of iteration 2, then succeeds.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _fp_loop AS
SELECT df.start(
    df.loop(
        $$SELECT 1 / (CASE WHEN nextval('test_fp_loop_seq') >= 4 THEN 1 ELSE 0 END)$$
        ~> $$INSERT INTO test_fp_loop_log (note) VALUES ('body-completed')$$,
        'SELECT count(*) < 1 FROM test_fp_loop_log'
    ),
    'test-failure-policy-loop-continue',
    max_attempts => 2,
    max_backoff => '1 second'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    attempts BIGINT;
    completed_bodies INT;
BEGIN
    SELECT i.instance_id INTO instance_id FROM _fp_loop i;
    SELECT df.await_instance(instance_id, 60) INTO final_status;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [loop-continue]: expected completed, got % (%)',
            final_status, (SELECT output FROM df.instance_info(instance_id));
    END IF;

    -- 2 attempts in the abandoned first iteration, 2 more in the second.
    SELECT last_value INTO attempts FROM test_fp_loop_seq;
    IF attempts IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-continue]: expected 4 attempts across 2 iterations, got %', attempts;
    END IF;

    -- The node after the failure is skipped in the abandoned iteration, so it
    -- runs exactly once even though the loop ran twice.
    SELECT count(*) INTO completed_bodies FROM test_fp_loop_log;
    IF completed_bodies IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'TEST FAILED [loop-continue]: expected 1 completed body, got %', completed_bodies;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Case 3: 'continue' with no enclosing loop has no next iteration to continue
-- into, so the instance fails once the attempts are spent.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _fp_no_loop AS
SELECT df.start(
    $$SELECT 1 / (CASE WHEN nextval('test_fp_no_loop_seq') < 0 THEN 1 ELSE 0 END)$$,
    'test-failure-policy-no-loop',
    max_attempts => 2,
    max_backoff => '1 second',
    on_failure => 'continue'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    instance_output TEXT;
    attempts BIGINT;
    failed_nodes INT;
    waited INT;
BEGIN
    SELECT i.instance_id INTO instance_id FROM _fp_no_loop i;
    SELECT df.await_instance(instance_id, 60) INTO final_status;

    IF final_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [no-loop]: expected failed, got %', final_status;
    END IF;

    SELECT last_value INTO attempts FROM test_fp_no_loop_seq;
    IF attempts IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'TEST FAILED [no-loop]: expected 2 attempts, got %', attempts;
    END IF;

    -- df.instances.status can be visible a moment before the failure output is
    -- written, so give the output a bounded window to appear.
    FOR waited IN 1..100 LOOP
        SELECT output INTO instance_output FROM df.instance_info(instance_id);
        EXIT WHEN instance_output IS NOT NULL;
        PERFORM pg_sleep(0.1);
    END LOOP;

    IF COALESCE(instance_output, '') NOT LIKE '%division by zero%' THEN
        RAISE EXCEPTION 'TEST FAILED [no-loop]: original SQL error did not surface: %', instance_output;
    END IF;

    -- The node itself is stamped failed once the attempts settle.
    SELECT count(*) INTO failed_nodes
    FROM df.instance_nodes(instance_id) n
    WHERE n.inferred_status = 'failed';
    IF failed_nodes < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [no-loop]: no failed node reported by df.instance_nodes()';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Case 4: on_failure => 'fail' with max_attempts => 1 restores the pre-0.2.7
-- behaviour — a single attempt, then the instance fails even inside a loop.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _fp_fail AS
SELECT df.start(
    df.loop(
        $$SELECT 1 / (CASE WHEN nextval('test_fp_fail_seq') < 0 THEN 1 ELSE 0 END)$$,
        'SELECT true'
    ),
    'test-failure-policy-fail',
    max_attempts => 1,
    on_failure => 'fail'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    final_status TEXT;
    attempts BIGINT;
BEGIN
    SELECT i.instance_id INTO instance_id FROM _fp_fail i;
    SELECT df.await_instance(instance_id, 60) INTO final_status;

    IF final_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [fail]: expected failed, got %', final_status;
    END IF;

    SELECT last_value INTO attempts FROM test_fp_fail_seq;
    IF attempts IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'TEST FAILED [fail]: expected exactly 1 attempt, got %', attempts;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Case 5: argument validation is rejected at df.start() time.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    err TEXT;
BEGIN
    BEGIN
        PERFORM df.start('SELECT 1', 'test-failure-policy-bad-attempts', max_attempts => 0);
        RAISE EXCEPTION 'TEST FAILED [validation]: max_attempts => 0 was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS err = MESSAGE_TEXT;
        IF err NOT LIKE '%max_attempts%' THEN
            RAISE EXCEPTION 'TEST FAILED [validation]: unexpected error for max_attempts => 0: %', err;
        END IF;
    END;

    BEGIN
        PERFORM df.start('SELECT 1', 'test-failure-policy-bad-backoff', max_backoff => '-1 second');
        RAISE EXCEPTION 'TEST FAILED [validation]: negative max_backoff was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS err = MESSAGE_TEXT;
        IF err NOT LIKE '%max_backoff%' THEN
            RAISE EXCEPTION 'TEST FAILED [validation]: unexpected error for negative max_backoff: %', err;
        END IF;
    END;

    BEGIN
        PERFORM df.start('SELECT 1', 'test-failure-policy-bad-on-failure', on_failure => 'explode');
        RAISE EXCEPTION 'TEST FAILED [validation]: on_failure => ''explode'' was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS err = MESSAGE_TEXT;
        IF err NOT LIKE '%on_failure%' THEN
            RAISE EXCEPTION 'TEST FAILED [validation]: unexpected error for on_failure => ''explode'': %', err;
        END IF;
    END;
END $$;

DROP TABLE _fp_transient;
DROP TABLE _fp_loop;
DROP TABLE _fp_no_loop;
DROP TABLE _fp_fail;
DROP TABLE test_fp_loop_log;
DROP SEQUENCE test_fp_transient_seq;
DROP SEQUENCE test_fp_loop_seq;
DROP SEQUENCE test_fp_no_loop_seq;
DROP SEQUENCE test_fp_fail_seq;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
