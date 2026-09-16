BEGIN;
CREATE SCHEMA :"bench_schema";
CREATE FUNCTION :"bench_schema".await(instance_id TEXT, timeout_seconds INTEGER, poll_ms INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    deadline TIMESTAMPTZ := clock_timestamp() + make_interval(secs => timeout_seconds);
    instance_status TEXT;
BEGIN
    LOOP
        instance_status := lower(df.status(instance_id));
        IF instance_status = 'completed' THEN
            RETURN;
        END IF;
        IF instance_status IS NULL OR instance_status NOT IN ('pending', 'running') THEN
            RAISE EXCEPTION 'Benchmark instance % ended with status %', instance_id, instance_status;
        END IF;
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'Benchmark instance % timed out after % seconds (status %)',
                instance_id, timeout_seconds, instance_status;
        END IF;
        PERFORM pg_sleep(poll_ms / 1000.0);
    END LOOP;
END
$$;
COMMIT;