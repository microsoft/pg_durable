-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.7 -> 0.2.8
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).
--
-- pg_durable::dsl::loop
CREATE FUNCTION df."loop"(
    "body" TEXT,
    "continue_on_failure" bool
) RETURNS TEXT
STRICT
LANGUAGE c
AS 'MODULE_PATHNAME', 'loop_continue_on_failure_wrapper';
