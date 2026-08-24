-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.6 -> 0.2.7
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).

-- ============================================================================
-- Add the df.start() node failure policy: max_attempts, max_backoff, on_failure.
--
-- A failing df.sql(), df.http(), or df.http_multipart() node is now retried with
-- exponential backoff (1s, doubling, capped at max_backoff) up to max_attempts
-- tries. Once those are spent, on_failure decides between abandoning the rest of
-- the current loop iteration ('continue', the default) and failing the instance
-- ('fail'). With no enclosing loop there is no next iteration, so both settings
-- fail the instance.
--
-- The four-argument df.start() is dropped and replaced by a seven-argument one
-- bound to a new C symbol (start_v3_wrapper). Both cannot coexist: with defaults
-- on the trailing arguments of each, a four-argument call such as
-- df.start(fut, label, database, transaction_mode) matches both and PostgreSQL
-- raises "function is not unique". Dropping leaves exactly one df.start at every
-- arity.
--
-- Scenario B1 (new .so, un-upgraded schema) is preserved without the overload:
-- src/dsl.rs keeps the four-argument Rust fn start_v2() and therefore the
-- start_v2_wrapper symbol, marked #[pg_extern(sql = false)] so it contributes no
-- DDL. Pre-0.2.7 schemas declare df.start(text, text, text, text) against that
-- symbol and keep resolving to it; those instances run the pre-0.2.7 behaviour
-- (one attempt, then fail) and simply do not expose the new arguments. Because
-- sql = false emits nothing, a fresh 0.2.7 install has only the seven-argument
-- df.start, which is what this script produces too (Scenario A).
--
-- Note for existing callers: a four-argument df.start() on an upgraded schema
-- resolves to the new function and therefore picks up the new defaults, so a
-- workflow that used to fail on its first node error now retries five times and,
-- inside a loop, keeps running afterwards. Pass
-- max_attempts => 1, on_failure => 'fail' to restore the previous behaviour.
--
-- The CREATE FUNCTION block is the pgrx-generated fresh-install DDL for
-- src/dsl.rs::start_v3 copied verbatim, so the Scenario A snapshot matches a
-- fresh 0.2.7 install. New df.* functions retain PostgreSQL's default PUBLIC
-- EXECUTE (gated by USAGE ON SCHEMA df), so no explicit GRANT is needed.
-- ============================================================================
DROP FUNCTION IF EXISTS df.start(text, text, text, text);

-- pg_durable::dsl::start
CREATE  FUNCTION df."start"(
	"fut" TEXT, /* &str */
	"label" TEXT DEFAULT NULL, /* core::option::Option<&str> */
	"database" TEXT DEFAULT NULL, /* core::option::Option<&str> */
	"transaction_mode" TEXT DEFAULT 'caller', /* &str */
	"max_attempts" INT DEFAULT 1, /* i32 */
	"max_backoff" interval DEFAULT '16 seconds', /* pgrx::datum::interval::Interval */
	"on_failure" TEXT DEFAULT 'fail' /* &str */
) RETURNS TEXT /* alloc::string::String */

LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'start_v3_wrapper';

-- ============================================================================
-- df.instance_activity(): report whether an instance is making progress.
--
-- New in 0.2.7. Definition kept byte-identical to the fresh-install block in
-- src/lib.rs (extension_sql! name = "instance_activity") so the Scenario A
-- schema comparison matches.
-- ============================================================================

-- df.instance_activity(): is this workflow actually doing anything?
--
-- A long-running instance and a wedged one both read 'running', so status alone
-- cannot tell them apart. This reports when each non-terminal instance last
-- transitioned a node, how long it has been quiet since, and whether any node is
-- currently failing -- which is what a retrying-and-abandoning loop looks like
-- from the outside.
--
-- SECURITY INVOKER (the default) so the row-level security policies on
-- df.instances and df.nodes apply: a caller sees only their own instances.
-- Deliberately a function rather than a view, because view-level RLS
-- pass-through (security_invoker) requires PostgreSQL 15 and this extension
-- supports 13.
--
-- p_idle_for filters to instances quiet for at least that long. The default of
-- zero reports every non-terminal instance, so the common call is simply
--   SELECT * FROM df.instance_activity() ORDER BY idle_for_seconds DESC;
--
-- Idle time is measured against clock_timestamp(), not now(). now() is the
-- calling transaction's start time, and the worker keeps writing node
-- timestamps after that, so a busy instance's last activity can be *later*
-- than now() -- which would make its idle time negative and drop it below any
-- threshold, including zero. Reading a moving clock makes the function
-- VOLATILE, which is honest: two calls in one transaction can legitimately
-- differ.
--
-- GREATEST and EXTRACT are parser constructs and cannot be schema-qualified;
-- the pinned search_path resolves the remaining names to pg_catalog.
CREATE OR REPLACE FUNCTION df.instance_activity(p_idle_for interval DEFAULT '0 seconds')
RETURNS TABLE (
    instance_id VARCHAR(8),
    label TEXT,
    status TEXT,
    last_activity_at TIMESTAMPTZ,
    idle_for_seconds DOUBLE PRECISION,
    running_node_count BIGINT,
    failed_node_count BIGINT,
    last_error TEXT
)
LANGUAGE SQL
VOLATILE
SET search_path = pg_catalog, df, pg_temp
AS $fn$
    SELECT
        i.id,
        i.label,
        i.status,
        activity.last_activity_at,
        GREATEST(0, EXTRACT(EPOCH FROM pg_catalog.clock_timestamp() - activity.last_activity_at))::double precision,
        activity.running_node_count,
        activity.failed_node_count,
        activity.last_error
    FROM df.instances i
    CROSS JOIN LATERAL (
        SELECT
            -- GREATEST ignores NULLs, so an instance whose nodes have never
            -- transitioned still reports its own updated_at.
            GREATEST(i.updated_at, max(n.updated_at)) AS last_activity_at,
            count(*) FILTER (WHERE n.status = 'running') AS running_node_count,
            count(*) FILTER (WHERE n.status = 'failed') AS failed_node_count,
            -- A failed node's message is written to df.nodes.result, not to
            -- df.nodes.error, which nothing writes. #>> '{}' unwraps the JSONB
            -- scalar so the caller gets the message, not a quoted JSON string.
            (array_agg(n.result #>> '{}' ORDER BY n.updated_at DESC)
                FILTER (WHERE n.status = 'failed' AND n.result IS NOT NULL))[1] AS last_error
        FROM df.nodes n
        WHERE n.instance_id = i.id
    ) AS activity
    WHERE (i.status IS NULL OR i.status NOT IN ('completed', 'failed', 'cancelled'))
      AND pg_catalog.clock_timestamp() - activity.last_activity_at >= p_idle_for;
$fn$;

COMMENT ON FUNCTION df.instance_activity(interval) IS
    'Non-terminal instances with their last node transition, how long they have been idle, '
    'and any current node failure. Use to tell a working workflow from a wedged one, which '
    'status alone cannot show. RLS-filtered to the calling user.';
