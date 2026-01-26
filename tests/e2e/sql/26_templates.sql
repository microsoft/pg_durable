-- Test: Function Templates
-- Tests template registration, instantiation, update, deletion, and inspection

-- Cleanup from previous runs (delete instances first due to FK constraint)
DELETE FROM df.instances WHERE template_id IN (
    SELECT id FROM df.templates WHERE name IN ('test_template', 'multi_param_template', 'updated_template')
);
DELETE FROM df.templates WHERE name IN ('test_template', 'multi_param_template', 'updated_template');

-- Test 1: Template registration
SELECT df.create_template(
    'test_template',
    $$df.sql('SELECT COUNT(*) as count FROM {schema_name}.test_template_users')$$,
    'Test template for counting users'
);

-- Verify registration
DO $$
DECLARE
    template_count INT;
    template_sql TEXT;
BEGIN
    SELECT COUNT(*) INTO template_count FROM df.templates WHERE name = 'test_template' AND active = true;
    IF template_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Template not registered';
    END IF;
    
    SELECT dsl_template INTO template_sql FROM df.templates WHERE name = 'test_template' AND active = true;
    IF template_sql NOT LIKE '%{schema_name}%' THEN
        RAISE EXCEPTION 'TEST FAILED: Template DSL missing placeholder';
    END IF;
    
    RAISE NOTICE 'Template registered successfully';
END $$;

-- Test 2: Template instantiation and execution
DROP TABLE IF EXISTS test_template_users;
CREATE TABLE test_template_users (id INT, name TEXT);
INSERT INTO test_template_users VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Charlie');

CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state SELECT df.start_template(
    'test_template',
    'test-label',
    jsonb_build_object('schema_name', 'public')
);

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Started instance: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Template instantiation status = %', status;
    END IF;
    
    RAISE NOTICE 'Template instantiation completed successfully';
END $$;

-- Verify template_id was recorded
DO $$
DECLARE
    inst_id TEXT;
    tmpl_id BIGINT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT template_id INTO tmpl_id
    FROM df.instances WHERE id = inst_id;
    
    IF tmpl_id IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: template_id not recorded';
    END IF;
    
    RAISE NOTICE 'Template ID recorded correctly: %', tmpl_id;
END $$;

-- Test 3: Duplicate active template registration should fail
DO $$
BEGIN
    PERFORM df.create_template('test_template', 'SELECT {x}');
    RAISE EXCEPTION 'TEST FAILED: Should have failed on duplicate template';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%already exists%' THEN
            RAISE EXCEPTION 'TEST FAILED: Wrong error message: %', SQLERRM;
        END IF;
        RAISE NOTICE 'Duplicate registration correctly rejected';
END $$;

-- NOTE: Variable validation happens at orchestration time, not at start_template time.
-- Missing or extra variables will be detected during execution, not during template instantiation.

-- Test 4: df.get_template()
DO $$
DECLARE
    template_json JSONB;
BEGIN
    SELECT df.get_template('test_template') INTO template_json;
    
    IF template_json->>'name' != 'test_template' THEN
        RAISE EXCEPTION 'TEST FAILED: get_template returned wrong name';
    END IF;
    
    IF template_json->>'description' != 'Test template for counting users' THEN
        RAISE EXCEPTION 'TEST FAILED: get_template returned wrong description';
    END IF;
    
    IF template_json->>'dsl_template' NOT LIKE '%{schema_name}%' THEN
        RAISE EXCEPTION 'TEST FAILED: get_template returned unexpected DSL';
    END IF;
    
    RAISE NOTICE 'get_template works correctly';
END $$;

-- Test 5: df.list_templates()
DO $$
DECLARE
    template_count INT;
    rec RECORD;
BEGIN
    SELECT COUNT(*) INTO template_count FROM df.list_templates();
    
    IF template_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: list_templates returned no results';
    END IF;
    
    FOR rec IN SELECT * FROM df.list_templates() WHERE name = 'test_template' LOOP
        IF rec.description != 'Test template for counting users' THEN
            RAISE EXCEPTION 'TEST FAILED: list_templates returned wrong description';
        END IF;
        IF rec.created_by IS DISTINCT FROM current_user THEN
            RAISE EXCEPTION 'TEST FAILED: list_templates returned wrong creator';
        END IF;
    END LOOP;
    
    RAISE NOTICE 'list_templates works correctly';
END $$;

-- Test 6: df.explain_template() - needs template with operators
-- Create a template with DSL operators for explain test
SELECT df.create_template(
    'explain_test_template',
    $$'SELECT COUNT(*) as count FROM {schema_name}.test_template_users' 
    ~> df.sql('SELECT ''done'' as result')$$,
    'Template with sequence operator for explain test'
);

DO $$
DECLARE
    explanation TEXT;
BEGIN
    SELECT df.explain_template('explain_test_template') INTO explanation;
    
    IF explanation IS NULL OR explanation = '' THEN
        RAISE EXCEPTION 'TEST FAILED: explain_template returned empty result';
    END IF;
    
    -- Verify placeholder is still present (not substituted)
    IF explanation NOT LIKE '%{schema_name}%' THEN
        RAISE EXCEPTION 'TEST FAILED: explain_template should preserve placeholders, got: %', explanation;
    END IF;

    RAISE NOTICE 'explain_template works correctly';
END $$;

-- Clean up explain test template
SELECT df.drop_template('explain_test_template');

