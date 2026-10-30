-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

CREATE INDEX idx_instances_submitted_by ON df.instances(submitted_by, id);

CREATE FUNCTION df.with_policy(
    "fut" pg_catalog.text,
    "policy" pg_catalog.jsonb
) RETURNS pg_catalog.text
STRICT
LANGUAGE c
AS 'MODULE_PATHNAME', 'with_policy_wrapper';
