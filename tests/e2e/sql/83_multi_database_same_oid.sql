-- Reuse the deterministic queued A-to-B schedule, but replace only the
-- extension. The database OID and the idle source connection remain alive.
\set e79_replace_extension true
\ir 79_multi_database_remote_origin.sql
