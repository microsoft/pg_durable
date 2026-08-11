-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

BEGIN;

CREATE EXTENSION pg_durable;

CREATE TABLE _duroxide._worker_ready (
    sentinel BOOLEAN PRIMARY KEY DEFAULT TRUE,
    schema_version INT NOT NULL,
    initialized_at TIMESTAMPTZ NOT NULL
);
INSERT INTO _duroxide._worker_ready
VALUES (TRUE, 73, TIMESTAMPTZ '2000-01-01 00:00:00+00');

CREATE TABLE _duroxide.compat_rejection_sentinel (
    marker TEXT PRIMARY KEY
);
INSERT INTO _duroxide.compat_rejection_sentinel VALUES ('must-survive-rejection');

-- The recovery test restores from this rather than hardcoding a release.
CREATE TABLE _duroxide.compat_fixture_state AS
SELECT extversion AS original_version
FROM pg_catalog.pg_extension
WHERE extname = 'pg_durable';

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