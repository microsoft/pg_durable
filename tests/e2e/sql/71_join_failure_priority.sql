-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- A fatal JOIN branch failure must take precedence over a recoverable activity
-- failure in an earlier branch. Otherwise a failure-isolated loop consumes the
-- recoverable error without inspecting the fatal sibling and starts another
-- iteration.
SET SESSION AUTHORIZATION df_e2e_user;

DROP SEQUENCE IF EXISTS test_join_failure_priority_attempt_seq;
CREATE SEQUENCE test_join_failure_priority_attempt_seq CACHE 1;

CREATE TEMP TABLE _join_failure_priority_instance AS
SELECT df.start(
    df.loop(
        $$SELECT 1 / (
            CASE
                WHEN nextval('test_join_failure_priority_attempt_seq') >= 2 THEN 1
                ELSE 0
            END
        )$$
        & (
            df.sql('SELECT NULL::int AS value') |=> 'nullable'
            ~> 'SELECT $nullable'
        ),
        continue_on_failure => true
    ),
    'test-join-fatal-failure-priority'
) AS instance_id;

DO $$
DECLARE
    final_status TEXT;
    attempts BIGINT;
    instance_output TEXT;
    waited INT;
BEGIN
    SELECT df.await_instance(i.instance_id, 30)
    INTO final_status
    FROM _join_failure_priority_instance i;

    SELECT last_value
    INTO attempts
    FROM test_join_failure_priority_attempt_seq;

    IF final_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION
            'TEST FAILED [join failure priority]: expected failed, got %',
            final_status;
    END IF;
    IF attempts IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION
            'TEST FAILED [join failure priority]: fatal sibling was hidden for % iterations',
            attempts;
    END IF;

    FOR waited IN 1..100 LOOP
        SELECT info.output
        INTO instance_output
        FROM _join_failure_priority_instance i
        CROSS JOIN LATERAL df.instance_info(i.instance_id) info;
        EXIT WHEN instance_output IS NOT NULL;
        PERFORM pg_sleep(0.1);
    END LOOP;

    IF COALESCE(instance_output, '') NOT LIKE '%$nullable is NULL%' THEN
        RAISE EXCEPTION
            'TEST FAILED [join failure priority]: fatal sibling error did not surface: %',
            instance_output;
    END IF;
END $$;

DROP TABLE _join_failure_priority_instance;
DROP SEQUENCE test_join_failure_priority_attempt_seq;

-- A fatal sibling also takes precedence over intentional break control flow.
CREATE TEMP TABLE _join_break_failure_priority_instance AS
SELECT df.start(
    df.loop(
        df.break('"break-must-not-win"')
        & (
            df.sql('SELECT NULL::int AS value') |=> 'break_nullable'
            ~> 'SELECT $break_nullable'
        ),
        continue_on_failure => true
    ),
    'test-join-fatal-over-break-priority'
) AS instance_id;

DO $$
DECLARE
    final_status TEXT;
    instance_output TEXT;
    waited INT;
BEGIN
    SELECT df.await_instance(i.instance_id, 30)
    INTO final_status
    FROM _join_break_failure_priority_instance i;

    FOR waited IN 1..100 LOOP
        SELECT info.output
        INTO instance_output
        FROM _join_break_failure_priority_instance i
        CROSS JOIN LATERAL df.instance_info(i.instance_id) info;
        EXIT WHEN instance_output IS NOT NULL;
        PERFORM pg_sleep(0.1);
    END LOOP;

    IF final_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION
            'TEST FAILED [join break priority]: expected failed, got %',
            final_status;
    END IF;
    IF COALESCE(instance_output, '') NOT LIKE '%$break_nullable is NULL%' THEN
        RAISE EXCEPTION
            'TEST FAILED [join break priority]: fatal sibling error did not surface: %',
            instance_output;
    END IF;
END $$;

DROP TABLE _join_break_failure_priority_instance;

-- Outside a failure-isolated loop, retain the historical first-branch error.
CREATE TEMP TABLE _join_legacy_failure_priority_instance AS
SELECT df.start(
    'SELECT 1 / 0'
    & (
        df.sql('SELECT NULL::int AS value') |=> 'legacy_nullable'
        ~> 'SELECT $legacy_nullable'
    ),
    'test-join-legacy-first-error'
) AS instance_id;

DO $$
DECLARE
    final_status TEXT;
    instance_output TEXT;
    waited INT;
BEGIN
    SELECT df.await_instance(i.instance_id, 30)
    INTO final_status
    FROM _join_legacy_failure_priority_instance i;

    FOR waited IN 1..100 LOOP
        SELECT info.output
        INTO instance_output
        FROM _join_legacy_failure_priority_instance i
        CROSS JOIN LATERAL df.instance_info(i.instance_id) info;
        EXIT WHEN instance_output IS NOT NULL;
        PERFORM pg_sleep(0.1);
    END LOOP;

    IF final_status IS DISTINCT FROM 'failed' THEN
        RAISE EXCEPTION
            'TEST FAILED [join legacy priority]: expected failed, got %',
            final_status;
    END IF;
    IF COALESCE(instance_output, '') NOT LIKE '%division by zero%' THEN
        RAISE EXCEPTION
            'TEST FAILED [join legacy priority]: first branch error changed: %',
            instance_output;
    END IF;
END $$;

DROP TABLE _join_legacy_failure_priority_instance;
RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
