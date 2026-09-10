-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.7 -> 0.2.8
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).
--
ALTER FUNCTION df."loop"(TEXT, TEXT) RENAME TO "_loop_legacy";

CREATE FUNCTION df."loop"(
    "body" TEXT,
    "condition" TEXT DEFAULT NULL,
    "continue_on_failure" bool DEFAULT false
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'loop_with_policy_wrapper';

CREATE TABLE df._installation (
    singleton pg_catalog.bool PRIMARY KEY DEFAULT true CHECK (singleton),
    id pg_catalog.uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid()
);
INSERT INTO df._installation (singleton) VALUES (true);
REVOKE ALL ON TABLE df._installation FROM PUBLIC;
GRANT SELECT ON TABLE df._installation TO PUBLIC;

CREATE FUNCTION df.validate_installation() RETURNS bool
STRICT
LANGUAGE c
AS 'MODULE_PATHNAME', 'validate_installation_wrapper';

DO $$
BEGIN
    PERFORM df.validate_installation();
END $$;
