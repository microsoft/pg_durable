\getenv e92_port PGDURABLE_TEST_HTTP_PORT
\getenv e92_counts PGDURABLE_TEST_HTTP_COUNTS
\getenv e92_after PGDURABLE_TEST_HTTP_RESTARTED
SELECT set_config('test.e92_url', 'https://127.0.0.1:' || :'e92_port' || '/capacity?case=', false),
    set_config('test.e92_counts', :'e92_counts', false);

\if :e92_after
DO $$
DECLARE observed jsonb; inst_id text := (SELECT instance_id FROM public._e92_state);
BEGIN
    IF df.await_instance(inst_id, 60) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: active and queued HTTP work did not recover after restart';
    END IF;
    observed := pg_read_file(current_setting('test.e92_counts'))::jsonb;
    IF COALESCE((observed->>'restart1')::int, 0) < 1
        OR COALESCE((observed->>'restart2')::int, 0) < 1
        OR COALESCE((observed->>'restart3')::int, 0) < 1
        OR (observed->>'restart1')::int + (observed->>'restart2')::int
            + (observed->>'restart3')::int < 4 THEN
        RAISE EXCEPTION 'TEST FAILED: interrupted HTTP attempt was not recovered: %', observed;
    END IF;
    IF (SELECT count(*) FROM df.nodes n JOIN df.instances i ON i.id = n.instance_id
        WHERE i.id = inst_id AND n.node_type IN ('HTTP', 'HTTP_MULTIPART')
          AND n.query::jsonb #>> '{_pgd_http_scopes,0,id}' = i.root_node
          AND n.query::jsonb #>> '{_pgd_http_scopes,0,max_concurrency}' = '1') <> 3 THEN
        RAISE EXCEPTION 'TEST FAILED: persisted scope changed across restart';
    END IF;
END $$;
DROP TABLE public._e92_state;
\else
DROP TABLE IF EXISTS public._e92_state;
CREATE TABLE public._e92_state(instance_id text);
INSERT INTO public._e92_state SELECT df.start(
    df.with_policy(df.join3(
        df.http(current_setting('test.e92_url') || 'restart1', 'GET', timeout_seconds => 120),
        df.http(current_setting('test.e92_url') || 'restart2', 'GET', timeout_seconds => 120),
        df.http_multipart(current_setting('test.e92_url') || 'restart3',
            parts => '[{"name":"payload","data_b64":"eA=="}]', timeout_seconds => 120)),
        '{"http":{"max_concurrency":1}}'), 'e92-restart');
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '15 seconds'; observed jsonb;
BEGIN
    LOOP
        observed := pg_read_file(current_setting('test.e92_counts'))::jsonb;
        EXIT WHEN observed #>> '{_capacity,active}' = '1';
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'TEST FAILED: HTTP activity did not reach the slow-body fixture';
        END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;
\endif
SELECT 'TEST PASSED' AS result;