-- Test 7: Update template - DSL only (creates new version)
SELECT df.update_template(
    'test_template',
    dsl_template := $$df.sql('SELECT COUNT(*) as count FROM {schema_name}.test_template_users WHERE id > 1')$$
);

-- Verify new version was created and old one marked inactive
DO $$
DECLARE
    active_count INT;
    inactive_count INT;
    old_desc TEXT;
BEGIN
    SELECT COUNT(*) INTO active_count FROM df.templates WHERE name = 'test_template' AND active = true;
    SELECT COUNT(*) INTO inactive_count FROM df.templates WHERE name = 'test_template' AND active = false;
    
    IF active_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 active version, got %', active_count;
    END IF;
    
    IF inactive_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Expected 1 inactive version, got %', inactive_count;
    END IF;
    
    -- Check that old description was preserved
    SELECT description INTO old_desc FROM df.templates WHERE name = 'test_template' AND active = true;
    IF old_desc != 'Test template for counting users' THEN
        RAISE EXCEPTION 'TEST FAILED: Description not preserved on update';
    END IF;
    
    RAISE NOTICE 'Template updated correctly with new version';
END $$;

-- Test 8: Update template - description only (in-place update)
SELECT df.update_template(
    'test_template',
    description := 'Updated description for test template'
);

-- Verify description was updated without creating new version
DO $$
DECLARE
    version_count INT;
    new_desc TEXT;
BEGIN
    SELECT COUNT(*) INTO version_count FROM df.templates WHERE name = 'test_template';
    
    IF version_count != 2 THEN
        RAISE EXCEPTION 'TEST FAILED: Description update should not create new version, got % versions', version_count;
    END IF;
    
    SELECT description INTO new_desc FROM df.templates WHERE name = 'test_template' AND active = true;
    IF new_desc != 'Updated description for test template' THEN
        RAISE EXCEPTION 'TEST FAILED: Description not updated';
    END IF;
    
    RAISE NOTICE 'Template description updated correctly';
END $$;

-- Test 9: Drop template (soft delete)
SELECT df.drop_template('test_template');

-- Verify template is marked inactive but still exists
DO $$
DECLARE
    active_count INT;
    total_count INT;
BEGIN
    SELECT COUNT(*) INTO active_count FROM df.templates WHERE name = 'test_template' AND active = true;
    SELECT COUNT(*) INTO total_count FROM df.templates WHERE name = 'test_template';
    
    IF active_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED: Template should be inactive after drop';
    END IF;
    
    IF total_count = 0 THEN
        RAISE EXCEPTION 'TEST FAILED: Template should still exist in database after drop';
    END IF;
    
    RAISE NOTICE 'Template dropped correctly (marked inactive)';
END $$;

-- Test 10: Cannot instantiate inactive template
DO $$
BEGIN
    PERFORM df.start_template('test_template', NULL, jsonb_build_object('schema_name', 'public'));
    RAISE EXCEPTION 'TEST FAILED: Should not be able to instantiate inactive template';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%not found%' THEN
            RAISE EXCEPTION 'TEST FAILED: Wrong error message: %', SQLERRM;
        END IF;
        RAISE NOTICE 'Inactive template correctly rejected';
END $$;

-- Test 11: Can create new template with same name after drop
SELECT df.create_template(
    'test_template',
    $$'SELECT 1 as result'$$,
    'New template with same name'
);

-- Verify new template was created
DO $$
DECLARE
    active_count INT;
    total_count INT;
BEGIN
    SELECT COUNT(*) INTO active_count FROM df.templates WHERE name = 'test_template' AND active = true;
    SELECT COUNT(*) INTO total_count FROM df.templates WHERE name = 'test_template';
    
    IF active_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Should have 1 active template';
    END IF;
    
    IF total_count < 3 THEN
        RAISE EXCEPTION 'TEST FAILED: Old versions should still exist';
    END IF;
    
    RAISE NOTICE 'New template created successfully with same name';
END $$;

-- Test 12: Complex template with multiple variables
SELECT df.create_template(
    'parallel_counts',
    $$df.sql('SELECT COUNT(*) as users FROM {schema_name}.test_template_users')
    & df.sql('SELECT 1 as dummy')
    ~> df.sql('SELECT ''done'' as result')$$,
    'Parallel operations template'
);

-- Verify template registered
DO $$
DECLARE
    template_sql TEXT;
BEGIN
    SELECT dsl_template INTO template_sql FROM df.templates WHERE name = 'parallel_counts' AND active = true;
    IF template_sql NOT LIKE '%{schema_name}%' THEN
        RAISE EXCEPTION 'TEST FAILED: parallel_counts template missing placeholder';
    END IF;
    
    RAISE NOTICE 'Complex template created successfully';
END $$;

-- Start instance from complex template
DELETE FROM _test_state;
INSERT INTO _test_state SELECT df.start_template(
    'parallel_counts',
    'parallel-test',
    jsonb_build_object('schema_name', 'public')
);

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Complex template status = %', status;
    END IF;
    
    RAISE NOTICE 'Complex template executed successfully';
END $$;

-- Cleanup
SELECT df.drop_template('test_template');
SELECT df.drop_template('parallel_counts');
DROP TABLE IF EXISTS _test_state;
DROP TABLE IF EXISTS test_template_users;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;

SELECT 'TEST PASSED' AS result;
