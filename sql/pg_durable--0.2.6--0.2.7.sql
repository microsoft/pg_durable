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
	"max_attempts" INT DEFAULT 5, /* i32 */
	"max_backoff" interval DEFAULT '16 seconds', /* pgrx::datum::interval::Interval */
	"on_failure" TEXT DEFAULT 'continue' /* &str */
) RETURNS TEXT /* alloc::string::String */

LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'start_v3_wrapper';
