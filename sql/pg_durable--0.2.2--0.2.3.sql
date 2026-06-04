-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.2 → 0.2.3
--
-- Introduces df.duroxide_schema(), a helper that reports which schema holds the
-- duroxide provider objects for this install. Fresh 0.2.3 installs create the
-- provider objects in the '_duroxide' schema (see lib.rs). Installs upgrading
-- from <= 0.2.2 already have their provider objects in the legacy 'duroxide'
-- schema and must keep using it — renaming an in-use schema would orphan the
-- background worker's durable state. This upgrade therefore defines
-- df.duroxide_schema() to return 'duroxide' for pre-existing installs.
--
-- Backend sessions and the background worker call df.duroxide_schema() to learn
-- which schema to use, falling back to 'duroxide' when the helper is absent
-- (installs predating it). No schema rename, drop, or data movement occurs.

CREATE FUNCTION df.duroxide_schema() RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, pg_temp
    AS $$ SELECT 'duroxide'::text $$;
