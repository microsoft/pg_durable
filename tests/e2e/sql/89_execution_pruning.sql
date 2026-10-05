-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Real continue-as-new histories must be pruned without breaking replay of the
-- current generation, including a child loop and a satellite-origin workflow.
CREATE EXTENSION IF NOT EXISTS dblink;
DO $$
BEGIN
    IF current_setting('pg_durable.reconcile_interval') <> '2'
        OR current_setting('pg_durable.retention_days') <> '0' THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires reconcile phase';
    END IF;
END $$;

CREATE TABLE test_execution_pruning (scenario TEXT PRIMARY KEY, iterations INT NOT NULL);
INSERT INTO test_execution_pruning VALUES ('root',0),('nested',0);
CREATE TEMP TABLE _pruning_cases (
    scenario TEXT PRIMARY KEY, local_id TEXT, engine_id TEXT,
    loop_id TEXT, current_history JSONB
);
DROP DATABASE IF EXISTS _e89_pruning WITH (FORCE);
CREATE DATABASE _e89_pruning;
SELECT dblink_connect('pruning', format(
    'host=localhost port=%s dbname=_e89_pruning user=postgres', current_setting('port')));
SELECT dblink_exec('pruning', $remote$
    CREATE EXTENSION pg_durable;
    CREATE TABLE test_execution_pruning (scenario TEXT PRIMARY KEY, iterations INT NOT NULL);
    INSERT INTO test_execution_pruning VALUES ('satellite',0);
$remote$);

DO $$
DECLARE scenario TEXT; graph TEXT; id TEXT; engine TEXT;
BEGIN
    FOREACH scenario IN ARRAY ARRAY['root','nested','satellite'] LOOP
        graph := df.loop(
            format('UPDATE test_execution_pruning SET iterations=iterations+1 WHERE scenario=%L', scenario)
            ~> df.wait_for_signal('pruning-next')
        );
        IF scenario = 'nested' THEN graph := 'SELECT 1' ~> graph; END IF;
        IF scenario = 'satellite' THEN
            SELECT remote.id INTO id FROM dblink('pruning',
                format('SELECT df.start(%L,%L)',graph,'execution-pruning'))
                AS remote(id TEXT);
            SELECT prefix || id INTO engine FROM dblink('pruning', $remote$
                SELECT 'pgdf-' || (SELECT oid::text FROM pg_database WHERE datname=current_database())
                    || '-' || (SELECT replace(id::text,'-','') FROM df._installation) || '-'
            $remote$) AS remote(prefix TEXT);
        ELSE
            id := df.start(graph,'execution-pruning');
            engine := id;
        END IF;
        INSERT INTO _pruning_cases(scenario,local_id,engine_id) VALUES (scenario,id,engine);
    END LOOP;
END $$;

CREATE FUNCTION pg_temp.wait_pruning_generation(generation BIGINT) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE item RECORD; waiting_id TEXT; iterations INT;
BEGIN
    FOR item IN SELECT * FROM _pruning_cases LOOP
        waiting_id := NULL;
        FOR attempt IN 1..300 LOOP
            EXECUTE format(
                'SELECT i.instance_id FROM %1$I.instances i
                 WHERE (i.instance_id=$1 OR i.parent_instance_id=$1)
                     AND i.current_execution_id=$2 AND EXISTS (
                         SELECT 1 FROM %1$I.history h
                         WHERE h.instance_id=i.instance_id AND h.execution_id=i.current_execution_id
                             AND h.event_data::jsonb->>''type''=''ExternalSubscribed''
                             AND h.event_data::jsonb->>''name''=''pruning-next'')',
                df.duroxide_schema())
                INTO waiting_id USING item.engine_id,generation;
            EXIT WHEN waiting_id IS NOT NULL;
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF waiting_id IS NULL THEN
            RAISE EXCEPTION 'TEST FAILED: % did not reach waiting generation %',item.scenario,generation;
        END IF;
        UPDATE _pruning_cases SET loop_id=waiting_id WHERE scenario=item.scenario;
        IF item.scenario='satellite' THEN
            SELECT n INTO iterations FROM dblink('pruning',
                'SELECT iterations FROM test_execution_pruning') AS remote(n INT);
        ELSE
            SELECT p.iterations INTO iterations FROM test_execution_pruning p WHERE p.scenario=item.scenario;
        END IF;
        IF iterations IS DISTINCT FROM generation THEN
            RAISE EXCEPTION 'TEST FAILED: % ran % iterations in generation %',item.scenario,iterations,generation;
        END IF;
    END LOOP;
END $$;

