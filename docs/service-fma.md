# pg_durable Service-Level Failure Mode Analysis

**Status**: Draft
**Created**: 2026-03-24

---

## 1. Overview

This document analyzes failure modes for pg_durable **as a feature of a managed PostgreSQL-as-a-Service (PaaS) platform** — e.g., Azure Database for PostgreSQL Flexible Server. It covers infrastructure, control plane, data plane, and operational concerns that are outside the extension's own codebase but directly affect pg_durable users.

For extension-internal failure modes (background worker, activities, orchestrations, DSL, client), see [fma.md](fma.md).

**Assumptions**:
- pg_durable is deployed as a first-party extension on the PaaS platform.
- The extension `.so` is baked into the PostgreSQL engine image.
- `shared_preload_libraries` includes `pg_durable` on all nodes where the feature is enabled.
- The duroxide schema (`duroxide.*`) and extension schema (`df.*`) live in the same database.
- The background worker runs as the platform superuser role (e.g., `azuresu`).

---

## 2. Severity Definitions

| Level | Definition |
|-------|-----------|
| **SEV-1** | All pg_durable users in a region/stamp are impacted. Data loss or extended unavailability. |
| **SEV-2** | Subset of users affected, or degraded functionality across the service. |
| **SEV-3** | Single-server or single-tenant impact. Self-recoverable or cosmetic. |

---

## 3. Deployments

### SFM-1: Region Buildout — Missing Feature Registration

| Attribute | Detail |
|-----------|--------|
| **Scenario** | New region is enabled but the infrastructure subscription lacks feature registration for pg_durable (e.g., `shared_preload_libraries` allowlisting, extension package deployment, or ARM resource provider registration). |
| **Severity** | SEV-2 (new region only) |
| **Impact** | Customers in the new region cannot enable pg_durable. `CREATE EXTENSION pg_durable` fails or `shared_preload_libraries` rejects the library name. Existing regions unaffected. |
| **Programmatic mitigation** | Extension SQL includes a startup check: `pg_durable must be loaded via shared_preload_libraries` — fast-fails if misconfigured. |
| **Process mitigation** | Buildout checklist should include: (1) extension package deployed to region's image, (2) `shared_preload_libraries` allowlist updated, (3) ARM RP feature flag enabled. Validate with smoke test before region GA. |
| **Detection** | Customer-reported `CREATE EXTENSION` failures. Platform provisioning logs show missing extension in `pg_available_extensions`. |
| **Recommendation** | Add pg_durable to the region-buildout validation suite: after deployment, run `SELECT * FROM pg_available_extensions WHERE name = 'pg_durable'` and `SHOW shared_preload_libraries` on a canary server. |

### SFM-2: Region Buildout — Monitoring Not Configured

| Attribute | Detail |
|-----------|--------|
| **Scenario** | New region is enabled but platform monitoring (Geneva/Azure Monitor rules, dashboards, ICM connectors) hasn't been onboarded for pg_durable-specific signals. |
| **Severity** | SEV-2 |
| **Impact** | pg_durable failures in the new region go undetected by the service team. No alerts fire for worker crashes, stuck instances, or other FM-* scenarios from [fma.md](fma.md). |
| **Programmatic mitigation** | None — monitoring configuration is external to the extension. |
| **Process mitigation** | Buildout checklist should include monitoring validation. Use infrastructure-as-code for monitor/alert definitions so they deploy atomically with the region. |
| **Detection** | Periodic audit of monitoring coverage per region. Synthetic canary tests that verify alerts fire. |
| **Recommendation** | Define pg_durable monitoring rules as code (e.g., Azure Monitor alert rules in Bicep) and deploy them as part of the region buildout pipeline, not as a separate manual step. |

### SFM-3: Engine Image Deployment — Extension `.so` Missing or Mismatched

| Attribute | Detail |
|-----------|--------|
| **Scenario** | A new engine image is deployed to the fleet but the pg_durable `.so` is missing, is compiled against the wrong PostgreSQL major version, or is an older version than expected. |
| **Severity** | SEV-1 (if rollout is fleet-wide) or SEV-2 (if canary catches it) |
| **Impact** | On server restart with the new image, PostgreSQL fails to start because `shared_preload_libraries` references a missing/incompatible library. Or, PostgreSQL starts but pg_durable functions produce unexpected behavior due to binary-schema mismatch. See FM-15 in [fma.md](fma.md) for duroxide schema drift specifics. |
| **Programmatic mitigation** | The extension's `_PG_init()` fails fast if not loaded via `shared_preload_libraries`. The duroxide provider uses `MigrationPolicy::VerifyOnly` on backend connections (fails closed on schema mismatch). CI runs `test-upgrade.sh` to validate backward compatibility. |
| **Process mitigation** | Image build pipeline should: (1) compile the extension against the exact PG version in the image, (2) run smoke tests before fleet rollout, (3) use canary deployments. Docker CI (`docker.yml`) validates the image builds and passes E2E tests. |
| **Detection** | PostgreSQL fails to start → platform health check detects unresponsive server. Or, `df.version()` returns unexpected version after image update. |
| **Recommendation** | Add a post-deployment validation step that connects to a canary server and runs `SELECT df.version()`, verifying it matches the expected version in the release manifest. |

### SFM-4: Engine Image Deployment — Binary-Schema Gap During Rolling Update

