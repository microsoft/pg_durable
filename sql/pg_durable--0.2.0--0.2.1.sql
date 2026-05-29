-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.0 → 0.2.1
--
-- Add durable child-orchestration helpers and refresh helper/grant functions
-- so upgraded installations can use the new API surface immediately.

CREATE FUNCTION df."await_instance"(
    "instance_id" TEXT,
    "timeout_seconds" INT DEFAULT NULL
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'await_instance_wrapper';

CREATE FUNCTION df."call_child"(
    "fut" TEXT,
    "label" TEXT DEFAULT NULL,
    "options" JSONB DEFAULT NULL
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'call_child_wrapper';

CREATE OR REPLACE FUNCTION df.ensure_durofut(val text) RETURNS text AS $$
DECLARE
    node_type_val text;
BEGIN
    BEGIN
        node_type_val := (val::jsonb)->>'node_type';
        IF node_type_val IS NOT NULL THEN
            IF node_type_val NOT IN ('SQL', 'THEN', 'IF', 'JOIN', 'LOOP', 'BREAK', 'RACE', 'SLEEP', 'WAIT_SCHEDULE', 'HTTP', 'SIGNAL', 'AWAIT_INSTANCE') THEN
                RAISE EXCEPTION 'Unknown node_type ''%''. Valid types: SQL, THEN, IF, JOIN, LOOP, BREAK, RACE, SLEEP, WAIT_SCHEDULE, HTTP, SIGNAL, AWAIT_INSTANCE', node_type_val;
            END IF;
            RETURN val;
        END IF;
    EXCEPTION WHEN invalid_text_representation THEN
        NULL;
    WHEN raise_exception THEN
        RAISE;
    WHEN OTHERS THEN
        NULL;
    END;

    RETURN df.sql(val);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

CREATE OR REPLACE FUNCTION df.grant_usage(
    p_role TEXT,
    include_http boolean DEFAULT false,
    with_grant boolean DEFAULT false
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, df, pg_temp
AS $fn$
DECLARE
    grant_opt TEXT := '';
    func_sig TEXT;
    func_sigs TEXT[] := ARRAY[
        'df.sql(text)',
        'df.seq(text, text)',
        'df.as(text, text)',
        'df.sleep(bigint)',
        'df.wait_for_schedule(text)',
        'df.loop(text, text)',
        'df.break(text)',
        'df.if(text, text, text)',
        'df.if_rows(text, text, text)',
        'df.join(text, text)',
        'df.join3(text, text, text)',
        'df.race(text, text)',
        'df.wait_for_signal(text, integer)',
        'df.await_instance(text, integer)',
        'df.call_child(text, text, jsonb)',
        'df.signal(text, text, text)',
        'df.start(text, text, text)',
        'df.setvar(text, text)',
        'df.getvar(text)',
        'df.unsetvar(text)',
        'df.clearvars()',
        'df.status(text)',
        'df.result(text)',
        'df.cancel(text, text)',
        'df.wait_for_completion(text, integer)',
        'df.run(text)',
        'df.list_instances(text, integer)',
        'df.instance_info(text)',
        'df.instance_nodes(text, integer)',
        'df.instance_executions(text, integer)',
        'df.metrics()',
        'df.as_op(text, text)',
        'df.if_then_op(text, text)',
        'df.if_else_op(text, text)',
        'df.ensure_durofut(text)',
        'df.loop_prefix_op(text)',
        'df.version()',
        'df.debug_connection()',
        'df.explain(text)',
        'df.target_database()'
    ];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
        RAISE EXCEPTION 'role "%" does not exist', p_role;
    END IF;

    IF with_grant THEN
        grant_opt := ' WITH GRANT OPTION';
    END IF;

    EXECUTE format('GRANT USAGE ON SCHEMA df TO %I', p_role) || grant_opt;

    FOREACH func_sig IN ARRAY func_sigs LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', func_sig, p_role) || grant_opt;
    END LOOP;

    IF include_http THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO %I', p_role) || grant_opt;
    END IF;

    IF with_grant THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) TO %I', p_role) || grant_opt;
        EXECUTE format('GRANT EXECUTE ON FUNCTION df.revoke_usage(text) TO %I', p_role) || grant_opt;
    END IF;

    EXECUTE format('GRANT SELECT ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT UPDATE (status, updated_at) ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT SELECT ON df.nodes TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT INSERT (id, label, root_node, submitted_by, database) ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database) ON df.nodes TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO %I', p_role) || grant_opt;

    RAISE NOTICE 'pg_durable: granted df usage privileges to "%"', p_role;
END;
$fn$;
