-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.0 → 0.2.1
--
-- No schema changes in this release.
-- This upgrade removes the dependency on the `ring` crate (switched to
-- native-tls), includes security hardening fixes, and other bug fixes.