| Attribute | Detail |
|-----------|--------|
| **Scenario** | New pg_durable `.so` is deployed via engine image update (fleet maintenance window). Customers have not yet run `ALTER EXTENSION pg_durable UPDATE`. The new binary runs against the old schema for hours, days, or indefinitely. |
| **Severity** | SEV-1 (if backward compat is broken) or SEV-3 (if tested and compatible) |
| **Impact** | If the new binary is not backward compatible with the old schema, durable functions fail silently or produce incorrect results. The background worker may crash-loop or activities may error. |
| **Programmatic mitigation** | CI enforces backward compatibility via `test-upgrade.sh` (Scenario B1: new `.so` against all previous schemas). The duroxide provider's `VerifyOnly` policy fails closed on schema mismatch. |
| **Process mitigation** | All code changes must pass upgrade tests before merge. Release notes must document any required `ALTER EXTENSION UPDATE` steps. The upgrade model is designed for an extended binary-schema gap. |
| **Detection** | Worker logs: `"failed to create PostgreSQL store (will retry)"` repeated — indicates schema verification failure. `df.metrics()` shows no progress. See FM-15 in [fma.md](fma.md). |
| **Recommendation** | For breaking schema changes, use a two-phase rollout: (1) deploy binary that supports both old and new schema, (2) after fleet adoption, deploy the schema migration via `ALTER EXTENSION UPDATE` guidance. Never ship a binary that requires the new schema to function. |

### SFM-5: Sidecar Deployment Failure

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Platform sidecars (monitoring agent, log collector, backup agent, security scanner) fail to deploy or crash on a node running pg_durable. |
| **Severity** | SEV-2 |
| **Impact** | pg_durable itself is unaffected (it runs inside the PostgreSQL process, not as a sidecar). However: (1) log collection failure means pg_durable worker logs and activity traces are not ingested — all detection mechanisms in [fma.md](fma.md) Section 4.3 become blind, (2) backup agent failure means duroxide state and extension tables may not be backed up, (3) monitoring agent failure means platform-level metrics (CPU, memory, connections) that are proxies for pg_durable health are missing. |
| **Programmatic mitigation** | None internal to pg_durable. |
| **Process mitigation** | Platform sidecar health monitoring. Ensure sidecar restarts don't trigger PostgreSQL restarts (process isolation). |
| **Detection** | Sidecar health checks. Gap in telemetry ingestion (missing log entries for expected time windows). |
| **Recommendation** | pg_durable's most critical observability data is in PostgreSQL server logs (`pgrx::log!` with `"pg_durable:"` prefix) and duroxide execution history (in `duroxide.*` tables). Ensure the log collector captures the PostgreSQL log file even if other sidecars fail. |

### SFM-6: Control Ring — Management Service Deployment Failure

| Attribute | Detail |
|-----------|--------|
| **Scenario** | An Orcas/Management Service (ARM RP) deployment fails or causes an outage. This includes the component that handles `CREATE SERVER`, `UPDATE SERVER`, and extension management operations. |
| **Severity** | SEV-1 (if management plane is down) |
| **Impact** | Customers cannot create new servers with pg_durable, cannot enable/disable the extension via portal/CLI, and cannot perform server scaling operations. **Running durable functions on existing servers are unaffected** — the data plane (PostgreSQL + background worker) operates independently of the management plane. |
| **Programmatic mitigation** | pg_durable has no dependency on the management plane at runtime. The background worker and all DSL/monitoring functions operate purely within the PostgreSQL process. |
| **Process mitigation** | Standard management service deployment safeguards (canary, rollback, health checks). |
| **Detection** | ARM RP health monitoring. Customer-reported provisioning failures. |
| **pg_durable-specific concern** | If the management service deployment includes a change to pg_durable's `shared_preload_libraries` configuration or GUC defaults, a failed rollout could leave servers in an inconsistent state where some have the new config and others don't. |

---

## 4. Service SLAs / KPIs and Customer Workflows

### SFM-7: Login Availability Below SLA

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Customer cannot authenticate to the PostgreSQL server. Login success rate drops below SLA. |
| **Severity** | SEV-1 |
| **Impact** | Customers cannot submit new durable functions (`df.start()`), check status (`df.status()`), or retrieve results (`df.result()`). **Running durable functions continue executing** — the background worker uses its own connection pool (authenticated at startup) and is not affected by frontend authentication failures. However, `execute_sql` activities that need to connect as a user role may fail if the authentication substrate is globally degraded. See FM-7 in [fma.md](fma.md). |
| **Programmatic mitigation** | The worker's sqlx pool is long-lived and reconnects independently. Activity connections use `SET ROLE` after connecting as the login role, which may succeed even if new logins are throttled (existing connections survive). |
| **Process mitigation** | Platform login availability monitoring and alerting. |
| **Detection** | Platform login success rate metric. `execute_sql` activity failures with auth-related errors in duroxide traces. |
| **pg_durable-specific concern** | The `execute_sql` activity opens a **new connection per SQL node** (not pooled). Under login degradation, each SQL node execution pays the full authentication cost and may fail. High-concurrency workflows amplify the impact. |