CREATE FUNCTION pg_temp.advance_pruning_generation() RETURNS void LANGUAGE plpgsql AS $$
DECLARE item RECORD;
BEGIN
    FOR item IN SELECT * FROM _pruning_cases LOOP
        IF item.scenario='satellite' THEN
            PERFORM result FROM dblink('pruning',
                format('SELECT df.signal(%L,''pruning-next'')',item.local_id)) AS remote(result TEXT);
        ELSE
            PERFORM df.signal(item.local_id,'pruning-next');
        END IF;
    END LOOP;
END $$;

SELECT pg_temp.wait_pruning_generation(1);
SELECT pg_temp.advance_pruning_generation();
SELECT pg_temp.wait_pruning_generation(2);
SELECT pg_temp.advance_pruning_generation();
SELECT pg_temp.wait_pruning_generation(3);

DO $$
DECLARE item RECORD; snapshot JSONB;
BEGIN
    FOR item IN SELECT * FROM _pruning_cases LOOP
        EXECUTE format(
            'SELECT jsonb_agg(to_jsonb(h) ORDER BY event_id) FROM %I.history h
             WHERE instance_id=$1 AND execution_id=3',df.duroxide_schema())
            INTO snapshot USING item.loop_id;
        IF snapshot IS NULL THEN RAISE EXCEPTION 'TEST FAILED: no current history for %',item.scenario; END IF;
        UPDATE _pruning_cases SET current_history=snapshot WHERE scenario=item.scenario;
    END LOOP;
END $$;

DO $$
DECLARE item RECORD; remaining INT; snapshot JSONB; live BOOLEAN;
BEGIN
    FOR item IN SELECT * FROM _pruning_cases LOOP
        FOR attempt IN 1..300 LOOP
            EXECUTE format(
                'SELECT count(*) FROM %I.executions WHERE instance_id=$1 AND execution_id<3',
                df.duroxide_schema()) INTO remaining USING item.loop_id;
            EXIT WHEN remaining=0;
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF remaining<>0 THEN
            RAISE EXCEPTION 'TEST FAILED: % still has % old executions',item.scenario,remaining;
        END IF;
        EXECUTE format('SELECT count(*) FROM %I.history WHERE instance_id=$1 AND execution_id<3',
            df.duroxide_schema()) INTO remaining USING item.loop_id;
        IF remaining<>0 THEN RAISE EXCEPTION 'TEST FAILED: old history survived for %',item.scenario; END IF;
        EXECUTE format(
            'SELECT jsonb_agg(to_jsonb(h) ORDER BY event_id) FROM %I.history h
             WHERE instance_id=$1 AND execution_id=3',df.duroxide_schema())
            INTO snapshot USING item.loop_id;
        IF snapshot IS DISTINCT FROM item.current_history THEN
            RAISE EXCEPTION 'TEST FAILED: current history changed for %',item.scenario;
        END IF;
        IF item.scenario='satellite' THEN
            SELECT result INTO live FROM dblink('pruning',format(
                'SELECT df.status(%1$L)=''running'' AND EXISTS(SELECT 1 FROM df.nodes WHERE instance_id=%1$L)',
                item.local_id)) AS remote(result BOOLEAN);
        ELSE
            SELECT df.status(item.local_id)='running'
                AND EXISTS(SELECT 1 FROM df.nodes WHERE instance_id=item.local_id) INTO live;
        END IF;
        IF live IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'TEST FAILED: pruning removed live workflow state for %',item.scenario;
        END IF;
    END LOOP;
END $$;

SELECT pg_temp.advance_pruning_generation();
SELECT pg_temp.wait_pruning_generation(4);

DO $$
DECLARE item RECORD; running BOOLEAN;
BEGIN
    FOR item IN SELECT * FROM _pruning_cases LOOP
        IF item.scenario='satellite' THEN
            PERFORM result FROM dblink('pruning',
                format('SELECT df.cancel(%L)',item.local_id)) AS remote(result TEXT);
        ELSE
            PERFORM df.cancel(item.local_id);
        END IF;
        FOR attempt IN 1..300 LOOP
            EXECUTE format(
                'SELECT EXISTS(SELECT 1 FROM %1$I.instances i JOIN %1$I.executions e
                 ON e.instance_id=i.instance_id AND e.execution_id=i.current_execution_id
                 WHERE (i.instance_id=$1 OR i.parent_instance_id=$1) AND e.status=''Running'')',
                df.duroxide_schema()) INTO running USING item.engine_id;
            EXIT WHEN NOT running;
            PERFORM pg_sleep(0.1);
        END LOOP;
        IF running THEN RAISE EXCEPTION 'TEST FAILED: cleanup left % running',item.scenario; END IF;
    END LOOP;
END $$;
SELECT dblink_disconnect('pruning');
DROP DATABASE _e89_pruning WITH (FORCE);
DROP TABLE _pruning_cases;
DROP TABLE test_execution_pruning;
SELECT 'TEST PASSED: execution pruning' AS result;
