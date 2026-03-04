-- Test: Superuser durable SQL execution
--
-- This test is intentionally run as a superuser by the E2E harness.
-- It verifies that durable functions work when submitted by a superuser,
-- and exercises a superuser-only query (pg_authid).

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state
SELECT df.start(
    df.sql('SELECT (SELECT rolname FROM pg_authid LIMIT 1) AS any_role'),
    'test-superuser-pg_authid'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed, got %', status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result NOT LIKE '%any_role%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected result to contain any_role, got %', result;
    END IF;

    RAISE NOTICE 'TEST PASSED: superuser durable sql (pg_authid)';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