### SFM-8: Customer Cannot Connect (Network/Firewall)

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Customer connectivity is blocked by firewall rules, VNet misconfiguration, private endpoint issues, or DNS resolution failure. |
| **Severity** | SEV-3 (single customer) |
| **Impact** | Customer cannot interact with pg_durable at all (no DSL calls, no monitoring). **Running durable functions continue executing** — the background worker is local to the PostgreSQL process and doesn't traverse the customer's network path. Activities that execute SQL connect via the local socket/loopback, not through the customer-facing endpoint. |
| **Programmatic mitigation** | None — this is a platform networking concern. |
| **Detection** | Customer-reported. Platform connection metrics per server. |
| **pg_durable-specific concern** | If `df.http()` nodes target endpoints within the customer's VNet, those HTTP requests originate from the PostgreSQL server's network context, not the customer's client. Firewall rules must account for the server's egress IP, not the customer's ingress path. |

### SFM-9: Azure Compute Failure (Full)

| Attribute | Detail |
|-----------|--------|
| **Scenario** | The VM or container hosting the PostgreSQL server experiences a compute failure (hardware fault, hypervisor crash, VM eviction). |
| **Severity** | SEV-1 |
| **Impact** | PostgreSQL process terminates. Background worker dies. All in-flight activities are interrupted. **Duroxide's durability guarantee applies**: on restart, the worker replays incomplete orchestrations from the last checkpoint. Activities that were mid-execution are re-dispatched. See FM-17 in [fma.md](fma.md) for restart/replay behavior. |
| **Programmatic mitigation** | Duroxide's event-sourced architecture provides at-least-once execution. PostgreSQL's restart-time of the background worker (`set_restart_time(5s)`) ensures quick recovery. The epoch sentinel detects the restart and re-initializes cleanly. |
| **Process mitigation** | Platform HA: availability zone redundancy, automated failover, VM auto-restart. |
| **Detection** | Platform VM health monitoring. After restart: worker log `"pg_durable: duroxide background worker starting..."`. `df._worker_epoch` shows a new epoch UUID. |
| **pg_durable-specific concern** | **SQL activities have at-least-once semantics.** In-flight SQL statements are rolled back by PostgreSQL crash recovery, then re-dispatched by duroxide replay. Users must design SQL to be **idempotent** (`INSERT ... ON CONFLICT`, conditional UPDATEs). This is the single most important user-facing guidance for pg_durable on a PaaS. |

### SFM-10: Azure Storage Failure (Full)

| Attribute | Detail |
|-----------|--------|
| **Scenario** | The managed disk or storage subsystem backing PostgreSQL's data directory becomes unavailable or experiences data loss. |
| **Severity** | SEV-1 |
| **Impact** | PostgreSQL cannot read/write data. All pg_durable state is lost if storage is unrecoverable: `df.instances`, `df.nodes`, `df.vars`, and all `duroxide.*` tables (orchestration history, event log, activity state). **Total loss of durable function state.** There is no external state store — everything is in PostgreSQL. |
| **Programmatic mitigation** | None — pg_durable stores all state in PostgreSQL by design. There is no out-of-band state replication. |
| **Process mitigation** | Platform storage redundancy (LRS/ZRS/GRS). Point-in-time restore (PITR) from backups. |
| **Detection** | Platform storage health alerts. PostgreSQL `PANIC` logs. |
| **pg_durable-specific concern** | Duroxide's durability guarantee is **only as strong as the underlying PostgreSQL storage**. Unlike external orchestrators (Temporal, Azure Durable Functions) that have independent state stores, pg_durable's state lives in the same storage as user data. A storage failure that loses user data **also loses orchestration state**. Recovery via PITR restores both user data and pg_durable state to the same point-in-time, which is actually a consistency advantage — but any durable functions that completed between the restore point and the failure are lost. |

### SFM-11: Limited Azure Storage/Compute Failure

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Partial degradation: elevated I/O latency, intermittent storage errors, CPU throttling, or memory pressure. |
| **Severity** | SEV-2 |
| **Impact** | pg_durable operations slow down. `execute_sql` activities take longer. The duroxide runtime's polling intervals feel the latency. The worker's sqlx pool may experience connection timeouts. Under memory pressure, the Tokio runtime may fail to spawn tasks. Under CPU throttling, duroxide's orchestration dispatcher falls behind. |
| **Programmatic mitigation** | sqlx pool has built-in connection health checks. Duroxide polling is tolerant of latency (it just polls less frequently). Activity timeouts prevent indefinite blocking. |
| **Detection** | Platform I/O and CPU metrics. `df.metrics()` shows growing `running_instances` without corresponding `completed_instances` growth — see FM-16 in [fma.md](fma.md). Activity traces show increasing `duration_ms` for HTTP nodes. |
| **pg_durable-specific concern** | The background worker is a **single process** running inside PostgreSQL. It competes with user workloads for CPU and memory. Under resource pressure, user queries and durable function execution degrade together. There is no resource isolation between the worker and user sessions. |

---

## 5. Manageability

### SFM-12: Create Server

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Customer creates a new server with pg_durable enabled. The provisioning workflow must: (1) configure `shared_preload_libraries`, (2) set GUCs (`pg_durable.worker_role`, `pg_durable.database`), (3) ensure the worker role exists and is superuser, (4) run `CREATE EXTENSION pg_durable`. |
| **Severity** | SEV-3 (single server) |
| **Impact** | If any step fails, the server exists but pg_durable is non-functional. Common failure modes: (a) `shared_preload_libraries` not set → extension load fails (see FM-1 in [fma.md](fma.md)), (b) worker role doesn't exist or isn't superuser → silent failure (see FM-3 in [fma.md](fma.md)), (c) `CREATE EXTENSION` runs in wrong database → worker can't find extension (see FM-4 in [fma.md](fma.md)). |
| **Programmatic mitigation** | Extension SQL validates: `shared_preload_libraries` inclusion, worker role existence/superuser status, correct database. The validation emits errors (not just warnings) for critical misconfigurations in production builds. |
| **Process mitigation** | Provisioning workflow should have explicit pg_durable setup steps with validation at each stage. Post-provisioning smoke test: `SELECT df.version()`. |
| **Detection** | Provisioning workflow logs. Customer-reported. Post-provision health check. |
| **Recommendation** | Add a provisioning validation step that waits for the background worker to initialize (check `df._worker_epoch` has a recent `last_seen_at`) before marking the server as `Ready`. |

