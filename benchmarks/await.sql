BEGIN;
CREATE SCHEMA :"bench_schema";
CREATE FUNCTION :"bench_schema".await(instance_id TEXT, timeout_seconds INTEGER, poll_ms INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    deadline TIMESTAMPTZ := clock_timestamp() + make_interval(secs => timeout_seconds);
    instance_status TEXT;
    failure_details TEXT;
BEGIN
    LOOP
        instance_status := lower(df.status(instance_id));
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'Benchmark instance % timed out after % seconds (status %)',
                instance_id, timeout_seconds, instance_status;
        END IF;
        IF instance_status = 'completed' THEN
            RETURN;
        END IF;
        IF instance_status IS NULL OR instance_status NOT IN ('pending', 'running') THEN
            SELECT jsonb_agg(jsonb_build_object('node_id', node.id, 'result', node.result) ORDER BY node.id)::TEXT
            INTO failure_details
            FROM df.nodes AS node
            WHERE node.instance_id = await.instance_id AND node.status = 'failed';
            RAISE EXCEPTION 'Benchmark instance % ended with status %', instance_id, instance_status
                USING DETAIL = coalesce(failure_details, 'No failed node result was recorded');
        END IF;
        PERFORM pg_sleep(greatest(0, least(poll_ms / 1000.0, extract(epoch FROM deadline - clock_timestamp()))));
    END LOOP;
END
$$;
COMMIT;