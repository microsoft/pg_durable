-- Test: Function Templates
-- Tests template creation, instantiation, and management
-- Expected: Templates can be created, started, and managed properly

-- Cleanup any existing templates
DO $$
DECLARE
    tpl RECORD;
BEGIN
    FOR tpl IN SELECT name FROM df.templates WHERE active = true AND name LIKE 'test_%' LOOP
        PERFORM df.drop_template(tpl.name);
    END LOOP;
END $$;

DROP TABLE IF EXISTS test_template_log;
CREATE TABLE test_template_log (
    id SERIAL PRIMARY KEY,
    step TEXT,
    value INT,
    ts TIMESTAMP DEFAULT now()
);

-- Test 1: Create a simple template
DO $$
DECLARE
    result TEXT;
BEGIN
    result := df.create_template(
        'test_simple',
        'INSERT INTO test_template_log (step, value) VALUES (''simple'', 1)',
        'A simple template test'
    );
    RAISE NOTICE 'Created template: %', result;
END $$;

-- Test 2: Start template and verify execution
CREATE TEMP TABLE _test_state (instance_id TEXT, test_name TEXT);

INSERT INTO _test_state SELECT df.start_template('test_simple', 'test-simple-1'), 'simple';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
    cnt INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'simple';
    RAISE NOTICE 'Started template instance: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [simple template]: status = %', status;
    END IF;
    
    SELECT COUNT(*) INTO cnt FROM test_template_log WHERE step = 'simple';
    IF cnt != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [simple template]: expected 1 row, got %', cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: simple template';
END $$;

-- Test 3: Create template with sequence
DO $$
DECLARE
    result TEXT;
BEGIN
    result := df.create_template(
        'test_sequence',
        'INSERT INTO test_template_log (step, value) VALUES (''seq1'', 1) ~> INSERT INTO test_template_log (step, value) VALUES (''seq2'', 2)',
        'A sequence template'
    );
    RAISE NOTICE 'Created sequence template: %', result;
END $$;

INSERT INTO _test_state SELECT df.start_template('test_sequence', 'test-seq-1'), 'sequence';

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
    steps TEXT[];
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state WHERE test_name = 'sequence';
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [sequence template]: status = %', status;
    END IF;
    
    SELECT array_agg(step ORDER BY id) INTO steps 
    FROM test_template_log WHERE step IN ('seq1', 'seq2');
    
    IF steps != ARRAY['seq1', 'seq2'] THEN
        RAISE EXCEPTION 'TEST FAILED [sequence template]: expected [seq1, seq2], got %', steps;
    END IF;
    
    RAISE NOTICE 'PASSED: sequence template';
END $$;

-- Test 4: List templates
DO $$
DECLARE
    templates JSONB;
    cnt INT;
BEGIN
    templates := df.list_templates();
    cnt := jsonb_array_length(templates);
    
    IF cnt < 2 THEN
        RAISE EXCEPTION 'TEST FAILED [list templates]: expected at least 2 templates, got %', cnt;
    END IF;
    
    RAISE NOTICE 'PASSED: list templates (found %)', cnt;
END $$;

-- Test 5: Get template details
DO $$
DECLARE
    tpl_details JSONB;
    tpl_name TEXT;
BEGIN
    tpl_details := df.get_template('test_simple');
    tpl_name := tpl_details->>'name';
    
    IF tpl_name != 'test_simple' THEN
        RAISE EXCEPTION 'TEST FAILED [get template]: expected test_simple, got %', tpl_name;
    END IF;
    
    RAISE NOTICE 'PASSED: get template';
END $$;

-- Test 6: Update template description
DO $$
DECLARE
    result TEXT;
    tpl_details JSONB;
    new_desc TEXT;
BEGIN
    result := df.update_template('test_simple', NULL, 'Updated description');
    tpl_details := df.get_template('test_simple');
    new_desc := tpl_details->>'description';
    
    IF new_desc != 'Updated description' THEN
        RAISE EXCEPTION 'TEST FAILED [update template description]: expected "Updated description", got %', new_desc;
    END IF;
    
    RAISE NOTICE 'PASSED: update template description';
END $$;

-- Test 7: Drop template
DO $$
DECLARE
    result TEXT;
    templates JSONB;
    found BOOLEAN := FALSE;
    i INT;
BEGIN
    result := df.drop_template('test_simple');
    templates := df.list_templates();
    
    -- Check that test_simple is no longer in the list
    FOR i IN 0..(jsonb_array_length(templates) - 1) LOOP
        IF (templates->i->>'name') = 'test_simple' THEN
            found := TRUE;
        END IF;
    END LOOP;
    
    IF found THEN
        RAISE EXCEPTION 'TEST FAILED [drop template]: template still exists after drop';
    END IF;
    
    RAISE NOTICE 'PASSED: drop template';
END $$;

-- Cleanup
DO $$
DECLARE
    tpl RECORD;
BEGIN
    FOR tpl IN SELECT name FROM df.templates WHERE active = true AND name LIKE 'test_%' LOOP
        PERFORM df.drop_template(tpl.name);
    END LOOP;
END $$;

DROP TABLE _test_state;
DROP TABLE test_template_log;
SELECT 'TEST PASSED' AS result;