### SFM-13: Update Server — Compute Scale Up/Down

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Customer scales compute (vCPU/memory) up or down. This typically requires a server restart. |
| **Severity** | SEV-3 |
| **Impact** | PostgreSQL restarts. Background worker terminates and re-initializes. Same behavior as FM-17 in [fma.md](fma.md): duroxide replays incomplete orchestrations. **Brief interruption** to durable function execution during the restart window (typically seconds to a minute). |
| **Programmatic mitigation** | Duroxide replay handles restart. Worker auto-restarts after 5s. |
| **Process mitigation** | Scale operations should occur during maintenance windows when possible. Platform should drain active connections gracefully before restart. |
| **Detection** | New epoch UUID in `df._worker_epoch` after scale operation. Worker log: `"duroxide background worker starting..."`. |
| **pg_durable-specific concern** | Scaling **down** could push the server into resource pressure. If the worker's Tokio runtime or activity sqlx pool were sized for the larger tier, the reduced tier may not have enough memory/connections. GUCs like `max_connections` may be auto-adjusted, reducing headroom for activity connections. |

### SFM-14: Update Server — Storage Scale Up/Down

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Customer scales storage. May or may not require restart depending on platform. |
| **Severity** | SEV-3 |
| **Impact** | If restart is required: same as SFM-13. If online resize: pg_durable is unaffected — it doesn't manage storage directly. Scaling **down** could trigger disk space pressure if duroxide tables have grown large (see SFM-27). |
| **Programmatic mitigation** | None specific to pg_durable. |
| **Recommendation** | Before scaling storage down, check the size of `duroxide.*` tables: `SELECT pg_size_pretty(pg_total_relation_size('duroxide.instances'))`. Duroxide execution history can be significant for long-running or eternal functions. |

### SFM-15: Drop Server

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Customer or platform deletes the server. |
| **Severity** | SEV-3 (intentional) or SEV-1 (accidental) |
| **Impact** | All pg_durable state is permanently destroyed: instance history, node results, duroxide execution log, variables. There is no external backup of orchestration state. |
| **Programmatic mitigation** | None — state lives entirely in PostgreSQL. |
| **Process mitigation** | Platform soft-delete / retention period for dropped servers. Backup retention policies. |
| **pg_durable-specific concern** | Unlike external orchestrators that have independent state, pg_durable state is **co-located with the database**. Dropping the server also drops the orchestration engine and all its history. Users should be warned that dropping a server with active durable functions is irreversible. |

### SFM-16: Update Server — `shared_preload_libraries` Change

| Attribute | Detail |
|-----------|--------|
| **Scenario** | A server configuration change removes `pg_durable` from `shared_preload_libraries`, or a platform update resets the configuration. |
| **Severity** | SEV-1 (for that server) |
| **Impact** | After the next PostgreSQL restart, pg_durable's `_PG_init()` is not called. The background worker is never registered. Extension functions still exist (SQL objects), but the worker doesn't run. All pending/running durable functions stall. New `df.start()` calls succeed (they write to tables) but instances never execute. |
| **Programmatic mitigation** | `_PG_init()` errors if not in `shared_preload_libraries`. But this only fires when the library is explicitly loaded, not when it's absent. |
| **Detection** | Worker absence from `pg_stat_activity`. Empty or stale `df._worker_epoch`. `df.start()` succeeds but `df.status()` never transitions from `pending`. |
| **Recommendation** | Platform should treat `pg_durable` in `shared_preload_libraries` as an invariant when the extension is installed. Configuration changes that remove it should be blocked or warn explicitly. |

---

## 6. Disaster Recovery

### SFM-17: Point-in-Time Restore (PITR)

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Customer or platform initiates a PITR to a point before a data loss/corruption event. |
| **Severity** | SEV-2 |
| **Impact** | The restored database includes pg_durable state (`df.*` and `duroxide.*` tables) as of the restore point. Durable functions that **completed after the restore point are lost** — their results, status updates, and execution history revert. Durable functions that were `running` at the restore point will be **replayed from their last checkpoint** when the background worker starts on the restored server. Some activities may re-execute (at-least-once). |
| **Programmatic mitigation** | Duroxide's replay model handles partial state correctly — it replays from the last committed event. This is **the same behavior as a crash recovery** (see FM-17 in [fma.md](fma.md)). |
| **Process mitigation** | Document PITR behavior for pg_durable in the user guide. |
| **Detection** | After restore: `df._worker_epoch` shows a new epoch. Some instances may show statuses that don't match what the user last observed. |
| **pg_durable-specific concern** | PITR restores both user data and orchestration state to the same point-in-time. This is actually **better than external orchestrators** where the orchestration state and database are restored independently, requiring reconciliation. With pg_durable, the orchestration state is always consistent with the data it operated on. |
| **User recommendation** | After a PITR, check `df.list_instances('running')` — some workflows may re-execute activities. Ensure your SQL is idempotent. Workflows that completed after the restore point will appear in their pre-completion state. |

