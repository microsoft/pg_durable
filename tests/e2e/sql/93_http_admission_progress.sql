-- Admit the backlog while authorized, then revoke HTTP before it can dispatch.
\getenv e93_port PGDURABLE_TEST_HTTP_PORT
\getenv e93_counts PGDURABLE_TEST_HTTP_COUNTS
\getenv e93_release PGDURABLE_TEST_HTTP_RELEASE
SELECT set_config('test.e93_url', 'https://127.0.0.1:' || :'e93_port' || '/capacity?case=', false),
    set_config('test.e93_counts', :'e93_counts', false),
    set_config('test.e93_release', :'e93_release', false);
DO $$ BEGIN
    IF current_setting('pg_durable.max_http_concurrency')::int <> 1
        OR current_setting('pg_durable.max_activity_concurrency')::int <> 2 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires one HTTP slot and two activity slots';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '_e93_no_http') THEN
        EXECUTE 'DROP OWNED BY _e93_no_http';
        DROP ROLE _e93_no_http;
    END IF;
END $$;
CREATE ROLE _e93_no_http LOGIN;
SELECT df.grant_usage('_e93_no_http', include_http => true);

CREATE TEMP TABLE _e93_cases(kind text, id text PRIMARY KEY);
GRANT SELECT, INSERT ON _e93_cases TO _e93_no_http;
CREATE FUNCTION pg_temp.e93_wait(check_sql text, assertion text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + interval '30 seconds'; satisfied bool;
BEGIN
    LOOP
        EXECUTE check_sql INTO satisfied;
        IF satisfied IS TRUE THEN RETURN; END IF;
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'TEST FAILED [%]: deadline exceeded', assertion;
        END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;
INSERT INTO _e93_cases SELECT 'held', df.start(
    df.http(current_setting('test.e93_url') || 'held', 'GET', timeout_seconds => 120),
    'e93-held');
SELECT pg_temp.e93_wait(
    'SELECT pg_read_file(current_setting(''test.e93_counts''))::jsonb #>> ''{_capacity,active}'' = ''1''',
    'HTTP slot occupied before enqueueing the backlog');

-- Several small graphs avoid conflating admission churn with one huge graph's
-- repeated serialization into every child-orchestration input.
CREATE TEMP TABLE _e93_graph AS
WITH leaves AS (
    SELECT jsonb_build_object('node_type', 'HTTP', 'query', jsonb_build_object(
        'url', current_setting('test.e93_url') || 'denied-http', 'method', 'GET',
        'timeout_seconds', 120)::text) AS ordinary,
        jsonb_build_object('node_type', 'HTTP_MULTIPART', 'query', jsonb_build_object(
        'url', current_setting('test.e93_url') || 'denied-multipart', 'method', 'POST',
        'parts', '[{"name":"payload","data_b64":"eA=="}]'::jsonb,
        'timeout_seconds', 120)::text) AS multipart
)
SELECT jsonb_build_object('node_type', 'JOIN', 'left_node', ordinary, 'right_node', multipart,
    'extra_nodes', (SELECT jsonb_agg(CASE WHEN n % 2 = 0 THEN ordinary ELSE multipart END ORDER BY n)
                    FROM generate_series(1, 18) n))::text AS graph
FROM leaves;
GRANT SELECT ON _e93_graph TO _e93_no_http;
SET ROLE _e93_no_http;
INSERT INTO _e93_cases SELECT 'backlog', df.start(graph, 'e93-backlog-' || n)
    FROM _e93_graph CROSS JOIN generate_series(1, 25) n;
RESET ROLE;
REVOKE EXECUTE ON FUNCTION df.http(text,text,text,jsonb,integer),
    df.http(df.http_endpoint,text,text,jsonb,integer),
    df.http_multipart(text,text,jsonb,jsonb,integer),
    df.http_multipart(df.http_endpoint,text,jsonb,jsonb,integer) FROM _e93_no_http;
DO $$ BEGIN
    IF has_function_privilege('_e93_no_http', 'df.http(text,text,text,jsonb,integer)', 'EXECUTE')
        OR has_function_privilege('_e93_no_http',
            'df.http_multipart(text,text,jsonb,jsonb,integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: HTTP privileges must be revoked before release';
    END IF;
END $$;

SELECT pg_temp.e93_wait(format($check$
    SELECT count(*) = 500
    FROM %I.history h JOIN _e93_cases c ON split_part(h.instance_id, '::', 1) = c.id
    WHERE c.kind = 'backlog' AND h.event_data::jsonb->>'type' = 'ActivityScheduled'
        AND h.event_data::jsonb->>'name' IN (
            'pg_durable::activity::execute-http', 'pg_durable::activity::execute-multipart')
$check$, df.duroxide_schema()), 'all HTTP activities can be scheduled despite saturated capacity');

-- Let earlier deferrals become visible again before enqueueing the marker.
SELECT pg_sleep(0.5);
INSERT INTO _e93_cases SELECT 'marker', df.start('SELECT 42', 'e93-sql-headroom');
DO $$
DECLARE observed jsonb; started timestamptz := clock_timestamp();
BEGIN
    -- Each of the marker's metadata/SQL activities can wait behind one traversal
    -- of the backlog; the contract is progress without releasing HTTP capacity.
    IF df.await_instance((SELECT id FROM _e93_cases WHERE kind = 'marker'), 60)
        IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: deferred HTTP backlog starved unrelated SQL or status updates';
    END IF;
    RAISE NOTICE 'SQL completed under sustained HTTP saturation in %', clock_timestamp() - started;
    observed := pg_read_file(current_setting('test.e93_counts'))::jsonb;
    IF observed #>> '{_capacity,active}' IS DISTINCT FROM '1'
        OR observed #>> '{_capacity,peak}' IS DISTINCT FROM '1'
        OR observed->>'held' IS DISTINCT FROM '1'
        OR (SELECT count(*) FROM jsonb_object_keys(observed)) <> 2
        OR df.status((SELECT id FROM _e93_cases WHERE kind = 'held')) IS DISTINCT FROM 'running' THEN
        RAISE EXCEPTION 'TEST FAILED: marker completed without the intended saturated backlog: %', observed;
    END IF;
    EXECUTE format('COPY (SELECT ''release'') TO %L', current_setting('test.e93_release'));
END $$;
SELECT pg_temp.e93_wait(
    'SELECT bool_and(CASE WHEN kind = ''backlog'' THEN df.status(id) = ''failed''
                    ELSE df.status(id) = ''completed'' END) FROM _e93_cases',
    'held request completes and denied backlog fails after admission');
DO $$
DECLARE observed jsonb := pg_read_file(current_setting('test.e93_counts'))::jsonb;
BEGIN
    IF observed #>> '{_capacity,active}' IS DISTINCT FROM '0'
        OR observed #>> '{_capacity,peak}' IS DISTINCT FROM '1'
        OR observed->>'held' IS DISTINCT FROM '1'
        OR (SELECT count(*) FROM jsonb_object_keys(observed)) <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: backlog bypassed HTTP authorization: %', observed;
    END IF;
END $$;
DROP TABLE _e93_graph, _e93_cases;
DROP OWNED BY _e93_no_http;
DROP ROLE _e93_no_http;
SELECT 'TEST PASSED' AS result;
