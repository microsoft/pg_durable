-- Test: Simple SQL execution
-- Tests both auto-wrapped SQL and explicit df.sql() function

-- Test A: Auto-wrapped SQL (plain string)
SELECT df.start('SELECT 42 as answer', 'test-simple-auto') AS instance_id \gset
SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify result contains 42
SELECT df.result(:'instance_id')::jsonb->'rows'->0->'answer' AS answer;

-- Test B: Explicit df.sql() function
SELECT df.start(df.sql('SELECT 42 as answer'), 'test-simple-func') AS instance_id \gset
SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify result contains 42
SELECT df.result(:'instance_id')::jsonb->'rows'->0->'answer' AS answer;

-- Test C: Multi-row, multi-column result
SELECT df.start(df.sql('SELECT 1 as col1, ''a'' as col2 UNION ALL SELECT 2, ''b'''), 'test-simple-multi') AS instance_id \gset
SELECT df.wait_for_completion(:'instance_id') AS status;

-- Verify result contains 2 rows with expected values
SELECT df.result(:'instance_id')::jsonb->'rows'->0->'col1' AS row1_col1;
SELECT df.result(:'instance_id')::jsonb->'rows'->0->'col2' AS row1_col2;
SELECT df.result(:'instance_id')::jsonb->'rows'->1->'col1' AS row2_col1;
SELECT df.result(:'instance_id')::jsonb->'rows'->1->'col2' AS row2_col2;
