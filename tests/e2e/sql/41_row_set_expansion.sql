-- Test: Row-set expansion ($name.*)
-- Tests $name.* in FROM clause and WHERE IN subquery, plus empty result handling

-- ============================================================================
-- Test 1: $batch.* in FROM clause — multi-row expansion
-- ============================================================================

DROP TABLE IF EXISTS test_rowset_results;
CREATE TABLE test_rowset_results (id SERIAL, total_rows INT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT id, val FROM (VALUES (1, 'a'), (2, 'b'), (3, 'c')) AS t(id, val)$$ |=> 'batch'
    ~> $$INSERT INTO test_rowset_results (total_rows) SELECT count(*) FROM $batch.*$$,
    'test-rowset-from'
), 'from_clause';

-- ============================================================================
-- Test 2: $batch.* in WHERE IN subquery
-- ============================================================================

DROP TABLE IF EXISTS test_rowset_source;
CREATE TABLE test_rowset_source (id INT, name TEXT);
INSERT INTO test_rowset_source VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Carol'), (4, 'Dave');

DROP TABLE IF EXISTS test_rowset_filtered;
CREATE TABLE test_rowset_filtered (id SERIAL, cnt INT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT id FROM test_rowset_source WHERE id <= 2$$ |=> 'ids'
    ~> $$INSERT INTO test_rowset_filtered (cnt) SELECT count(*) FROM test_rowset_source WHERE id IN (SELECT id FROM $ids.*)$$,
    'test-rowset-where-in'
), 'where_in';

-- ============================================================================
-- Test 3: Empty result set expansion — should not error
-- ============================================================================

DROP TABLE IF EXISTS test_rowset_empty;
CREATE TABLE test_rowset_empty (id SERIAL, total_rows INT);

INSERT INTO _test_state SELECT df.start(
    $$SELECT id FROM test_rowset_source WHERE false$$ |=> 'none'
    ~> $$INSERT INTO test_rowset_empty (total_rows) SELECT count(*) FROM $none.*$$,
    'test-rowset-empty'
), 'empty';

DO $$
DECLARE
    rec RECORD;
    status TEXT;
    int_val INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state ORDER BY variant LOOP
        RAISE NOTICE 'Testing % variant: %', rec.variant, rec.instance_id;

        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;

        IF rec.variant = 'empty' THEN
            -- Empty expansion: count(*) from empty subquery = 0
            SELECT total_rows INTO int_val FROM test_rowset_empty ORDER BY id DESC LIMIT 1;
            IF int_val != 0 THEN
                RAISE EXCEPTION 'TEST FAILED [empty]: expected 0 rows, got %', int_val;
            END IF;

        ELSIF rec.variant = 'from_clause' THEN
            -- FROM expansion: 3 rows from VALUES
            SELECT total_rows INTO int_val FROM test_rowset_results ORDER BY id ASC LIMIT 1;
            IF int_val != 3 THEN
                RAISE EXCEPTION 'TEST FAILED [from_clause]: expected 3 rows, got %', int_val;
            END IF;

        ELSIF rec.variant = 'where_in' THEN
            -- WHERE IN expansion: only ids 1,2 matched
            SELECT cnt INTO int_val FROM test_rowset_filtered ORDER BY id DESC LIMIT 1;
            IF int_val != 2 THEN
                RAISE EXCEPTION 'TEST FAILED [where_in]: expected 2 rows, got %', int_val;
            END IF;
        END IF;

        RAISE NOTICE 'PASSED: row-set expansion [%]', rec.variant;
    END LOOP;

    RAISE NOTICE 'TEST PASSED: row-set expansion (all variants)';
END $$;

DROP TABLE _test_state;
DROP TABLE test_rowset_results;
DROP TABLE test_rowset_empty;
DROP TABLE test_rowset_filtered;
DROP TABLE test_rowset_source;
SELECT 'TEST PASSED' AS result;
