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

CREATE FUNCTION df.endpoint_option_validator(
    "options" pg_catalog.text[],
    "catalog" pg_catalog.oid
) RETURNS pg_catalog.void
LANGUAGE c STRICT
AS 'MODULE_PATHNAME', 'endpoint_option_validator_wrapper';

CREATE FOREIGN DATA WRAPPER pg_durable_fdw
    NO HANDLER VALIDATOR df.endpoint_option_validator;
REVOKE ALL ON FOREIGN DATA WRAPPER pg_durable_fdw FROM PUBLIC;
