-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

DROP SCHEMA IF EXISTS schema_qualification CASCADE;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'schema_qualification_user') THEN
        DROP OWNED BY schema_qualification_user;
        DROP ROLE schema_qualification_user;
    END IF;
END $$;
CREATE ROLE schema_qualification_user LOGIN;
CREATE SCHEMA schema_qualification AUTHORIZATION schema_qualification_user;
SELECT df.grant_usage('schema_qualification_user');

DO $$
DECLARE
    type_name text;
BEGIN
    FOREACH type_name IN ARRAY ARRAY['text', 'name', 'oid', 'timestamptz']
    LOOP
        EXECUTE format(
            'CREATE FUNCTION schema_qualification.unexpected(%1$s, %1$s)
             RETURNS boolean LANGUAGE plpgsql AS $body$
             BEGIN RAISE EXCEPTION ''schema qualification operator trap''; END $body$',
            type_name
        );
    END LOOP;
END $$;
CREATE OPERATOR schema_qualification.= (
    LEFTARG = text, RIGHTARG = text, FUNCTION = schema_qualification.unexpected
);
CREATE OPERATOR schema_qualification.= (
    LEFTARG = name, RIGHTARG = name, FUNCTION = schema_qualification.unexpected
);
CREATE OPERATOR schema_qualification.= (
    LEFTARG = oid, RIGHTARG = oid, FUNCTION = schema_qualification.unexpected
);
CREATE OPERATOR schema_qualification.<> (
    LEFTARG = text, RIGHTARG = text, FUNCTION = schema_qualification.unexpected
);
CREATE OPERATOR schema_qualification.~ (
    LEFTARG = text, RIGHTARG = text, FUNCTION = schema_qualification.unexpected
);
CREATE OPERATOR schema_qualification.> (
    LEFTARG = text, RIGHTARG = text, FUNCTION = schema_qualification.unexpected
);
CREATE OPERATOR schema_qualification.< (
    LEFTARG = timestamptz, RIGHTARG = timestamptz, FUNCTION = schema_qualification.unexpected
);
CREATE OPERATOR schema_qualification.<= (
    LEFTARG = timestamptz, RIGHTARG = timestamptz, FUNCTION = schema_qualification.unexpected
);
CREATE FUNCTION schema_qualification.quote_ident(text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'schema qualification function trap';
END $$;
CREATE FUNCTION schema_qualification.quote_ident(name) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'schema qualification function trap';
END $$;
CREATE FUNCTION schema_qualification.to_char(timestamptz, text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'schema qualification function trap';
END $$;
CREATE FUNCTION schema_qualification.user_value() RETURNS integer LANGUAGE sql AS $$ SELECT 42 $$;

-- These also shadow casts in the separate transaction_mode => 'new' backend.
CREATE DOMAIN schema_qualification.text AS pg_catalog.text CHECK (false);
CREATE DOMAIN schema_qualification.oid AS pg_catalog.oid CHECK (false);
CREATE DOMAIN schema_qualification.regrole AS pg_catalog.regrole CHECK (false);
CREATE DOMAIN schema_qualification.int4 AS pg_catalog.int4 CHECK (false);
SELECT format(
    'ALTER ROLE schema_qualification_user IN DATABASE %I SET search_path = schema_qualification, pg_catalog',
    current_database()
) \gexec

SET SESSION AUTHORIZATION schema_qualification_user;
CREATE TEMP TABLE _qualification_instances (kind text, id text);
CREATE TEMP TABLE _qualification_observed (kind text, value text);
CREATE DOMAIN pg_temp.text AS pg_catalog.text CHECK (false);
CREATE DOMAIN pg_temp.oid AS pg_catalog.oid CHECK (false);
CREATE DOMAIN pg_temp.regrole AS pg_catalog.regrole CHECK (false);
CREATE DOMAIN pg_temp.timestamptz AS pg_catalog.timestamptz CHECK (false);
CREATE DOMAIN pg_temp.int4 AS pg_catalog.int4 CHECK (false);

-- pg_temp is intentionally implicit, so it precedes pg_catalog for type lookup.
SET search_path = schema_qualification, pg_catalog;
DO $$
BEGIN
    BEGIN
        PERFORM 'x'::pg_catalog.text = 'x'::pg_catalog.text;
        RAISE EXCEPTION 'operator trap did not resolve';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM OPERATOR(pg_catalog.<>) 'schema qualification operator trap' THEN
            RAISE;
        END IF;
    END;
    BEGIN
        PERFORM quote_ident(CURRENT_USER);
        RAISE EXCEPTION 'function trap did not resolve';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM OPERATOR(pg_catalog.<>) 'schema qualification function trap' THEN
            RAISE;
        END IF;
    END;
    BEGIN
        PERFORM 'x'::text;
        RAISE EXCEPTION 'temporary type trap did not resolve';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END $$;

SELECT df.setvar('qualification_value', '41');
INSERT INTO _qualification_observed VALUES ('getvar', df.getvar('qualification_value'));
SELECT df.setvar('qualification_remove', 'unused');
SELECT df.unsetvar('qualification_remove');
INSERT INTO _qualification_observed VALUES ('unsetvar', df.getvar('qualification_remove'));

INSERT INTO _qualification_instances VALUES (
    'caller',
    df.start('SELECT {qualification_value} AS captured, user_value() AS resolved',
             'schema-qualification', database => pg_catalog.current_database())
);
INSERT INTO _qualification_instances VALUES (
    'new',
    df.start('SELECT {qualification_value} AS captured, user_value() AS resolved',
             'schema-qualification', transaction_mode => 'new')
);
INSERT INTO _qualification_instances VALUES ('failed', df.start('SELECT 1/0'));
INSERT INTO _qualification_instances VALUES ('cancelled', df.start(df.sleep(60)));
INSERT INTO _qualification_observed
SELECT 'signal', df.signal(id, 'qualification') FROM _qualification_instances
WHERE kind OPERATOR(pg_catalog.=) 'cancelled';

INSERT INTO _qualification_observed
SELECT kind, df.await_instance(id, 30) FROM _qualification_instances
WHERE kind OPERATOR(pg_catalog.<>) 'cancelled';
SELECT df.cancel(id) FROM _qualification_instances;
INSERT INTO _qualification_observed
SELECT kind, df.status(id) FROM _qualification_instances;
INSERT INTO _qualification_observed
SELECT 'result', df.result(id) FROM _qualification_instances
WHERE kind OPERATOR(pg_catalog.=) ANY (ARRAY['caller', 'new']);
INSERT INTO _qualification_observed
SELECT 'explain', df.explain(id) FROM _qualification_instances
WHERE kind OPERATOR(pg_catalog.=) 'caller';

CREATE TEMP TABLE _qualification_basic AS SELECT * FROM df.list_instances('completed', 100);
CREATE TEMP TABLE _qualification_page1 AS
    SELECT * FROM df.list_instances('completed', 1, 'schema-qualification', NULL);
CREATE TEMP TABLE _qualification_page2 AS
    SELECT * FROM df.list_instances('completed', 1, 'schema-qualification',
        (SELECT next_cursor FROM _qualification_page1));
CREATE TEMP TABLE _qualification_info AS
    SELECT info.* FROM _qualification_instances AS i
    CROSS JOIN LATERAL df.instance_info(i.id) AS info;
CREATE TEMP TABLE _qualification_nodes AS
    SELECT nodes.* FROM _qualification_instances AS i
    CROSS JOIN LATERAL df.instance_nodes(i.id) AS nodes
    WHERE i.kind OPERATOR(pg_catalog.=) ANY (ARRAY['caller', 'new']);
CREATE TEMP TABLE _qualification_executions AS
    SELECT executions.* FROM _qualification_instances AS i
    CROSS JOIN LATERAL df.instance_executions(i.id) AS executions
    WHERE i.kind OPERATOR(pg_catalog.=) ANY (ARRAY['caller', 'new']);

SELECT df.clearvars();
INSERT INTO _qualification_observed VALUES ('clearvars', df.getvar('qualification_value'));

-- Assertions use trusted resolution; the API calls above did not.
SET search_path = pg_catalog, pg_temp;
DO $$
BEGIN
    IF (SELECT value FROM _qualification_observed WHERE kind = 'signal') IS DISTINCT FROM 'OK' THEN
        RAISE EXCEPTION 'Signal could not resolve the owning instance';
    END IF;
    IF (SELECT value FROM _qualification_observed WHERE kind = 'getvar') IS DISTINCT FROM '41'
       OR EXISTS (SELECT 1 FROM _qualification_observed
                  WHERE kind IN ('unsetvar', 'clearvars') AND value IS NOT NULL) THEN
        RAISE EXCEPTION 'Variable APIs used shadowed objects';
    END IF;
    IF EXISTS (
        SELECT 1 FROM _qualification_observed
        WHERE (kind IN ('caller', 'new') AND value IS DISTINCT FROM 'completed')
           OR (kind = 'failed' AND value IS DISTINCT FROM 'failed')
           OR (kind = 'cancelled' AND value IS DISTINCT FROM 'cancelled')
    ) THEN
        RAISE EXCEPTION 'Start/status/cancel APIs returned incorrect states';
    END IF;
    IF (SELECT count(*) FROM _qualification_observed WHERE kind = 'result') <> 2
       OR EXISTS (
           SELECT 1 FROM _qualification_observed WHERE kind = 'result'
           AND value::jsonb IS DISTINCT FROM '{"rows":[{"captured":41,"resolved":42}],"row_count":1}'::jsonb
       ) THEN
        RAISE EXCEPTION 'Result/captured variables/user search_path were not preserved';
    END IF;
    IF COALESCE((SELECT value FROM _qualification_observed WHERE kind = 'explain'), '')
       NOT LIKE '%SQL: SELECT {qualification_value} AS captured%' THEN
        RAISE EXCEPTION 'Explain did not load the graph: %',
            (SELECT value FROM _qualification_observed WHERE kind = 'explain');
    END IF;
    IF (SELECT count(*) FROM _qualification_basic) <> 2
       OR (SELECT count(*) FROM _qualification_page1) <> 1
       OR (SELECT next_cursor FROM _qualification_page1) IS NULL
       OR (SELECT count(*) FROM _qualification_page2) <> 1
       OR (SELECT next_cursor FROM _qualification_page2) IS NOT NULL
       OR (SELECT instance_id FROM _qualification_page1) = (SELECT instance_id FROM _qualification_page2)
       OR (SELECT count(*) FROM _qualification_info) <> 4 THEN
        RAISE EXCEPTION 'Monitoring filters/pagination did not preserve their result sets';
    END IF;
    IF (SELECT count(*) FROM _qualification_nodes) <> 2
       OR EXISTS (SELECT 1 FROM _qualification_nodes
                  WHERE status IS DISTINCT FROM 'completed'
                     OR result IS NULL OR status_details IS NULL)
       OR (SELECT count(*) FROM _qualification_executions) < 2 THEN
        RAISE EXCEPTION 'Node/history APIs did not return complete results';
    END IF;
END $$;

DROP TABLE _qualification_basic, _qualification_page1, _qualification_page2,
    _qualification_info, _qualification_nodes, _qualification_executions,
    _qualification_observed, _qualification_instances;
DROP DOMAIN pg_temp.text, pg_temp.oid, pg_temp.regrole, pg_temp.timestamptz, pg_temp.int4;
RESET SESSION AUTHORIZATION;
RESET search_path;
DROP SCHEMA schema_qualification CASCADE;
DROP OWNED BY schema_qualification_user;
DROP ROLE schema_qualification_user;
SELECT 'TEST PASSED' AS result;
