-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

CREATE OR REPLACE FUNCTION pg_temp.duroxide_instance_status(p_instance_id TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    provider_schema TEXT := df.duroxide_schema();
    engine_status TEXT;
BEGIN
    EXECUTE format(
        'SELECT i.status FROM %I.get_instance_info($1) i',
        provider_schema
    )
    INTO engine_status
    USING p_instance_id;
    RETURN engine_status;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.duroxide_child_count(p_parent_instance_id TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    provider_schema TEXT := df.duroxide_schema();
    child_count BIGINT;
BEGIN
    EXECUTE format(
        'SELECT count(*) FROM %I.instances WHERE parent_instance_id = $1',
        provider_schema
    )
    INTO child_count
    USING p_parent_instance_id;
    RETURN child_count;
END
$$;

SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_loop_continue_attempts;
CREATE TABLE test_loop_continue_attempts (
    id SERIAL PRIMARY KEY,
    scenario TEXT NOT NULL
);

CREATE TEMP TABLE _loop_continue_instances (
    scenario TEXT PRIMARY KEY,
    instance_id TEXT NOT NULL
);

INSERT INTO _loop_continue_instances
SELECT 'continue',
       df.start(
           df.loop(
               $$INSERT INTO test_loop_continue_attempts(scenario)
                   VALUES ('continue')$$
               ~> df.if(
                   $$SELECT count(*) = 1
                       FROM test_loop_continue_attempts
                       WHERE scenario = 'continue'$$,
                   'SELECT 1 / 0',
                   df.break('"completed-after-failure"')
               ),
               continue_on_failure => true
           ),
           'test-loop-continue-on-failure'
       );

INSERT INTO _loop_continue_instances
SELECT 'fail-fast',
       df.start(
           df.loop('SELECT 1 / 0', continue_on_failure => false),
           'test-loop-explicit-fail-fast'
       );

DO $$
DECLARE
    continued_status TEXT;
    failed_status TEXT;
    attempts INT;
    continued_explain TEXT;
BEGIN
    SELECT df.await_instance(instance_id, 30)
    INTO continued_status
    FROM _loop_continue_instances
    WHERE scenario = 'continue';

    SELECT df.await_instance(instance_id, 30)
    INTO failed_status
    FROM _loop_continue_instances
    WHERE scenario = 'fail-fast';

    SELECT count(*) INTO attempts
    FROM test_loop_continue_attempts
    WHERE scenario = 'continue';

    SELECT df.explain(instance_id) INTO continued_explain
    FROM _loop_continue_instances
    WHERE scenario = 'continue';

    IF continued_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION
            'TEST FAILED [continue]: expected completed, got %',
            continued_status;
    END IF;
    IF failed_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION
            'TEST FAILED [fail-fast]: expected failed, got %',
            failed_status;
    END IF;
    IF attempts <> 2 THEN
        RAISE EXCEPTION
            'TEST FAILED [continue]: expected exactly two isolated iterations, got %',
            attempts;
    END IF;
    IF continued_explain NOT LIKE '%LOOP (infinite, continue on failure)%' THEN
        RAISE EXCEPTION
            'TEST FAILED [continue]: df.explain() omitted loop policy: %',
            continued_explain;
    END IF;
END $$;

DROP TABLE _loop_continue_instances;
DROP TABLE test_loop_continue_attempts;

DROP TABLE IF EXISTS test_nested_continue;
CREATE TABLE test_nested_continue (stage TEXT NOT NULL);

CREATE TEMP TABLE _nested_continue_instance AS
SELECT df.start(
    $$INSERT INTO test_nested_continue VALUES ('prefix')$$
    ~> df.loop(
        $$INSERT INTO test_nested_continue VALUES ('iteration')$$
        ~> df.if(
            $$SELECT count(*) = 1
                FROM test_nested_continue
                WHERE stage = 'iteration'$$,
            'SELECT 1 / 0',
            df.break()
        ),
        continue_on_failure => true
    )
    ~> $$INSERT INTO test_nested_continue VALUES ('suffix')$$,
    'test-nested-loop-continue'
) AS instance_id;

DO $$
DECLARE
    final_status TEXT;
    prefix_count INT;
    iteration_count INT;
    suffix_count INT;
BEGIN
    SELECT df.await_instance(instance_id, 30)
    INTO final_status
    FROM _nested_continue_instance;

    SELECT
        count(*) FILTER (WHERE stage = 'prefix'),
        count(*) FILTER (WHERE stage = 'iteration'),
        count(*) FILTER (WHERE stage = 'suffix')
    INTO prefix_count, iteration_count, suffix_count
    FROM test_nested_continue;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION
            'TEST FAILED [nested]: expected completed, got %',
            final_status;
    END IF;
    IF prefix_count <> 1 OR iteration_count <> 2 OR suffix_count <> 1 THEN
        RAISE EXCEPTION
            'TEST FAILED [nested]: expected prefix/iteration/suffix = 1/2/1, got %/%/%',
            prefix_count, iteration_count, suffix_count;
    END IF;
END $$;

DROP TABLE _nested_continue_instance;
DROP TABLE test_nested_continue;

DROP FUNCTION IF EXISTS test_conditional_continue_body();
DROP FUNCTION IF EXISTS test_conditional_continue_condition();
DROP FUNCTION IF EXISTS test_conditional_continue_failing_condition();
DROP SEQUENCE IF EXISTS test_conditional_continue_attempt_seq;
DROP TABLE IF EXISTS test_conditional_continue_state;

CREATE TABLE test_conditional_continue_state (
    body_attempts INT NOT NULL DEFAULT 0,
    condition_checks INT NOT NULL DEFAULT 0
);
INSERT INTO test_conditional_continue_state DEFAULT VALUES;

-- Sequence values are not rolled back when the first function call raises, allowing the
-- second successful call to persist the total attempt count in the state table.
CREATE SEQUENCE test_conditional_continue_attempt_seq;

CREATE FUNCTION test_conditional_continue_body() RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    attempts INT;
BEGIN
    attempts := nextval('test_conditional_continue_attempt_seq');
    UPDATE test_conditional_continue_state
    SET body_attempts = attempts;

    IF attempts = 1 THEN
        RAISE EXCEPTION 'transient body failure';
    END IF;
    RETURN attempts;
END
$$;

CREATE FUNCTION test_conditional_continue_condition() RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE test_conditional_continue_state
    SET condition_checks = condition_checks + 1;
    RETURN false;
END
$$;

CREATE FUNCTION test_conditional_continue_failing_condition() RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'fatal condition failure';
END
$$;

CREATE TEMP TABLE _conditional_continue_instances (
    scenario TEXT PRIMARY KEY,
    instance_id TEXT NOT NULL
);

INSERT INTO _conditional_continue_instances
SELECT 'body-recovery',
       df.start(
           df.loop(
               'SELECT test_conditional_continue_body()',
               'SELECT test_conditional_continue_condition()',
               continue_on_failure => true
           ),
           'test-conditional-loop-continues-after-body-failure'
       );

INSERT INTO _conditional_continue_instances
SELECT 'condition-failure',
       df.start(
           df.loop(
               'SELECT 42',
               'SELECT test_conditional_continue_failing_condition()',
               continue_on_failure => true
           ),
           'test-conditional-loop-condition-failure-is-fatal'
       );

DO $$
DECLARE
    recovered_status TEXT;
    condition_failure_status TEXT;
    body_attempts INT;
    condition_checks INT;
    conditional_explain TEXT;
BEGIN
    SELECT df.await_instance(instance_id, 30)
    INTO recovered_status
    FROM _conditional_continue_instances
    WHERE scenario = 'body-recovery';

    SELECT df.await_instance(instance_id, 30)
    INTO condition_failure_status
    FROM _conditional_continue_instances
    WHERE scenario = 'condition-failure';

    SELECT s.body_attempts, s.condition_checks
    INTO body_attempts, condition_checks
    FROM test_conditional_continue_state s;

    SELECT df.explain(instance_id) INTO conditional_explain
    FROM _conditional_continue_instances
    WHERE scenario = 'body-recovery';

    IF recovered_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION
            'TEST FAILED [conditional continue]: expected completed, got %',
            recovered_status;
    END IF;
    IF body_attempts <> 2 OR condition_checks <> 1 THEN
        RAISE EXCEPTION
            'TEST FAILED [conditional continue]: expected body/condition = 2/1, got %/%',
            body_attempts, condition_checks;
    END IF;
    IF condition_failure_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION
            'TEST FAILED [condition failure]: expected failed, got %',
            condition_failure_status;
    END IF;
    IF conditional_explain NOT LIKE '%LOOP (while, continue on failure)%' THEN
        RAISE EXCEPTION
            'TEST FAILED [conditional continue]: df.explain() omitted combined loop mode: %',
            conditional_explain;
    END IF;
END $$;

DROP TABLE _conditional_continue_instances;
DROP FUNCTION test_conditional_continue_body();
DROP FUNCTION test_conditional_continue_condition();
DROP FUNCTION test_conditional_continue_failing_condition();
DROP SEQUENCE test_conditional_continue_attempt_seq;
DROP TABLE test_conditional_continue_state;

CREATE TEMP TABLE _cancel_continue_instance (instance_id TEXT);

INSERT INTO _cancel_continue_instance(instance_id)
SELECT df.start(
    df.loop(
        df.sleep(30),
        continue_on_failure => true
    ),
    'test-cancel-failure-isolated-loop'
);

DO $$
DECLARE
    parent_id TEXT;
    child_stamp TEXT;
    child_id TEXT;
    parent_status TEXT;
    child_status TEXT;
    child_count BIGINT;
    attempts INT := 0;
BEGIN
    SELECT c.instance_id INTO parent_id FROM _cancel_continue_instance c;

    LOOP
        SELECT n.status_details::jsonb->>'execution_id'
        INTO child_stamp
        FROM df.instance_nodes(parent_id) n
        WHERE n.node_type = 'SLEEP'
          AND n.status = 'running';
        EXIT WHEN child_stamp IS NOT NULL OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF child_stamp IS NULL THEN
        RAISE EXCEPTION
            'TEST FAILED [cancel]: active iteration child was not observed';
    END IF;

    child_id := array_to_string(
        (string_to_array(child_stamp, '::'))[
            1:array_length(string_to_array(child_stamp, '::'), 1) - 1
        ],
        '::'
    );
    child_status := pg_temp.duroxide_instance_status(child_id);
    IF lower(COALESCE(child_status, '')) IS DISTINCT FROM 'running' THEN
        RAISE EXCEPTION
            'TEST FAILED [cancel]: expected active child %, got status %',
            child_id, child_status;
    END IF;

    PERFORM df.cancel(parent_id, 'test cancellation propagation');
    SELECT df.await_instance(parent_id, 30) INTO parent_status;

    IF parent_status IS DISTINCT FROM 'cancelled' THEN
        RAISE EXCEPTION
            'TEST FAILED [cancel]: expected cancelled parent, got %',
            parent_status;
    END IF;

    attempts := 0;
    LOOP
        child_status := pg_temp.duroxide_instance_status(child_id);
        EXIT WHEN lower(COALESCE(child_status, '')) = 'failed' OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(COALESCE(child_status, '')) IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION
            'TEST FAILED [cancel]: active child % was not cancelled; engine status %',
            child_id, child_status;
    END IF;

    child_count := pg_temp.duroxide_child_count(parent_id);
    IF child_count <> 1 THEN
        RAISE EXCEPTION
            'TEST FAILED [cancel]: expected one cancelled iteration child and no continuation, got % children',
            child_count;
    END IF;
END $$;

DROP TABLE _cancel_continue_instance;

DROP TABLE IF EXISTS test_scheduled_loop_ticks;
CREATE TABLE test_scheduled_loop_ticks (
    id SERIAL PRIMARY KEY,
    fired_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TEMP TABLE _scheduled_loop_instance AS
SELECT df.start(
    df.loop(
        df.wait_for_schedule('* * * * *')
        ~> 'INSERT INTO test_scheduled_loop_ticks DEFAULT VALUES'
        ~> df.if(
            'SELECT count(*) = 1 FROM test_scheduled_loop_ticks',
            'SELECT 1 / 0',
            df.break('"scheduled-loop-recovered"')
        ),
        continue_on_failure => true
    ),
    'test-scheduled-loop-continues'
) AS instance_id;

DO $$
DECLARE
    instance_id TEXT;
    attempts INT := 0;
    current_status TEXT;
    failed_nodes INT;
BEGIN
    SELECT s.instance_id INTO instance_id FROM _scheduled_loop_instance s;
    LOOP
        SELECT count(*) INTO failed_nodes
        FROM df.instance_nodes(instance_id)
        WHERE status = 'failed';
        EXIT WHEN failed_nodes > 0 OR attempts >= 900;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    SELECT s INTO current_status FROM df.status(instance_id) s;
    IF failed_nodes = 0 THEN
        RAISE EXCEPTION
            'TEST FAILED [scheduled]: failed child node was not recorded';
    END IF;
    IF current_status IS DISTINCT FROM 'running' THEN
        RAISE EXCEPTION
            'TEST FAILED [scheduled]: parent stopped after child failure: %',
            current_status;
    END IF;
END $$;

DO $$
DECLARE
    final_status TEXT;
    tick_count INT;
    first_tick TIMESTAMPTZ;
    second_tick TIMESTAMPTZ;
BEGIN
    SELECT df.await_instance(instance_id, 180)
    INTO final_status
    FROM _scheduled_loop_instance;

    SELECT count(*), min(fired_at), max(fired_at)
    INTO tick_count, first_tick, second_tick
    FROM test_scheduled_loop_ticks;

    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION
            'TEST FAILED [scheduled]: expected completed, got %',
            final_status;
    END IF;
    IF tick_count <> 2 THEN
        RAISE EXCEPTION
            'TEST FAILED [scheduled]: expected two ticks, got %',
            tick_count;
    END IF;
    IF second_tick - first_tick < interval '50 seconds' THEN
        RAISE EXCEPTION
            'TEST FAILED [scheduled]: next iteration did not wait for the next tick: % / %',
            first_tick, second_tick;
    END IF;
END $$;

DROP TABLE _scheduled_loop_instance;
DROP TABLE test_scheduled_loop_ticks;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
