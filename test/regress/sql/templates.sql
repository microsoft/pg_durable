-- Test: Template registration, instantiation, and deletion
-- Uses df.wait_for_completion() for deterministic output

-- Cleanup
DROP TABLE IF EXISTS template_test_table;
CREATE TABLE template_test_table (id INT, result TEXT);

-- Test 1: Create template for simple substitution
SELECT df.create_template(
    'test_template',
    $$df.sql('SELECT {value}::int as result')$$,
    'Simple test template'
);

-- Verify template was created
SELECT name, dsl_template, description
FROM df.templates
WHERE name = 'test_template' AND active = true
ORDER BY name;

-- Test 2: Instantiate template and wait for completion
SELECT df.start_template(
    'test_template',
    'test-label',
    jsonb_build_object('value', '42')
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify result
SELECT result->'rows'->0->>'result' as result
FROM df.nodes
WHERE instance_id = :'instance_id' AND result IS NOT NULL
ORDER BY created_at DESC
LIMIT 1;

-- Test 3: Create template with sequence operator
SELECT df.create_template(
    'sequence_template',
    $$'SELECT {x}::int as val' ~> df.sql('SELECT {y}::int as val')$$,
    'Template with sequence'
);

-- Instantiate and wait
SELECT df.start_template(
    'sequence_template',
    'seq-test',
    jsonb_build_object('x', '1', 'y', '2')
) AS instance_id \gset

SELECT df.wait_for_completion(:'instance_id') AS status;

-- Test 4: List templates
SELECT name, description
FROM df.list_templates()
WHERE name IN ('test_template', 'sequence_template')
ORDER BY name;

-- Test 5: Get template details
SELECT (df.get_template('test_template')->>'name') as name,
       (df.get_template('test_template')->>'description') as description;

-- Test 6: Drop template (soft delete)
SELECT df.drop_template('test_template');

-- Verify it's inactive
SELECT COUNT(*) as inactive_count
FROM df.templates
WHERE name = 'test_template' AND active = false;

-- Test 7: Cannot instantiate dropped template
\set ON_ERROR_STOP 0
SELECT df.start_template('test_template', NULL, '{}'::jsonb);
\set ON_ERROR_STOP 1

-- Cleanup
SELECT df.drop_template('sequence_template');
DROP TABLE template_test_table;
