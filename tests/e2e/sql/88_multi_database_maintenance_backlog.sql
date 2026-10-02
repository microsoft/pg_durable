CREATE EXTENSION IF NOT EXISTS dblink;
DO $$ BEGIN
    IF current_setting('pg_durable.reconcile_interval') <> '60'
        OR current_setting('pg_durable.retention_days') <> '30' THEN
        RAISE EXCEPTION 'TEST SETUP ERROR: requires maintenance-backlog phase';
    END IF;
END $$;
DROP DATABASE IF EXISTS _e88_busy WITH (FORCE);
DROP DATABASE IF EXISTS _e88_peer WITH (FORCE);
DROP DATABASE IF EXISTS _e88_unavailable WITH (FORCE);
CREATE DATABASE _e88_busy;
CREATE DATABASE _e88_peer;
CREATE DATABASE _e88_unavailable;
CREATE TEMP TABLE _e88_origins(name text, oid oid, installation uuid);
DO $$
DECLARE database_name text;
BEGIN
    FOREACH database_name IN ARRAY ARRAY['_e88_busy','_e88_peer','_e88_unavailable'] LOOP
        PERFORM dblink_connect(database_name,format('host=localhost port=%s dbname=%L user=postgres',
            current_setting('port'),database_name));
        PERFORM dblink_exec(database_name,'CREATE EXTENSION pg_durable');
        INSERT INTO _e88_origins SELECT database_name,oid,id FROM dblink(database_name,
            'SELECT (SELECT oid FROM pg_database WHERE datname=current_database()),id FROM df._installation')
            AS source(oid oid,id uuid);
    END LOOP;
END $$;
SELECT dblink_exec('_e88_busy', $sql$
    BEGIN;
    SET CONSTRAINTS ALL DEFERRED;
    INSERT INTO df.instances(id,root_node,submitted_by,status,created_at,completed_at)
        SELECT lpad(to_hex(n),8,'0'),lpad(to_hex(n),8,'0'),current_user::regrole,'completed',
            now()+interval '1 day',now()+interval '1 day' FROM generate_series(1,10010) n;
    INSERT INTO df.instances(id,root_node,submitted_by,status,created_at,completed_at)
        SELECT lpad(to_hex(n),8,'0'),lpad(to_hex(n),8,'0'),current_user::regrole,'completed',
            now()-interval '31 days',now()-interval '31 days' FROM generate_series(10011,12011) n;
    INSERT INTO df.nodes(id,instance_id,node_type,query,submitted_by,status,result)
        SELECT id,id,'SQL','SELECT 1',current_user::regrole,'completed','{}'::jsonb FROM df.instances;
    COMMIT;
$sql$);
SELECT dblink_exec('_e88_peer', $sql$
    BEGIN;
    INSERT INTO df.instances(id,root_node,submitted_by,status,created_at,completed_at)
        VALUES ('00000001','00000001',current_user::regrole,'completed',now()-interval '31 days',now()-interval '31 days');
    INSERT INTO df.nodes(id,instance_id,node_type,query,submitted_by,status,result)
        VALUES ('00000001','00000001','SQL','SELECT 1',current_user::regrole,'completed','{}');
    COMMIT;
$sql$);
ALTER DATABASE _e88_unavailable ALLOW_CONNECTIONS false;
DO $$
DECLARE item record;
BEGIN
    FOR item IN SELECT * FROM _e88_origins LOOP
        EXECUTE format('INSERT INTO %I._origins(database_oid,installation_id) VALUES ($1,$2)',
            df.duroxide_schema()) USING item.oid::bigint,item.installation;
    END LOOP;
END $$;
CREATE TEMP TABLE _e88_progress(first_progress timestamptz, peer_done timestamptz, busy_done timestamptz);
INSERT INTO _e88_progress VALUES (NULL,NULL,NULL);
DO $$
DECLARE deadline timestamptz := clock_timestamp()+interval '120 seconds';
    busy_count bigint; peer_count bigint;
BEGIN
    LOOP
        SELECT n INTO busy_count FROM dblink('_e88_busy','SELECT count(*) FROM df.instances') AS source(n bigint);
        SELECT n INTO peer_count FROM dblink('_e88_peer','SELECT count(*) FROM df.instances') AS source(n bigint);
        IF busy_count < 12011 THEN UPDATE _e88_progress SET first_progress=COALESCE(first_progress,clock_timestamp()); END IF;
        IF peer_count = 0 THEN UPDATE _e88_progress SET peer_done=COALESCE(peer_done,clock_timestamp()); END IF;
        IF busy_count = 10000 THEN
            UPDATE _e88_progress SET busy_done=clock_timestamp();
            EXIT;
        END IF;
        IF clock_timestamp()>deadline THEN RAISE EXCEPTION 'TEST FAILED: maintenance backlog did not drain: %',busy_count; END IF;
        PERFORM pg_sleep(0.05);
    END LOOP;
    IF EXISTS (SELECT 1 FROM _e88_progress WHERE peer_done IS NULL
        OR peer_done-first_progress >= interval '40 seconds'
        OR busy_done-first_progress >= interval '40 seconds') THEN
        RAISE EXCEPTION 'TEST FAILED: pages or peer waited for the next 60-second maintenance interval: %',
            (SELECT row_to_json(p) FROM _e88_progress p);
    END IF;
END $$;
DO $$
DECLARE registered bool;
BEGIN
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I._origins WHERE database_oid=$1 AND installation_id=$2)',
        df.duroxide_schema()) INTO registered USING
        (SELECT oid::bigint FROM _e88_origins WHERE name='_e88_unavailable'),
        (SELECT installation FROM _e88_origins WHERE name='_e88_unavailable');
    IF registered IS DISTINCT FROM true THEN RAISE EXCEPTION 'TEST FAILED: unreachable registration removed'; END IF;
END $$;
SELECT dblink_disconnect(name) FROM _e88_origins;
DROP DATABASE _e88_busy WITH (FORCE);
DROP DATABASE _e88_peer WITH (FORCE);
DROP DATABASE _e88_unavailable WITH (FORCE);
-- Registration GC must work even if there have never been engine roots.
DO $$
DECLARE deadline timestamptz:=clock_timestamp()+interval '90 seconds'; remaining int;
BEGIN
    LOOP
        EXECUTE format('SELECT count(*) FROM %I._origins o JOIN _e88_origins s
            ON o.database_oid=s.oid::bigint AND o.installation_id=s.installation',df.duroxide_schema())
            INTO remaining;
        EXIT WHEN remaining=0;
        IF clock_timestamp()>deadline THEN RAISE EXCEPTION 'TEST FAILED: empty removed registrations not collected'; END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END $$;
DROP TABLE _e88_origins,_e88_progress;
SELECT 'TEST PASSED: maintenance pages continue promptly, peers progress, and removed registrations expire' AS result;