### SFM-18: Accidental Data Deletion by User

| Attribute | Detail |
|-----------|--------|
| **Scenario** | User accidentally runs `DELETE FROM df.instances` or `DROP TABLE df.nodes` or similar destructive DML/DDL against pg_durable tables. |
| **Severity** | SEV-2 (for that user/server) |
| **Impact** | **With RLS enabled**: User can only delete their own rows from `df.instances` and `df.nodes`. Other users' workflows are unaffected. The user's own workflows lose their tracking state, but duroxide still has the execution history in `duroxide.*` tables. If `duroxide.*` tables are intact, in-flight orchestrations continue — but status updates and result writes back to `df.instances`/`df.nodes` will fail (rows missing). **Without RLS / superuser**: All workflow state destroyed. |
| **Programmatic mitigation** | RLS limits blast radius to the calling user's own rows. Decision 8 in [rls.md](rls.md) grants no DELETE privilege to PUBLIC on `df.instances`/`df.nodes`, preventing accidental deletes by non-superusers entirely. |
| **Detection** | `update_instance_status` and `update_node_status` activities fail with update-zero-rows. Duroxide traces show failures. |
| **User recommendation** | Do not run DML directly against `df.*` tables. Use `df.cancel()` to stop workflows. If you accidentally deleted rows, contact your DBA — PITR may be needed. |

### SFM-19: Azure Regional Disaster / Full Region Failure

