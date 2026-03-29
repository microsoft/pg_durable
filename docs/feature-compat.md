# Azure PostgreSQL Flexible Server — Feature Compatibility Analysis

**Date:** 2026-03-24

## Architecture Summary (relevant to compatibility)

pg_durable is a `shared_preload_libraries` extension with a background worker (BGW).
All state lives in WAL-logged tables across two schemas (`df.*` and `duroxide.*`) in a single database.
The BGW connects back to PostgreSQL via **TCP/IP** (`127.0.0.1`) using `sqlx`—it does **not** use SPI or shared memory.
The BGW starts at `BgWorkerStartTime::RecoveryFinished` and auto-restarts after 5 seconds on failure.
Activity connections are also TCP, authenticated as the worker role (default `azuresu`) with `SET ROLE` to the submitting user.
No passwords are included in the connection string; local `trust` or `peer` authentication is assumed.

## Compatibility Matrix

| Feature | Compat | Risk Summary | Effort |
|---------|--------|--------------|--------|
| **Automated Backups** | Complete | All state is WAL-logged; no out-of-band files. Backup captures a fully consistent snapshot. | None |
| **Point-in-Time Recovery (PITR)** | Complete | Restores the database to a consistent mid-execution state. Duroxide replays orchestration history and retries in-flight activities (at-least-once semantics, by design). No data loss. | None |
| **High Availability (zone-redundant)** | Complete | Standby receives all WAL. On failover the new primary starts the BGW after recovery (`RecoveryFinished`). BGW reconnects to `127.0.0.1` on the new host. In-flight TCP connections die; duroxide retries activities automatically. Brief unavailability (~5 s BGW restart + failover time). | None |
| **Read Replicas** | Partial | BGW does **not** start on replicas (`RecoveryFinished` never fires on a hot standby). Read-only queries (`df.status()`, `df.result()`) work. Write calls (`df.start()`) error because the replica is read-only. This is the correct, expected behavior. | Low — document that `df.start()` is primary-only. Expose a read-only `df.status()` helper if needed. |
| **Customer-Managed Keys (CMK)** | Complete | CMK provides transparent disk-level encryption. pg_durable uses only regular heap tables and WAL; encryption is invisible to the extension. | None |
| **Major Version Upgrade** | Partial | Azure uses `pg_upgrade` internally. Extension data (`df.*`, `duroxide.*` tables, indexes, RLS policies) survives the upgrade. The main constraint is that the `.so` must be recompiled per PG major version (pgrx ABI). Azure must ship the matching `.so` for each supported version. Duroxide migrations are idempotent (`ApplyAll`), so the BGW re-initializes cleanly. | Medium — build and test the extension against each target PG major version. Verify `pg_upgrade --check` passes with pg_durable installed. |
| **Logical Replication** | Partial | `df.*` tables can be published, but replicating to a second cluster that also runs a BGW would cause duplicate activity execution and queue contention. Useful for read-only analytics replicas only. | Medium — if needed, add publication/subscription guidance and document that the target must **not** run a BGW. |
| **Connection Pooling (PgBouncer)** | Complete | The built-in PgBouncer proxy (port 6432) is on the client-facing path only. The BGW connects directly to PG (port 5432) via `127.0.0.1`, bypassing PgBouncer entirely. User sessions calling DSL functions use SPI (in-process), not pooled connections. | None |
| **Azure AD / Entra ID Auth** | Partial | The BGW connection string contains no password (`postgres://azuresu@127.0.0.1:…`). It relies on `trust` or `peer` for the loopback connection. If Azure enforces password/SCRAM for all connections (including loopback from the BGW), authentication will fail. Activity connections (`connect_as_user`) also use password-less options with just the username. | Medium — add optional password/token support to the connection builder (e.g., read `PGPASSWORD` or integrate Azure managed-identity token acquisition). |
| **Virtual Network / Private Endpoint** | Complete | BGW connects to `127.0.0.1` (loopback). No external network calls are made by the extension itself. Future HTTP activity support would need outbound rules. | None |
| **Storage Auto-grow** | Complete | Transparent to the extension. Table bloat from `duroxide.history` may accelerate storage growth under heavy workloads but is managed by normal VACUUM/autovacuum. | None |
| **Monitoring (Azure Metrics / pg_stat)** | Partial | BGW connections appear as regular backends in `pg_stat_activity`. `df.status()` provides per-instance monitoring. However, no Azure-native metrics integration exists (no custom metrics emitted to Azure Monitor). | Low — emit metrics to `pg_stat_user_tables` or a custom stats view; Azure-side integration would need a metrics extension or external exporter. |
| **Extension Allowlisting** | Blocked | pg_durable is not on the Azure PG Flexible Server allowlist today. It also requires `shared_preload_libraries` (a server-level config that demands a restart), which Azure only supports for a curated set of extensions (e.g., `pg_cron`, `pg_stat_statements`). The control file sets `superuser = true` and `trusted = false`. | High — requires Azure PG team onboarding: add to allowlist, configure `shared_preload_libraries` support, allocate the `azuresu` worker role, and configure `pg_hba.conf` for password-less loopback. |

## Key Architectural Properties

| Property | Value | Why it matters |
|----------|-------|----------------|
| State storage | WAL-logged heap tables only | Survives backup, PITR, HA failover, `pg_upgrade` |
| Shared memory | None (`enable_shmem_access(None)`) | No cross-process state to lose on failover |
| BGW start time | `RecoveryFinished` | Correct: starts on primary after crash recovery, does **not** start on standbys/replicas |
| BGW restart delay | 5 seconds | Brief gap after crash/failover; acceptable |
| Connection method | TCP via `sqlx` to `127.0.0.1` | Survives failover (new host, same loopback); bypasses PgBouncer; but requires local auth trust |
| Authentication | Username only, no password | Works with `trust`/`peer` `pg_hba.conf` rules; needs work for password-mandatory environments |
| Duroxide recovery | Replay from `duroxide.history` | Crash-safe; in-flight activities retried (at-least-once) |

## Recommendations

1. **Extension onboarding** is the critical-path blocker. Engage the Azure PG team early to add `pg_durable` to `shared_preload_libraries` support and the extension allowlist.
2. **Authentication hardening**: Add optional password / managed-identity token support to `postgres_connection_string()` and `connect_as_user()` for environments that do not allow password-less loopback.
3. **Major version upgrade testing**: Add a CI job that runs `pg_upgrade --check` (and a full upgrade) with pg_durable installed to catch ABI or catalog issues before release.
4. **Read replica documentation**: Document that `df.start()` is primary-only and that `df.status()`/`df.result()` work on read replicas for monitoring.
