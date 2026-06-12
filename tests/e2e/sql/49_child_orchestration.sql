-- Tests: df.call_child convenience wrapper and df.await_instance durable wait
SET SESSION AUTHORIZATION df_e2e_user;

DROP TABLE IF EXISTS test_child_orchestration_log;
CREATE TABLE test_child_orchestration_log (
    id SERIAL PRIMARY KEY,
    msg TEXT NOT NULL,
    data JSONB NOT NULL
);

-- === Test 1: df.call_child starts a child instance and waits for completion ===
CREATE TEMP TABLE _test_call_child_parent (instance_id TEXT);

INSERT INTO _test_call_child_parent
SELECT df.start(
    df.call_child(
        'SELECT json_build_object(''value'', 42, ''kind'', ''child'')',
        'call-child-child',
        '{"timeout_seconds": 30}'::jsonb
    ) |=> 'child'
    ~> 'INSERT INTO test_child_orchestration_log (msg, data) VALUES (''call_child'', $child::jsonb)',
    'call-child-parent'
);

DO $$
DECLARE
    parent_id TEXT;
    parent_status TEXT;
    child_instance_id TEXT;
BEGIN
    SELECT instance_id INTO parent_id FROM _test_call_child_parent;
    SELECT df.wait_for_completion(parent_id, 30) INTO parent_status;

    IF parent_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: call_child parent status = %', parent_status;
    END IF;

    SELECT data->>'instance_id'
      INTO child_instance_id
      FROM test_child_orchestration_log
     WHERE msg = 'call_child'
     ORDER BY id DESC
     LIMIT 1;

    IF child_instance_id IS NULL OR child_instance_id = parent_id THEN
        RAISE EXCEPTION 'TEST FAILED: call_child did not record a distinct child instance_id';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM test_child_orchestration_log
         WHERE msg = 'call_child'
           AND data->>'status' = 'completed'
           AND data->'result'->'rows'->0->'json_build_object'->>'value' = '42'
           AND data->'result'->'rows'->0->'json_build_object'->>'kind' = 'child'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: call_child result envelope missing expected child output';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM df.instances
         WHERE id = child_instance_id
           AND label = 'call-child-child'
           AND status = 'completed'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: child instance metadata missing or not completed';
    END IF;

    RAISE NOTICE 'TEST PASSED: call_child';
END $$;

DROP TABLE _test_call_child_parent;
DELETE FROM test_child_orchestration_log;

-- === Test 2: df.await_instance durably waits on an existing instance ===
CREATE TEMP TABLE _test_direct_child AS
SELECT df.start(
    'SELECT json_build_object(''source'', ''direct-child'', ''ok'', true)',
    'direct-await-child'
) AS child_instance_id;

CREATE TEMP TABLE _test_direct_parent AS
SELECT df.start(
    df.await_instance((SELECT child_instance_id FROM _test_direct_child), 30) |=> 'awaited'
    ~> 'INSERT INTO test_child_orchestration_log (msg, data) VALUES (''await_instance'', $awaited::jsonb)',
    'direct-await-parent'
) AS parent_instance_id;

DO $$
DECLARE
    parent_id TEXT;
    child_id TEXT;
    parent_status TEXT;
BEGIN
    SELECT parent_instance_id INTO parent_id FROM _test_direct_parent;
    SELECT child_instance_id INTO child_id FROM _test_direct_child;
    SELECT df.wait_for_completion(parent_id, 30) INTO parent_status;

    IF parent_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: await_instance parent status = %', parent_status;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM test_child_orchestration_log
         WHERE msg = 'await_instance'
           AND data->>'instance_id' = child_id
           AND data->>'status' = 'completed'
           AND data->'result'->'rows'->0->'json_build_object'->>'source' = 'direct-child'
           AND (data->'result'->'rows'->0->'json_build_object'->>'ok')::boolean = true
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: await_instance result envelope missing expected child output';
    END IF;

    RAISE NOTICE 'TEST PASSED: await_instance';
END $$;

DROP TABLE _test_direct_parent;
DROP TABLE _test_direct_child;
DROP TABLE test_child_orchestration_log;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
