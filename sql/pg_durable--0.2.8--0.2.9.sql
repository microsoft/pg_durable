-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.8 -> 0.2.9
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).
--
-- HTTP options are additive; existing function ABIs, OIDs and ACLs stay unchanged.
CREATE FUNCTION df."with_http_options"(
    "fut" TEXT,
    "options" jsonb
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'with_http_options_wrapper';
