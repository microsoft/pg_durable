-- pg_durable upgrade: 0.2.2 → 0.2.3
--
-- Add filter_label parameter to df.list_instances().
-- See issue: Add a filter_label parameter to list_instances function

-- Drop the old signature so we can replace it with the new one.
DROP FUNCTION IF EXISTS df.list_instances(TEXT, INT);

CREATE FUNCTION df."list_instances"(
    "status_filter" TEXT DEFAULT NULL,
    "limit_count" INT DEFAULT 100,
    "filter_label" TEXT DEFAULT NULL
) RETURNS TABLE (
    "instance_id" TEXT,
    "label" TEXT,
    "function_name" TEXT,
    "status" TEXT,
    "execution_count" bigint,
    "output" TEXT
)
LANGUAGE c
AS 'MODULE_PATHNAME', 'list_instances_wrapper';
