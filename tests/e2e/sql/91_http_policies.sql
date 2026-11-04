\getenv e91_port PGDURABLE_TEST_HTTP_PORT
\getenv e91_counts PGDURABLE_TEST_HTTP_COUNTS
\getenv e91_release PGDURABLE_TEST_HTTP_RELEASE
SELECT set_config('test.e91_url', 'https://127.0.0.1:' || :'e91_port' || '/capacity?case=', false),
    set_config('test.e91_counts', :'e91_counts', false),
    set_config('test.e91_release', :'e91_release', false);
DO $$ BEGIN
    IF current_setting('pg_durable.max_http_concurrency')::int <> 4
        OR current_setting('pg_durable.max_activity_concurrency')::int <> 6 THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires four HTTP and six activity slots';
    END IF;
END $$;

CREATE FUNCTION pg_temp.e91_request(name text, groups text) RETURNS text LANGUAGE sql AS $$
    SELECT df.http(current_setting('test.e91_url') || name || groups, 'GET', timeout_seconds => 60);
$$;
CREATE FUNCTION pg_temp.e91_wait(check_sql text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE deadline timestamptz := clock_timestamp() + interval '20 seconds'; satisfied bool;
BEGIN
    LOOP
        EXECUTE check_sql INTO satisfied;
        IF satisfied IS TRUE THEN RETURN; END IF;
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'TEST FAILED: policy admission deadline exceeded: %', check_sql;
        END IF;
        PERFORM pg_sleep(0.025);
    END LOOP;
END $$;
CREATE TEMP TABLE _e91_runs(name text PRIMARY KEY, id text);
INSERT INTO _e91_runs SELECT 'nested', df.start(
    df.with_policy(
        df.join3(
            df.with_policy(df.join3(
                pg_temp.e91_request('a1', '&group=outer&group=a'),
                pg_temp.e91_request('a2', '&group=outer&group=a'),
                pg_temp.e91_request('a3', '&group=outer&group=a')),
                '{"http":{"max_concurrency":1}}'),
            df.with_policy(df.join3(
                pg_temp.e91_request('b1', '&group=outer&group=b'),
                pg_temp.e91_request('b2', '&group=outer&group=b'),
                df.http_multipart(current_setting('test.e91_url') || 'b3&group=outer&group=b',
                    parts => '[{"name":"payload","data_b64":"eA=="}]', timeout_seconds => 60)),
                '{"http":{"max_concurrency":1}}'),
            df.with_policy(df.join(
                pg_temp.e91_request('c1', '&group=outer&group=c'),
                pg_temp.e91_request('c2', '&group=outer&group=c')),
                '{"http":{"max_concurrency":1}}')),
        '{"http":{"max_concurrency":2}}'), 'e91-nested');
INSERT INTO _e91_runs SELECT 'independent', df.start(
    df.with_policy(df.join(
        pg_temp.e91_request('independent1', '&group=independent'),
        pg_temp.e91_request('independent2', '&group=independent')),
        '{"http":{"max_concurrency":1}}'), 'e91-independent');
SELECT pg_temp.e91_wait($check$
    SELECT observed #>> '{_groups,outer,active}' = '2'
        AND observed #>> '{_groups,independent,active}' = '1'
        AND observed #>> '{_capacity,active}' = '3'
    FROM (SELECT pg_read_file(current_setting('test.e91_counts'))::jsonb AS observed) s
$check$);
INSERT INTO _e91_runs SELECT 'unscoped',
    df.start(pg_temp.e91_request('unscoped', ''), 'e91-unscoped');
SELECT pg_temp.e91_wait($check$
    SELECT pg_read_file(current_setting('test.e91_counts'))::jsonb #>> '{_capacity,active}' = '4'
$check$);
CREATE TEMP TABLE _e91_sql AS SELECT df.start('SELECT 42', 'e91-sql-headroom') AS id;
DO $$ BEGIN
    IF df.await_instance((SELECT id FROM _e91_sql), 10) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: scoped admission blocked SQL progress';
    END IF;
    IF (SELECT count(*) FROM df.nodes WHERE instance_id = (SELECT id FROM _e91_runs WHERE name = 'nested')
        AND node_type IN ('HTTP', 'HTTP_MULTIPART')
        AND jsonb_array_length(query::jsonb->'_pgd_http_scopes') = 2) <> 8 THEN
        RAISE EXCEPTION 'TEST FAILED: enclosing scopes were not materialized on every HTTP leaf';
    END IF;
    EXECUTE format('COPY (SELECT ''release'') TO %L', current_setting('test.e91_release'));
END $$;
DO $$
DECLARE item record; observed jsonb;
BEGIN
    FOR item IN SELECT * FROM _e91_runs LOOP
        IF df.await_instance(item.id, 30) IS DISTINCT FROM 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: % did not complete after admission', item.name;
        END IF;
    END LOOP;
    observed := pg_read_file(current_setting('test.e91_counts'))::jsonb;
    IF observed #>> '{_groups,outer,peak}' IS DISTINCT FROM '2'
        OR observed #>> '{_groups,a,peak}' IS DISTINCT FROM '1'
        OR observed #>> '{_groups,b,peak}' IS DISTINCT FROM '1'
        OR observed #>> '{_groups,c,peak}' IS DISTINCT FROM '1'
        OR observed #>> '{_groups,independent,peak}' IS DISTINCT FROM '1'
        OR observed #>> '{_capacity,peak}' IS DISTINCT FROM '4' THEN
        RAISE EXCEPTION 'TEST FAILED: measured scoped limits were not respected: %', observed;
    END IF;
END $$;

DROP TABLE IF EXISTS public._e91_iterations;
CREATE TABLE public._e91_iterations(value int);
INSERT INTO public._e91_iterations VALUES (0);
INSERT INTO _e91_runs SELECT 'loop', df.start(
    df.with_policy(df.loop(
        df.seq(df.join(
            pg_temp.e91_request('loop1', '&group=loop&delay_ms=200'),
            pg_temp.e91_request('loop2', '&group=loop&delay_ms=200')),
            'UPDATE public._e91_iterations SET value = value + 1'),
        'SELECT value < 3 FROM public._e91_iterations'),
        '{"http":{"max_concurrency":1}}'), 'e91-loop');
DO $$
DECLARE observed jsonb;
BEGIN
    IF df.await_instance((SELECT id FROM _e91_runs WHERE name = 'loop'), 30) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: policy did not survive loop continuation';
    END IF;
    observed := pg_read_file(current_setting('test.e91_counts'))::jsonb;
    IF observed #>> '{_groups,loop,peak}' IS DISTINCT FROM '1'
        OR observed->>'loop1' IS DISTINCT FROM '3'
        OR observed->>'loop2' IS DISTINCT FROM '3'
        OR (SELECT value FROM public._e91_iterations) <> 3 THEN
        RAISE EXCEPTION 'TEST FAILED: loop policy counts mismatch: %', observed;
    END IF;
END $$;
INSERT INTO _e91_runs SELECT 'race', df.start(
    df.with_policy(df.race(
        pg_temp.e91_request('race1', '&group=race&delay_ms=200'),
        pg_temp.e91_request('race2', '&group=race&delay_ms=200')),
        '{"http":{"max_concurrency":1}}'), 'e91-race');
DO $$ BEGIN
    IF df.await_instance((SELECT id FROM _e91_runs WHERE name = 'race'), 30) IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: scoped race did not complete';
    END IF;
END $$;
SELECT pg_temp.e91_wait($check$
    SELECT pg_read_file(current_setting('test.e91_counts'))::jsonb #>> '{_groups,race,active}' = '0'
$check$);
DO $$ BEGIN
    IF pg_read_file(current_setting('test.e91_counts'))::jsonb #>> '{_groups,race,peak}' IS DISTINCT FROM '1' THEN
        RAISE EXCEPTION 'TEST FAILED: race branches did not share their policy';
    END IF;
END $$;
DROP TABLE public._e91_iterations;
DROP TABLE _e91_runs, _e91_sql;
SELECT 'TEST PASSED' AS result;
