-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

BEGIN;

CREATE EXTENSION pg_durable;

ALTER EXTENSION pg_durable DROP SCHEMA _duroxide;
CREATE TABLE _duroxide.unit4_ownership_sentinel (
    marker TEXT PRIMARY KEY
);
INSERT INTO _duroxide.unit4_ownership_sentinel VALUES ('must-survive-ownership-refusal');

COMMIT;