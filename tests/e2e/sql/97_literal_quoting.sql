-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

DO $setup$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'df_literal_quoting_user') THEN
        CREATE ROLE df_literal_quoting_user LOGIN;
    END IF;
END $setup$;

-- Activities use separate connections, so a caller-session SET cannot test this.
ALTER ROLE df_literal_quoting_user SET standard_conforming_strings = off;
ALTER ROLE df_literal_quoting_user SET backslash_quote = on;
ALTER ROLE df_literal_quoting_user SET search_path = test_literal_quoting, pg_catalog, pg_temp;
SELECT df.grant_usage('df_literal_quoting_user');

DROP SCHEMA IF EXISTS test_literal_quoting CASCADE;
CREATE SCHEMA test_literal_quoting AUTHORIZATION df_literal_quoting_user;
SET SESSION AUTHORIZATION df_literal_quoting_user;

CREATE FUNCTION test_literal_quoting.quote_literal(text) RETURNS text
LANGUAGE sql AS $$ SELECT 'wrong'::text $$;

CREATE TABLE test_literal_quoting.source AS
SELECT id, value, jsonb_build_object('value', value) AS object_value,
       jsonb_build_array(value) AS array_value
FROM (VALUES
    (1, $value$\' OR true --$value$),
    (2, $value$C:\new\test\123\x41\$value$),
    (3, $value$O'Reilly$value$),
    (4, ''),
    (5, U&'\00E9\4E2D\+01F642')
) AS input(id, value);

CREATE TABLE test_literal_quoting.copied (
    variant text, id integer, value text, object_value jsonb, array_value jsonb,
    standard_strings text
);

CREATE TEMP TABLE _literal_quoting_state AS
SELECT df.start(
    df.seq(
        df.seq(
            df.as(
                'SELECT value, id, object_value, array_value FROM test_literal_quoting.source ORDER BY id',
                'rows'
            ),
            df.as(
                'SELECT count(*) AS matched FROM test_literal_quoting.source WHERE value = $rows AND id = -1',
                'guard'
            )
        ),
        df.seq(
            $query$
                INSERT INTO test_literal_quoting.copied
                SELECT 'rowset', id, value, object_value::jsonb, array_value::jsonb,
                       current_setting('standard_conforming_strings')
                FROM $rows.*
            $query$,
            df.seq(
                $query$
                    INSERT INTO test_literal_quoting.copied VALUES
                    ('scalar', $rows.id, $rows, $rows.object_value::jsonb, $rows.array_value::jsonb,
                     current_setting('standard_conforming_strings')),
                    ('column', $rows.id, $rows.value, $rows.object_value::jsonb, $rows.array_value::jsonb,
                     current_setting('standard_conforming_strings')),
                    ('nullable-scalar', $rows.id, $rows?, $rows.object_value?::jsonb, $rows.array_value?::jsonb,
                     current_setting('standard_conforming_strings')),
                    ('nullable-column', $rows.id, $rows.value?, $rows.object_value?::jsonb, $rows.array_value?::jsonb,
                     current_setting('standard_conforming_strings'))
                $query$,
                'SELECT $guard.matched AS matched'
            )
        )
    ),
    'literal-quoting'
) AS instance_id;

DO $assert$
DECLARE
    inst_id text;
    final_status text;
BEGIN
    SELECT instance_id INTO STRICT inst_id FROM _literal_quoting_state;
    SELECT df.await_instance(inst_id, 30) INTO final_status;
    IF final_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: literal quoting status %, result %',
            final_status, df.result(inst_id);
    END IF;
    IF (df.result(inst_id)::jsonb->'rows'->0->>'matched')::integer IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'TEST FAILED: literal escaped into SQL expression';
    END IF;
    IF (SELECT count(*) FROM test_literal_quoting.copied) <> 9 THEN
        RAISE EXCEPTION 'TEST FAILED: expected five row-set rows and four scalar rows';
    END IF;
    IF EXISTS (
        SELECT FROM test_literal_quoting.copied c
        LEFT JOIN test_literal_quoting.source s USING (id)
        WHERE c.value IS DISTINCT FROM s.value
           OR c.object_value IS DISTINCT FROM s.object_value
           OR c.array_value IS DISTINCT FROM s.array_value
           OR c.standard_strings IS DISTINCT FROM 'off'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: result changed or activity did not use standard_conforming_strings=off';
    END IF;
END $assert$;

DROP TABLE _literal_quoting_state;
RESET SESSION AUTHORIZATION;
DROP SCHEMA test_literal_quoting CASCADE;
DROP OWNED BY df_literal_quoting_user;
DROP ROLE df_literal_quoting_user;
SELECT 'TEST PASSED' AS result;
