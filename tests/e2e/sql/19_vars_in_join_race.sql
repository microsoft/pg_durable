-- Tests: vars and label propagation into JOIN and RACE subtrees
-- Repro for: Bug: vars and label lost in JOIN/RACE subtrees
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test: vars in JOIN branches ===

SELECT df.clearvars();
SELECT df.setvar('magic', '42');

CREATE TEMP TABLE _test_join_vars (instance_id TEXT);

INSERT INTO _test_join_vars SELECT df.start(
    'SELECT ''{magic}'' AS val' & 'SELECT ''branch_b'' AS val',
    'test-vars-in-join'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    join_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_join_vars;
    RAISE NOTICE 'Testing vars in JOIN branches: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-join]: status = %', status;
    END IF;

    SELECT result::text INTO join_result
    FROM df.instances
    WHERE id = inst_id;

    IF join_result NOT LIKE '%42%' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-join]: expected "42" in result, got %', join_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: vars_in_join';
END $$;

DROP TABLE _test_join_vars;

-- === Test: sys_label in JOIN branches ===

SELECT df.clearvars();

CREATE TEMP TABLE _test_join_label (instance_id TEXT);

INSERT INTO _test_join_label SELECT df.start(
    'SELECT ''{sys_label}'' AS lbl' & 'SELECT ''branch_b'' AS lbl',
    'test-label-in-join'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    join_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_join_label;
    RAISE NOTICE 'Testing sys_label in JOIN branches: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [label-in-join]: status = %', status;
    END IF;

    SELECT result::text INTO join_result
    FROM df.instances
    WHERE id = inst_id;

    IF join_result NOT LIKE '%test-label-in-join%' THEN
        RAISE EXCEPTION 'TEST FAILED [label-in-join]: expected label in result, got %', join_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: label_in_join';
END $$;

DROP TABLE _test_join_label;

-- === Test: vars in RACE branches ===

SELECT df.clearvars();
SELECT df.setvar('race_val', 'hello');

CREATE TEMP TABLE _test_race_vars (instance_id TEXT);

INSERT INTO _test_race_vars SELECT df.start(
    'SELECT ''{race_val}'' AS val' | 'SELECT ''other'' AS val',
    'test-vars-in-race'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    race_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_race_vars;
    RAISE NOTICE 'Testing vars in RACE branches: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-race]: status = %', status;
    END IF;

    -- The winning branch used the var correctly (not empty string)
    SELECT result::text INTO race_result
    FROM df.instances
    WHERE id = inst_id;

    IF race_result LIKE '%""val"":"""%' OR race_result LIKE '%"val":""' THEN
        RAISE EXCEPTION 'TEST FAILED [vars-in-race]: var was empty string, got %', race_result;
    END IF;

    RAISE NOTICE 'TEST PASSED: vars_in_race';
END $$;

DROP TABLE _test_race_vars;

SELECT df.clearvars();

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
