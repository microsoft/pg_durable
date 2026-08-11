-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

BEGIN;

CREATE EXTENSION pg_durable;

-- Shape this like an install that originated on pg_durable <= 0.2.2: the
-- provider schema is the legacy 'duroxide' and the helper reports it. That is
-- what pg_durable--0.2.2--0.2.3.sql leaves behind, and it is the state every
-- real below-floor database is in, so the worker resolves 'duroxide' here and
-- '_duroxide' after the recovery recreate.
ALTER SCHEMA _duroxide RENAME TO duroxide;
CREATE OR REPLACE FUNCTION df.duroxide_schema() RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, pg_temp
    AS $$ SELECT 'duroxide'::text $$;

CREATE TABLE duroxide._worker_ready (
    sentinel BOOLEAN PRIMARY KEY DEFAULT TRUE,
    schema_version INT NOT NULL,
    initialized_at TIMESTAMPTZ NOT NULL
);
INSERT INTO duroxide._worker_ready
VALUES (TRUE, 73, TIMESTAMPTZ '2000-01-01 00:00:00+00');

CREATE TABLE duroxide.compat_rejection_sentinel (
    marker TEXT PRIMARY KEY
);
INSERT INTO duroxide.compat_rejection_sentinel VALUES ('must-survive-rejection');

INSERT INTO df.instances (id, label, root_node, status, submitted_by, database)
VALUES
    ('a0000001', 'compat-signal-target', 'b0000001', 'running', CURRENT_USER::pg_catalog.regrole, CURRENT_DATABASE()),
    ('a0000002', 'compat-cancel-target', 'b0000002', 'running', CURRENT_USER::pg_catalog.regrole, CURRENT_DATABASE()),
    ('a0000003', 'compat-monitor-target', 'b0000003', 'completed', CURRENT_USER::pg_catalog.regrole, CURRENT_DATABASE());

INSERT INTO df.nodes (
    id, instance_id, node_type, query, status, result, submitted_by, database
)
VALUES
    ('b0000001', 'a0000001', 'SQL', 'SELECT 1', 'running', NULL, CURRENT_USER::pg_catalog.regrole, CURRENT_DATABASE()),
    ('b0000002', 'a0000002', 'SQL', 'SELECT 2', 'running', NULL, CURRENT_USER::pg_catalog.regrole, CURRENT_DATABASE()),
    ('b0000003', 'a0000003', 'SQL', 'SELECT 42', 'completed', '{"answer": 42}', CURRENT_USER::pg_catalog.regrole, CURRENT_DATABASE());

UPDATE pg_catalog.pg_extension
SET extversion = '0.2.2-rc1'
WHERE extname = 'pg_durable';

COMMIT;
