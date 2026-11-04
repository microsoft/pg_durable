-- Submission authorization is based on current_user in the origin, not graph JSON.
RESET SESSION AUTHORIZATION;
DROP SCHEMA IF EXISTS _e94_http_auth CASCADE;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '_e94_submitter') THEN
        DROP OWNED BY _e94_submitter;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '_e94_http_owner') THEN
        DROP OWNED BY _e94_http_owner;
    END IF;
END $$;
DROP ROLE IF EXISTS _e94_submitter, _e94_http_owner;
CREATE ROLE _e94_submitter LOGIN;
CREATE ROLE _e94_http_owner LOGIN;
SELECT df.grant_usage('_e94_submitter');
SELECT df.grant_usage('_e94_http_owner', include_http => true);
CREATE SCHEMA _e94_http_auth;
GRANT USAGE ON SCHEMA _e94_http_auth TO _e94_submitter;
GRANT USAGE, CREATE ON SCHEMA _e94_http_auth TO _e94_http_owner;
CREATE FUNCTION _e94_http_auth.has_function_privilege(oid, oid, text)
RETURNS bool LANGUAGE sql AS 'SELECT true';
CREATE FUNCTION _e94_http_auth.to_regprocedure(text)
RETURNS regprocedure LANGUAGE sql AS
    'SELECT ''df.http(pg_catalog.text,pg_catalog.text,pg_catalog.text,pg_catalog.jsonb,pg_catalog.int4)''::pg_catalog.regprocedure';
ALTER ROLE _e94_submitter SET search_path = _e94_http_auth, pg_catalog, pg_temp;
CREATE FUNCTION _e94_http_auth.start_as_owner(graph text) RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$ SELECT df.start(graph, 'e94-security-definer'); $$;
ALTER FUNCTION _e94_http_auth.start_as_owner(text) OWNER TO _e94_http_owner;

CREATE TEMP TABLE _e94_requests(signature text, node text);
INSERT INTO _e94_requests
SELECT signature, jsonb_build_object('node_type', node_type,
    'query', (config || '{"submitted_by":"_e94_http_owner"}'::jsonb)::text)::text
FROM (VALUES
    ('df.http(text,text,text,jsonb,integer)', 'HTTP',
     '{"url":"https://api.github.com/","method":"GET"}'::jsonb),
    ('df.http(df.http_endpoint,text,text,jsonb,integer)', 'HTTP',
     '{"endpoint":"not_resolved_during_submission","url":"/","method":"GET"}'::jsonb),
    ('df.http_multipart(text,text,jsonb,jsonb,integer)', 'HTTP_MULTIPART',
     '{"url":"https://api.github.com/","method":"POST","parts":[]}'::jsonb),
    ('df.http_multipart(df.http_endpoint,text,jsonb,jsonb,integer)', 'HTTP_MULTIPART',
     '{"endpoint":"not_resolved_during_submission","url":"/","method":"POST","parts":[]}'::jsonb)
) AS requests(signature, node_type, config);
GRANT SELECT ON _e94_requests TO _e94_submitter;

SET ROLE _e94_submitter;
SET search_path = _e94_http_auth, pg_catalog, pg_temp;
DO $$
DECLARE request record; mode text; graph text;
BEGIN
    FOREACH mode IN ARRAY ARRAY['caller', 'new'] LOOP
        FOR request IN SELECT * FROM _e94_requests LOOP
            graph := df.with_policy(
                df.seq('SELECT 1', df.if('SELECT false', request.node, 'SELECT 2')),
                '{"http":{"max_concurrency":1}}');
            BEGIN
                PERFORM df.start(graph, 'e94-denied', transaction_mode => mode);
                RAISE EXCEPTION 'TEST FAILED: unauthorized nested HTTP accepted for %/%', mode, request.signature;
            EXCEPTION WHEN insufficient_privilege THEN
                IF strpos(SQLERRM, 'does not have EXECUTE privilege') = 0
                    OR strpos(SQLERRM, request.signature) = 0 THEN
                    RAISE EXCEPTION 'TEST FAILED: wrong submission error for %/%: %', mode, request.signature, SQLERRM;
                END IF;
            END;
        END LOOP;
    END LOOP;
END $$;
RESET ROLE;
RESET search_path;
DO $$
DECLARE submitter oid := '_e94_submitter'::regrole; charges bigint;
BEGIN
    IF EXISTS (SELECT 1 FROM df.instances WHERE submitted_by = submitter)
        OR EXISTS (SELECT 1 FROM df.nodes WHERE submitted_by = submitter) THEN
        RAISE EXCEPTION 'TEST FAILED: denied starts persisted workflow metadata';
    END IF;
    EXECUTE format('SELECT count(*) FROM %I._submissions WHERE submitted_by = $1', df.duroxide_schema())
        INTO charges USING submitter;
    IF charges <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: denied starts reached protected submission/enqueue';
    END IF;
END $$;

CREATE TEMP TABLE _e94_allowed(kind text, id text);
GRANT SELECT, INSERT ON _e94_allowed TO _e94_submitter;
GRANT _e94_http_owner TO _e94_submitter;
SET ROLE _e94_submitter;
INSERT INTO _e94_allowed
SELECT 'inherited', df.start(
    df.seq(df.wait_for_signal('hold'), node), 'e94-inherited')
FROM _e94_requests WHERE signature = 'df.http(text,text,text,jsonb,integer)';
RESET ROLE;
REVOKE _e94_http_owner FROM _e94_submitter;
SET ROLE _e94_submitter;
INSERT INTO _e94_allowed
SELECT 'definer', _e94_http_auth.start_as_owner(df.seq(df.wait_for_signal('hold'), node))
FROM _e94_requests WHERE signature = 'df.http(text,text,text,jsonb,integer)';
RESET ROLE;
DO $$
DECLARE item record; expected_owner oid;
BEGIN
    FOR item IN SELECT * FROM _e94_allowed LOOP
        expected_owner := CASE WHEN item.kind = 'inherited' THEN '_e94_submitter'::regrole
                               ELSE '_e94_http_owner'::regrole END;
        IF (SELECT submitted_by FROM df.instances WHERE id = item.id) IS DISTINCT FROM expected_owner THEN
            RAISE EXCEPTION 'TEST FAILED: % start used the wrong submission identity', item.kind;
        END IF;
        PERFORM df.cancel(item.id);
        IF df.await_instance(item.id, 30) IS DISTINCT FROM 'cancelled' THEN
            RAISE EXCEPTION 'TEST FAILED: waiting % workflow was not cancelled', item.kind;
        END IF;
    END LOOP;
END $$;
DROP TABLE _e94_allowed, _e94_requests;
DROP SCHEMA _e94_http_auth CASCADE;
DROP OWNED BY _e94_submitter, _e94_http_owner;
DROP ROLE _e94_submitter, _e94_http_owner;
SELECT 'TEST PASSED' AS result;