| Attribute | Detail |
|-----------|--------|
| **Scenario** | An entire Azure region becomes unavailable. |
| **Severity** | SEV-1 |
| **Impact** | All pg_durable workloads in the region are unavailable. If geo-redundant backups are configured, the database (including all pg_durable state) can be restored in another region. pg_durable state is recovered along with the database — no separate state recovery needed. |
| **Programmatic mitigation** | None specific to pg_durable. State co-location with the database means DR procedures restore everything atomically. |
| **Process mitigation** | Geo-redundant backups. Cross-region read replicas (if supported — note: pg_durable's background worker only runs on the primary). |
| **pg_durable-specific concern** | **Read replicas cannot run durable functions.** The background worker only operates on the primary. If a read replica is promoted during DR, the worker will start on the new primary and begin processing. In-flight workflows replay from the last replicated checkpoint. The replication lag determines how much orchestration progress is lost. |

### SFM-20: Restoring an Accidentally Dropped Server

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Server was dropped and needs to be recovered from the platform's retention/soft-delete mechanism. |
| **Severity** | SEV-1 |
| **Impact** | If the platform supports soft-delete recovery, the full database (including pg_durable state) is restored. `shared_preload_libraries` and GUC configuration must be re-applied. The background worker will start fresh — duroxide replays any incomplete orchestrations. |
| **pg_durable-specific concern** | Ensure the restored server has the same `pg_durable.worker_role` and `pg_durable.database` GUC values. If the worker role was dropped as part of cleanup, it must be recreated before the worker can operate. |

---

## 7. Reliability / Performance

### SFM-21: IOPS Limit Reached

| Attribute | Detail |
|-----------|--------|
| **Scenario** | The server hits its provisioned IOPS limit due to high I/O from user workloads, duroxide polling, or activity execution. |
| **Severity** | SEV-2 |
| **Impact** | All database operations slow down, including pg_durable. Duroxide polling (long-poll or interval-based) becomes slower. Activity SQL execution takes longer. Status updates to `df.instances`/`df.nodes` are delayed. Users observe workflows completing slowly. The worker's throughput decreases proportionally. |
| **Programmatic mitigation** | Duroxide uses long-polling (reduces unnecessary I/O vs. tight polling). Activity connections are opened on-demand and closed after use (no persistent per-user pool). |
| **Detection** | Platform IOPS metrics at provisioned limit. `df.metrics()` shows growing `running_instances` without `completed_instances` growth. Activity trace durations increase. |
| **pg_durable-specific concern** | Duroxide's polling-based dispatcher generates **baseline IOPS** even when idle. Each poll cycle queries the `duroxide.*` tables. Under IOPS contention, this baseline load compounds the problem. Additionally, each `execute_sql` activity writes: (1) activity start event, (2) SQL execution, (3) activity completion event, (4) node status update, (5) instance status update — **5+ write operations per SQL node**. High-throughput workflows with many SQL nodes generate significant write IOPS. |
| **User recommendation** | Monitor your server's IOPS utilization. If durable function throughput degrades coincident with IOPS saturation, scale to a higher IOPS tier or reduce concurrent workflow submissions. |

### SFM-22: Write Latency High

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Storage write latency is elevated (slow disk, storage throttling, VNet latency to remote storage). |
| **Severity** | SEV-2 |
| **Impact** | Every duroxide event, activity checkpoint, and status update involves a write. Orchestration progress slows proportionally to write latency. `df.start()` (which inserts into `df.instances` and `df.nodes`) becomes slow from the user's perspective. `execute_sql` activities that perform writes are doubly affected (user SQL write + duroxide checkpoint write). |
| **Detection** | Platform storage latency metrics. User-perceived `df.start()` latency. Duroxide execution durations increase across the board. |
| **pg_durable-specific concern** | Duroxide's event-sourcing model is **write-heavy by design**. Every activity invocation, every orchestration decision, and every checkpoint is an INSERT into `duroxide.*` tables. pg_durable amplifies write-latency impact more than a typical read-heavy PostgreSQL workload. |

### SFM-23: Resource Usage High (CPU/Memory)

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Server CPU or memory utilization is high from user workloads, leaving insufficient resources for the pg_durable background worker. |
| **Severity** | SEV-2 |
| **Impact** | The background worker competes with user backend processes for CPU and memory. Under memory pressure, the Tokio runtime may fail to allocate buffers. Under CPU saturation, duroxide's dispatcher thread can't keep up with orchestration decisions. Activity throughput drops. In extreme cases, PostgreSQL's OOM killer terminates the worker process. |
| **Programmatic mitigation** | PostgreSQL auto-restarts the background worker after termination (5s delay). The worker has minimal steady-state memory (main allocation is the sqlx pool and Tokio runtime). |
| **Detection** | Platform CPU/memory metrics. Worker crashes appear as restarts in `df._worker_epoch` (new epoch UUID). Repeated entries in PostgreSQL log: `"pg_durable: duroxide background worker starting..."`. |
| **pg_durable-specific concern** | There is **no resource isolation** between the background worker and user sessions. No cgroup, no memory limit, no CPU pinning. The worker is a regular PostgreSQL background worker process. On a server running both heavy user queries and many durable functions, the two workloads contend for the same resources. See FM-16 in [fma.md](fma.md) for the single-worker bottleneck analysis. |

### SFM-24: Server Crash Due to Lack of Resources

| Attribute | Detail |
|-----------|--------|
| **Scenario** | PostgreSQL crashes due to OOM, disk full, or other resource exhaustion. |
| **Severity** | SEV-1 |
| **Impact** | Same as SFM-9 (compute failure). All in-flight activities interrupted. Duroxide replays after recovery. Risk of corruption if crash occurs during a WAL write for duroxide tables. PostgreSQL's crash recovery (WAL replay) restores consistency. |
| **pg_durable-specific concern** | If the crash was caused by duroxide's own resource consumption (e.g., a runaway loop creating unbounded execution history), the crash-and-restart cycle may repeat. The worker will restart, pick up the same runaway orchestration, and consume resources again. See FM-10 in [fma.md](fma.md) for infinite loop scenarios. Without a max-duration or max-iteration limit, this creates a **crash loop**. |
| **Recommendation** | Implement a circuit breaker: if the worker crashes N times within a window, delay restart progressively. Add a system-level `pg_durable.max_instance_duration_seconds` GUC to auto-cancel runaway instances. |

---

## 8. Monitoring

### SFM-25: Issues Not Detected (TTD Gap)

| Attribute | Detail |
|-----------|--------|
| **Scenario** | A pg_durable failure occurs but the service team doesn't detect it. |
| **Severity** | SEV-2 |
| **Impact** | Customer workflows are broken but no alert fires. Time-to-detect (TTD) is driven by customer complaint rather than proactive monitoring. |
| **Current detection capabilities** | See [fma.md](fma.md) Section 4 for the full telemetry inventory. Key signals: <ul><li>PostgreSQL server logs with `"pg_durable:"` prefix (~25 lifecycle messages)</li><li>Epoch sentinel heartbeat in `df._worker_epoch`</li><li>`df.metrics()` aggregate counters (total/running/completed/failed instances)</li><li>Duroxide activity traces (stored in `duroxide.*` tables)</li></ul> |
| **Gaps** | <ul><li>**No `df.worker_status()` SQL function** for health checks — operators must query system catalogs or parse logs</li><li>**No queue depth metric** — pending work is invisible without querying `df.instances`</li><li>**No throughput metric** — activities/second, instances completed/minute are not tracked</li><li>**No latency percentiles** — no p50/p95/p99 for activity duration or end-to-end instance completion</li><li>**No structured event stream** — all telemetry is in unstructured PostgreSQL logs or stored in duroxide tables; no integration with Azure Monitor, Geneva, or other PaaS monitoring systems</li><li>**Silent monitoring function failures** — `df.list_instances()`, `df.instance_info()` return empty results on internal errors rather than raising warnings</li></ul> |
| **Recommendation** | Build a PaaS monitoring integration that: (1) periodically calls `df.metrics()` and publishes to Azure Monitor as custom metrics, (2) checks `df._worker_epoch.last_seen_at` for worker liveness, (3) queries `SELECT count(*) FROM df.instances WHERE status = 'pending' AND created_at < now() - interval '5 minutes'` for stuck-instance detection. See also [fma.md](fma.md) Section 4.2 for the complete gap analysis. |

### SFM-26: Issues Detected Too Slowly (TTD Below Target)

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Alerts exist but fire too late — e.g., a log-based alert has a 5-minute ingestion delay, or a metric threshold is set too high. |
| **Severity** | SEV-2 |
| **Impact** | Customers experience extended downtime before the service team is engaged. |
| **pg_durable-specific concern** | The epoch sentinel heartbeat (`df._worker_epoch.last_seen_at`) is updated every ~5 seconds during the worker's main loop. If log ingestion has a 5-minute lag, a worker crash at T=0 isn't detectable via logs until T=5min. Direct database queries against `df._worker_epoch` would detect it within 10–15 seconds. |
| **Recommendation** | For the fastest TTD, use a **synthetic canary** that periodically submits a trivial durable function (`df.start(df.sql('SELECT 1'), 'canary')`) and verifies completion within an expected SLA (e.g., 30 seconds). This is an end-to-end health probe that catches all failure modes: worker down, connection failures, permission issues, schema drift, resource exhaustion. |

### SFM-27: Issues Mitigated Too Slowly (TTM Below Target)

| Attribute | Detail |
|-----------|--------|
| **Scenario** | An issue is detected but mitigation takes too long — e.g., worker restart requires manual intervention, or a configuration change needs a PostgreSQL restart. |
| **Severity** | SEV-2 |
| **Impact** | Extended customer impact. |
| **pg_durable-specific concern** | Two GUCs (`pg_durable.worker_role`, `pg_durable.database`) are `PGC_POSTMASTER` — they require a full PostgreSQL restart to change. If the mitigation involves changing these values, TTM includes the restart window plus any HA failover time. The background worker auto-restarts after a crash (5s delay), so crash-related mitigations are fast. But for configuration issues (wrong role, wrong database), there is no way to reconfigure without a restart. |
| **Recommendation** | Provide a runbook for common pg_durable mitigations. Include expected TTM for each: <ul><li>Worker crash → auto-recovery in ~5s (no action needed)</li><li>Worker role misconfigured → PostgreSQL restart required (~30s–2min depending on HA)</li><li>Extension dropped accidentally → `CREATE EXTENSION pg_durable` (state is lost, but worker recovers)</li><li>Runaway instance → `SELECT df.cancel('instance-id')` (immediate)</li><li>Schema corruption → PITR (minutes to hours depending on database size)</li></ul> |

---

## 9. Billing 

### SFM-28: Incorrect Billing / Metering

| Attribute | Detail |
|-----------|--------|
| **Scenario** | pg_durable's resource consumption is not properly accounted for in billing, or customers are charged for resources consumed by the background worker's internal operations. |
| **Severity** | SEV-2 |
| **Impact** | If billing is based on compute time, storage, or IOPS: the background worker's polling, activity execution, and duroxide state management generate measurable resource consumption. This is "extension overhead" that the customer didn't explicitly trigger. Storage for `duroxide.*` tables grows with orchestration history and may be significant for high-volume users. |
| **pg_durable-specific concern** | Duroxide tables (`duroxide.instances`, `duroxide.execution_events`, etc.) can grow very large for: (a) eternal/looping functions (each iteration creates a new execution), (b) functions with many parallel branches (high event count), (c) long-running functions (event history accumulates). There is currently **no automatic purge/TTL** for completed duroxide state. A customer with thousands of completed workflows accumulates unbounded storage in `duroxide.*`. |
| **Recommendation** | (1) Document pg_durable's storage overhead in the pricing FAQ. (2) Implement a TTL/purge mechanism for completed orchestration history (e.g., `pg_durable.history_retention_days` GUC). (3) Include `duroxide.*` table sizes in storage usage dashboards so customers can see the breakdown. |

---

## 10. Service Components

### SFM-29: Backup — Full/Diff/Log Backups Out of SLO

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Platform backup jobs (full, differential, or WAL archiving) exceed their SLO windows. |
| **Severity** | SEV-2 |
| **Impact** | RPO (Recovery Point Objective) increases. If a failure occurs during the backup gap, more pg_durable state is lost on PITR. Backup operations competing for I/O may slow duroxide's write-heavy workload (see SFM-21). |
| **pg_durable-specific concern** | Duroxide's write amplification (multiple events per activity, event-sourced model) increases WAL volume. High-throughput durable function workloads generate more WAL than typical OLTP, which extends backup times. Large duroxide tables increase full/differential backup size. |
| **Recommendation** | Monitor WAL generation rate for servers with pg_durable enabled. Consider automatic vacuuming and table maintenance for `duroxide.*` tables. |

### SFM-30: Backup — Detected Corrupt Backups

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Backup integrity check reveals corruption in a backup that includes pg_durable state. |
| **Severity** | SEV-1 |
| **Impact** | The backup may not be usable for PITR. Last known good backup determines actual RPO. pg_durable state may be irrecoverable for the affected window. |
| **pg_durable-specific concern** | Because pg_durable state is in PostgreSQL tables (not an external store), backup corruption affects orchestration state equally. There is no secondary copy or replication target for duroxide state. |
| **Recommendation** | Standard backup integrity validation applies. No pg_durable-specific action needed — corrupted backups are a platform-level concern. |

### SFM-31: Backup — Azure Storage Failure

| Attribute | Detail |
|-----------|--------|
| **Scenario** | The Azure Storage account used for backups becomes unavailable. |
| **Severity** | SEV-1 |
| **Impact** | Backups cannot be written. RPO effectively becomes "last successful backup." If the primary database also fails, pg_durable state is unrecoverable past the last good backup. Active durable functions are unaffected (they run from primary storage). |
| **pg_durable-specific concern** | None specific beyond the general database concern. |

### SFM-32: Restore — Slow or Hung Restore

| Attribute | Detail |
|-----------|--------|
| **Scenario** | A PITR or full restore operation takes longer than expected or hangs. |
| **Severity** | SEV-2 |
| **Impact** | Extended RTO (Recovery Time Objective). pg_durable is unavailable for the duration. After restore completes, the background worker starts fresh and duroxide replays orchestrations — adding additional time before durable functions resume processing. |
| **pg_durable-specific concern** | Large `duroxide.*` tables increase restore time. The post-restore duroxide replay phase adds latency before the worker is fully operational. For servers with many in-flight orchestrations at the restore point, the replay phase can be significant. |
| **Recommendation** | Include duroxide table sizes in restore-time estimation. Consider adding a `df.purge_completed(older_than interval)` function to help customers manage duroxide table sizes. |

### SFM-33: Storage — Loss of Data Files or WAL

| Attribute | Detail |
|-----------|--------|
| **Scenario** | Primary data files or WAL segments for the PostgreSQL data directory are lost or corrupted. |
| **Severity** | SEV-1 |
| **Impact** | If WAL is intact: PostgreSQL crash recovery may restore consistency, and pg_durable state is recovered along with all other data. If data files for `duroxide.*` or `df.*` tables are lost: those tables are unreadable. Worker enters retry loop (can't read duroxide schema). PITR is required. |
| **pg_durable-specific concern** | The `duroxide.*` schema and `df.*` schema are stored in the same tablespace as user data (default tablespace). There is no separation. Loss of tablespace data files affects pg_durable equally. |

### SFM-34: Storage — Corrupt Page in pg_durable Tables

| Attribute | Detail |
|-----------|--------|
| **Scenario** | A data page corruption is detected in a `df.*` or `duroxide.*` table. |
| **Severity** | SEV-2 |
| **Impact** | Queries against the corrupted table fail. If `duroxide.instances` or `duroxide.execution_events` is corrupted, the runtime may fail to dispatch or replay orchestrations. If `df.instances` is corrupted, `df.status()` and `df.list_instances()` fail. If `df.nodes` is corrupted, `load_function_graph` fails for affected instances. |
| **Programmatic mitigation** | PostgreSQL's `data_checksums` (if enabled) detects corruption at read time. The `pg_surgery` extension can skip corrupted tuples. |
| **Detection** | PostgreSQL log: `WARNING: page verification failed`. Worker retry logs if duroxide tables are affected. |
| **pg_durable-specific concern** | Duroxide's event-sourced model means a corrupt page in `duroxide.execution_events` could affect replay of multiple orchestrations — not just one. The impact radius of a single corrupt page may be broader than for a typical application table. |
| **Recommendation** | Enable `data_checksums` on all managed PostgreSQL instances running pg_durable. Monitor for checksum failure warnings. |

---

## 11. Summary: Detection Matrix

Cross-references each service failure mode with the detection mechanisms available.

| SFM | Platform Metrics | PG Server Logs | `df.metrics()` | `df._worker_epoch` | Synthetic Canary | Gap? |
|-----|:---:|:---:|:---:|:---:|:---:|:---:|
| SFM-1 (Feature registration) | | | | | Y | |
| SFM-2 (Monitoring gaps) | | | | | | **Yes** — meta-gap |
| SFM-3 (Image mismatch) | Y (health) | Y | | | Y | |
| SFM-4 (Binary-schema gap) | | Y | Y | | Y | |
| SFM-5 (Sidecar failure) | Y | | | | | |
| SFM-6 (Control ring) | Y | | | | | |
| SFM-7 (Login SLA) | Y | | | | Y | |
| SFM-8 (Connectivity) | Y | | | | | |
| SFM-9 (Compute failure) | Y | Y | | Y | Y | |
| SFM-10 (Storage failure) | Y | Y | | | | |
| SFM-11 (Resource degradation) | Y | | Y | | Y | |
| SFM-12 (Create server) | | Y | | Y | Y | |
| SFM-13 (Scale compute) | | Y | | Y | | |
| SFM-14 (Scale storage) | | | | | | |
| SFM-15 (Drop server) | Y | | | | | |
| SFM-16 (Config change) | | | | Y | Y | |
| SFM-17 (PITR) | | Y | | Y | | |
| SFM-18 (Accidental delete) | | | | | | **Yes** — no alert |
| SFM-19 (Regional DR) | Y | | | | | |
| SFM-20 (Restore dropped) | | Y | | Y | | |
| SFM-21 (IOPS limit) | Y | | Y | | Y | |
| SFM-22 (Write latency) | Y | | | | Y | |
| SFM-23 (CPU/Memory) | Y | Y | | Y | | |
| SFM-24 (Crash loop) | Y | Y | | Y | | **Partial** — no circuit breaker metric |
| SFM-25 (TTD gap) | | | | | | **Yes** — see details |
| SFM-26 (Slow TTD) | | | | Y | Y | |
| SFM-27 (Slow TTM) | | Y | | | | |
| SFM-28 (Billing) | | | | | | **Yes** — no duroxide storage metric |
| SFM-29 (Backup SLO) | Y | | | | | |
| SFM-30 (Corrupt backup) | Y | | | | | |
| SFM-31 (Backup storage) | Y | | | | | |
| SFM-32 (Slow restore) | Y | | | | | |
| SFM-33 (Data file loss) | Y | Y | | | | |
| SFM-34 (Corrupt page) | | Y | | | | |

**Key takeaways**:
- A **synthetic canary** (submit and verify a trivial workflow) detects the widest range of failure modes end-to-end.
- **`df._worker_epoch`** is the best pg_durable-specific liveness signal — but requires direct database access, not log scraping.
- **`df.metrics()`** is useful for throughput degradation detection but lacks queue depth, latency percentiles, and storage size metrics.
- The largest detection gaps are in **billing/storage accounting** and **accidental user-side data deletion**.
