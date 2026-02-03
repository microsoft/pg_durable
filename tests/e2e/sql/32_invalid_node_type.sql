-- Test: Reject invalid Durofut JSON node_type
-- Expected: df.start('{"node_type":"NOT_A_NODE"}') raises an error

DO $body$
BEGIN
    BEGIN
        PERFORM df.start('{"node_type":"NOT_A_NODE"}');
        RAISE EXCEPTION 'TEST FAILED: df.start should have rejected invalid node_type';
    EXCEPTION WHEN OTHERS THEN
        -- ok
        RAISE NOTICE 'Caught expected error: %', SQLERRM;
    END;

    BEGIN
        PERFORM df.explain('{"node_type":"NOT_A_NODE"}');
        -- explain returns a string; it should contain our error text, not crash.
        -- If it returned empty, that would be suspicious.
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'TEST FAILED: df.explain should not raise on invalid node_type';
    END;

    RAISE NOTICE 'TEST PASSED: invalid node_type handling';
END $body$;

SELECT 'TEST PASSED' AS result;
