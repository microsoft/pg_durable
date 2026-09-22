# Multi-Database Extension Installation

**Status:** Unreleased 0.2.9 integration with admission-based source fencing.
See [Deferred Lifetime Guarantees](#release-blockers) before destructive removal.
**Date:** 2026-09-10

## Summary

pg_durable already supports executing a workflow's SQL in another database through
the `database` argument to `df.start()`. That feature is documented in
[`multi-database.md`](multi-database.md). This document describes a different
capability: installing `pg_durable` in multiple databases so each database has a
local `df` API, local metadata, local privileges, and local transaction semantics.

The implemented architecture is:

- Keep exactly one Duroxide runtime and provider schema in the database selected by
  `pg_durable.database`. This is the **control database**.
- Require an explicit control-plane `CREATE EXTENSION pg_durable` in that database.
  Preloading starts worker initialization and control-installation checks, but
  creates no provider objects before explicit `CREATE EXTENSION`.
- Permit additional **satellite installations** in other databases. Each satellite
  owns its local `df` schema, `df.instances`, `df.nodes`, `df.vars`, functions,
  privileges, and RLS policies, but no active Duroxide provider schema.
- Namespace satellite engine IDs with the origin database and installation identity.
  Activities derive their route from `ActivityContext`; recorded orchestration and
  activity payloads are unchanged. Duroxide client operations use the control database.
- Treat the control installation as the lifecycle anchor. Do not attempt automatic
  cross-database reference counting for creation or removal of the runtime.

This preserves the most important local behavior: a normal `df.start()` writes its
graph in the caller's transaction and is rolled back with that transaction.

## Problem Frame

PostgreSQL extensions and their dependencies are database-local. The pg_durable
background worker, however, is registered once per cluster from
`shared_preload_libraries`, and the desired Duroxide runtime is also cluster-wide.
Through shipped 0.2.8, the extension could be installed only in `pg_durable.database`.

Users instead expect this topology:

```mermaid
flowchart LR
    A[Database A<br/>df API and metadata] --> R[One Duroxide runtime]
    C[Database C<br/>df API and metadata] --> R
    R --> B[Control database B<br/>Duroxide provider schema]
    R --> A
    R --> C
    R --> D[Optional SQL target database D]
```

The origin database, Duroxide control database, and SQL execution database are
three distinct concepts. They may be the same database, but the implementation
must not assume that they are.

## Requirements

### Installation And Lifecycle

- **R1.** `CREATE EXTENSION pg_durable` must remain required in
  `pg_durable.database` before provider creation and durable execution start.
  Worker initialization, management connections, and polling may precede it.
- **R2.** `CREATE EXTENSION pg_durable` must be allowed in additional databases once
  a compatible control installation exists.
- **R3.** A satellite installation must create its local `df` API and metadata but
  must not create or own a second active Duroxide provider schema.
- **R4.** Dropping a satellite must not stop the shared runtime or remove the
  control database's Duroxide schema.
- **R5.** Dropping the control installation must stop the runtime and remove the
  provider schema as it does today. Remaining satellites must fail new control-plane
  operations with a clear "control installation unavailable" error.
- **R6.** Loading `pg_durable` through `shared_preload_libraries` without a control
  installation must continue to leave no Duroxide schema behind.

### Workflow Behavior

- **R7.** A workflow started in database A must persist `df.instances`, `df.nodes`,
  and `df.vars` state in A, subject to A's RLS and extension privileges.
- **R8.** The default SQL execution database must be the database where
  `df.start()` was called. An explicit `database` argument may still target another
  database on the cluster.
- **R9.** `transaction_mode => 'caller'` must retain its current commit/rollback
  behavior. The worker must probe graph visibility and the originating XID in the
  origin database.
- **R10.** Status, result, explain, signal, cancel, await, and instance-listing APIs
  called in A must operate on A's local instances while consulting the shared
  Duroxide store when engine state is required.
- **R11.** Engine instance identity must be globally unique across installations;
  two databases generating the same current eight-character local ID must not
  address the same Duroxide orchestration.

### Security And Operations

- **R12.** SQL nodes must continue to connect as the captured `current_user` in the
  execution database. Installing pg_durable in another database must not grant that
  role any new execution privilege there.
- **R13.** The worker credential must be authorized explicitly in every satellite
  database it manages. A non-superuser `BYPASSRLS` role still needs the necessary
  object privileges and `CONNECT` privilege.
- **R14.** HTTP privilege checks must be evaluated against `df.http()` or
  `df.http_multipart()` in the workflow's origin installation, not accidentally
  against the control installation.
- **R15.** Connection growth must be bounded independently of the number of
  installed databases. Installing 100 satellites must not eagerly allocate 100
  full management pools.
- **R16.** The single worker must tolerate a rolling extension upgrade in which the
  control and satellite databases temporarily have different extension schema
  versions within the supported binary-compatibility range.

## Implementation Map

| Area | Implemented contract |
|---|---|
| [Install DDL](../src/lib.rs) | Local `df` objects everywhere; extension-owned provider namespace only in the control database. Satellite objects belong to the installer; provider objects inside the control namespace are created by `worker_role`. |
| [Origin routing](../src/origin.rs) | Database OID plus installation UUID, same-connection metadata fences, fresh admission checks, and a shared connection semaphore. |
| [Activity registry](../src/registry.rs) | Route graph admission, metadata updates, SQL defaults, and HTTP authorization using `ActivityContext`. |
| [Backend readiness](../src/types.rs) | Satellites discover the control schema and readiness over SQLx using the worker credential, without a lifetime schema cache. |
| [Worker maintenance](../src/worker.rs) | Retention and orphan reconciliation visit registered origins in bounded batches. |

## Implemented Architecture

### 1. Explicit Control Installation

The control database remains the only owner of the provider schema and the only
database whose extension lifecycle starts or stops the runtime. Administrators use:

```sql
-- In the database named by pg_durable.database:
CREATE EXTENSION pg_durable;

-- Then, in each additional database:
CREATE EXTENSION pg_durable;
```

Satellite creation verifies over SQLx that the control installation exists and its
worker readiness schema version is at least `2`, which includes the `_origins`
registry. It does not create the control extension automatically.
An automatic remote `CREATE EXTENSION` would commit independently from the local
installation transaction, so a local rollback could leave an unexpected control
installation and provider schema behind.

This explicit anchor removes the need for lifecycle reference counting. Runtime
initialization follows control creation; shutdown follows detection of control
removal, regardless of satellite count. Removal order is satellites first, control last.

The provider namespace is extension-owned (`_duroxide` on fresh control installs,
legacy `duroxide` on older upgraded installs). Objects inside it are created by
`pg_durable.worker_role` through worker-only `ApplyAll` migrations and readiness
initialization. Satellite DDL belongs to the local installer and creates neither
provider namespace nor provider objects.

### 2. Local Metadata, Shared Engine

Each satellite retains local metadata and local SPI operations. Public instance
IDs remain eight hexadecimal characters. Satellite engine IDs have this form:

```text
pgdf-<databaseOID>-<installationUUID>-<localID>
```

The UUID is stored in local `df._installation` and encoded without hyphens in the
engine ID. Database OID permits rename-safe lookup through `pg_database`; the UUID
fences work from a dropped/recreated installation. Activities parse the root ID
from `ActivityContext.instance_id()`, including for existing `::` child-ID suffixes.

No origin fields are added to recorded orchestration or activity payloads. Child
composition, `continue_as_new`, and control-database replay remain unchanged.
Control instances continue to use their unprefixed local IDs, including on older
schemas without `df._installation`.

### 3. Database-Aware Activity Routing

The activity registry uses an origin router for:

- graph load and transaction admission;
- instance and node status updates;
- HTTP and multipart privilege checks;
- retention and orphan reconciliation.

SQL execution remains separate. Its effective target is:

```text
explicit df.start(database => ...) ?? origin database
```

For SQL activities, a null execution database defaults to the origin through the
runtime route; an explicit database remains a separate SQL target.
Both paths freshly validate source database OID, installation UUID and extension
ownership after the execution-permit wait, after target connection, and immediately
before dispatch. Reconnecting to the same name does not establish source identity.
An unavailable source fails admission; it does not authorize a fallback to control.
An explicit remote SQL target still needs no pg_durable installation.

When SQL targets its own satellite, a short preflight on the **actual execution
connection** also validates the expected source OID/UUID. Its transaction commits
before business SQL; validation errors explicitly roll it back. SQL runs in
autocommit in control, default/explicit-self satellites, and remote targets.
`VACUUM` and `CREATE INDEX CONCURRENTLY` are supported wherever the submitting
role has the necessary PostgreSQL privileges. Preflight timeouts and isolation
settings are transaction-local and do not alter business SQL settings.

Graph visibility probes, graph loads, node/instance status writes, retention and
reconciliation each validate identity and access metadata in the **same short
transaction on one connection**. Locks cover the actual metadata operation.
Identity is read after any lock wait, using a fresh READ COMMITTED snapshot.
No metadata transaction spans visibility-poll sleeps, engine RPCs, user SQL, or
HTTP transfer. Ordinary PostgreSQL lock conflicts can still fail with a bounded
metadata timeout; the separate idle-guard/client-side lock cycle is removed.

HTTP and multipart privilege checks, endpoint servers and secret mappings resolve
in the trusted origin, never the SQL target or a database supplied in HTTP JSON.
After user-connection admission, the catalog transaction validates source OID/UUID.
Catalog connections close before network I/O. Source identity and the required
HTTP `EXECUTE` privilege are checked again immediately before sending, including
after catalog-slot waits. Endpoint settings and all named secrets retain their
one-attempt consistent snapshot; rotation is visible to subsequent attempts,
not a reread of half the credentials during the same request. Existing domain
policy and secret redaction remain in effect.

`pg_durable.max_origin_connections` bounds origin connections across activities and
maintenance: default `12`, minimum `2`, maximum `1000`, Postmaster context (restart
required). Each active route reserves one metadata connection slot. Routes close
their pools when finished; there is no
idle pool per database or database-name count ceiling. The control pool remains
governed by `pg_durable.max_management_connections`; SQL execution connections have
their separate existing budget.

Origin metadata connections enforce a 1.5-second lock timeout and a 5-second
statement timeout for routine metadata work (graph loading retains its own bounded
query policy). There is no idle guard transaction and no disabling of database
transaction/idle-in-transaction policies to protect long activities. These metadata
deadlines do not impose a timeout on user SQL or HTTP transfer.

### 4. Control-Plane Backend Calls

The following operations use a SQLx/Duroxide client connection to
the control database:

- start orchestration;
- cancel orchestration;
- raise signal/event;
- fetch instance/execution details;
- fetch system metrics;
- direct calls to Duroxide's published `get_instance_info` function.

Satellite readiness and provider-schema discovery also use the control connection.
Each satellite backend reuses one direct control-state connection on its cached
runtime, but rechecks extension identity, schema, and readiness on every operation.
Remote probes have 1.5-second server deadlines and a 5-second overall deadline;
failures discard the connection without falling back to stale readiness or a
satellite provider. Control-local callers use SPI so readiness changes in their
own transaction remain visible and do not require an extra control-state connection.
Instance operations authorize through local SPI/RLS before addressing engine state
under the worker credential. `df.metrics()` is the explicit administrative exception:
it reports totals for the entire shared engine, including every satellite.

`transaction_mode => 'new'` opens its loopback launch session in the caller's
database, regardless of the SQL execution target. Its advisory admission limit,
`pg_durable.max_new_transaction_starts`, is **per database**, not cluster-wide.
Caller-mode graph persistence and transaction admission remain origin-local.

### 5. Origin Registry For Maintenance, Not Ownership

The control provider schema's `_origins` table records database OID/installation UUID
pairs idempotently through activity routing for submitted work. `df.start()` does
not synchronously register the origin. Only origins submitting work are discovered,
not all installed extensions. The registry supports maintenance, not ownership or
an exact transactional reference count.

Exact cross-database reference counting is not reliable with ordinary extension
DDL: extension catalogs and dependencies are database-local, and registration over
a second connection commits or rolls back independently. There is no all-database
discovery scan or `ProcessUtility_hook`; correctness uses short identity-validated
metadata transactions and fresh side-effect admission checks. Reconciliation is
eventual cleanup, not an admission fence.

## Lifecycle And Failure Semantics

### Satellite Drop

Dropping a satellite removes its local metadata, leaving control and peer
installations intact. **pg_durable's own DROP protection covers short metadata
transactions, not arbitrary SQL/HTTP activities.** Ordinary PostgreSQL locks
held by caller transactions or user SQL can still delay DDL. This deliberately replaces
the initial multi-database patch's activity-long guards. There is no DDL hook,
automatic drain, or new administrative quiesce API.

Work whose source was removed/replaced during a semaphore, connection or catalog
wait fails its subsequent identity check before dispatch. Losing an idle metadata
connection alone is not removal: reconnect is allowed only after validating the
same source OID/UUID. Metadata writes cannot cross into a replacement installation,
even when local instance/node IDs collide.

Side-effect admission and dispatch are not one database transaction. A source can
be dropped **after the last successful check but before the remote send**, and
already-dispatched SQL/HTTP may finish after normal or forced removal. This narrow
race and active-work cancellation are not solved by identity validation. To avoid
in-flight effects, operationally stop submissions and finish the work before
uninstalling; do not treat DROP as a cancellation or quiescence acknowledgment.
Bounded reconciliation cancels running roots
after confirming removal; cancellation does not wait for the retention cutoff.
Deletion of terminal engine records remains subject to retention. Neither action
is immediate at DDL commit. Previously committed SQL or external HTTP effects
are not undone.

### Control Drop

Dropping the control extension destroys the shared engine state for **every
satellite** and causes the worker to stop the runtime when it detects the drop.
There is no cross-database dependency or registry veto. Remaining satellite metadata
does not restore the lost engine history; recreating control is not recovery of old
work. Remove satellites first and control last, after quiescing their work.
The pinned runtime's shutdown is not a joined task-tree drain; do not treat
in-process control recreation as a safe cancellation boundary.

### Database Rename Or Drop

Origin routing resolves the current database name from its OID before connecting.
Reconciliation treats a missing database OID, missing extension-owned installation
table, or replaced installation UUID as removal. An unreachable database, denied
connection, or failed probe is **not** evidence of absence: cleanup is deferred.
Explicit SQL target names remain names and are not rename-tracked by this route.

### Mixed Versions

The shared object is cluster-wide, but `pg_extension.extversion` is per database.
An older supported control schema works with the new binary without local
`df._installation`; its IDs and replay path remain unchanged. Satellites require
the new local identity/validator DDL and control worker readiness version `2`.
This readiness protocol, not equal extension version strings, gates installation.

## Security Considerations

- PostgreSQL roles and role OIDs are cluster-wide, but database `CONNECT`, schema,
  table, and function privileges are database-local.
- The default worker role is the `postgres` superuser. A custom worker role needs
  database-local `CONNECT`, access to `df` metadata and installation identity, and
  permission to perform origin-local HTTP privilege lookup in every managed origin.
  `BYPASSRLS` bypasses row policies only; it grants no database or object privileges.
- The caller must never be allowed to supply an arbitrary origin database or
  installation ID in raw workflow JSON. The C entrypoint derives origin identity
  from the current database and local installation row.
- Engine operations run under the worker credential. Every signal, cancellation,
  result lookup, and detailed monitoring operation must first prove local ownership
  through SPI/RLS in the origin database.
- An explicit SQL target database still executes as `submitted_by`, so normal
  `CONNECT` and SQL privileges remain the execution boundary.
- HTTP authorization is attached to the origin installation. Granting HTTP in
  database A must not implicitly grant it in database C.
- `df.grant_usage(..., with_grant => true)` delegates local administration and grants
  `df.metrics()` access. Even when granted in a satellite, this exposes all-engine
  aggregate totals across users and origins, not merely that satellite's activity.
- Dynamic database and schema identifiers must be resolved from trusted catalog
  values and quoted as identifiers; user input remains bound as query parameters.

## Alternatives Considered

### Eager Runtime From `shared_preload_libraries`

Rejected. Creating persistent provider objects on preload would leave them without
an explicit `CREATE EXTENSION` lifecycle owner. Uninstall and downgrade behavior would be
unclear, and removing the library from configuration cannot transactionally clean
database objects.

### Automatic Cross-Database Reference Counting

Rejected as the lifecycle foundation. A satellite's extension transaction cannot
atomically update a registry in the control database using an ordinary second
connection. Failed installs, forced drops, database removal, and restore can all
leave the count stale. Eventual registration is still useful for maintenance.

### Centralize All `df` Metadata In The Control Database

Rejected. Satellite functions could proxy every operation to the control
database, but `transaction_mode => 'caller'` could no longer naturally couple graph
persistence to the caller's local transaction. It would also require securely
forwarding caller identity for RLS and make local monitoring and grants surprising.

### One Runtime Per Installed Database

Rejected for this goal. It gives natural local semantics but multiplies Tokio
runtimes, provider pools, listeners, migrations, retention loops, and resource
budgets. It also contradicts the requirement for one Duroxide runtime and schema.

## Deferred Limitations

- Registry discovery begins with work submission, not installation. There is no
  complete cross-database installation inventory or administrative instance list.
- Satellite drop has no instant cancellation notification. Admission checks reject
  stale queued work, but do not atomically couple source DDL to a remote send or
  guarantee cancellation of admitted work.
- Local metadata, control enqueue, and explicit SQL targets do not share a
  cross-database atomic transaction. Caller-mode admission preserves local
  commit/rollback behavior, but does not provide distributed transactions.
- There is no per-node database targeting or idle SQL/metadata pool per satellite.

## Verification

The E2E coverage includes origin routing (`14_database`), isolation and installation
replacement (`75_multi_database_lifecycle`), maintenance (`76_multi_database_reconcile`),
lock ordering and metadata cleanup (`77_multi_database_guards`), forced same-target
replacement (`78_multi_database_force_drop`) and removed-source/remote-target
admission (`79_multi_database_remote_origin`). The non-echoing loopback HTTP oracle
in `80_multi_database_http_origin` covers colliding endpoint/secret catalogs,
rotation and local revocation with an extension-free SQL target.
`81_multi_database_autocommit` checks all ten route/statement combinations,
including valid concurrent indexes. `82_multi_database_ddl_cycle` verifies DDL
finishes before queued user SQL is released, without cancelling the SQL.
`83_multi_database_same_oid` replaces only the source extension while its idle
connection survives. `84_multi_database_metadata_fence` replaces the installation
after a metadata session is killed during a lock wait, then proves colliding
replacement rows remain untouched. `85_multi_database_http_admission` uses a
successful-authorization log barrier and occupied catalog permit to test
revocation, reconnect and replacement with zero disallowed network sends.
These are normal regressions, not expected-failure diagnostics. Pure
tests cover identity parsing, bounded control probes, and retention cursor progress.
The release gates remain full unit/E2E suites, formatting, build, Clippy, and upgrade
testing; focused regressions do not replace them.

## Upgrade And Migration

This feature changes local extension DDL, engine identity for satellite starts, and
runtime routing. It does not change recorded orchestration or activity payloads.

- **B1 binary compatibility:** control IDs bypass the installation-identity lookup,
  so supported old schemas without `df._installation` still work. Missing
  `df.duroxide_schema()` retains the legacy `duroxide` fallback. Control replay and
  existing child composition are unchanged by this feature.
- **Upgrade DDL:** the multi-database additions in
  [0.2.8 to 0.2.9](../sql/pg_durable--0.2.8--0.2.9.sql) are `df._installation`
  (singleton UUID, public read-only access) and `df.validate_installation()`, invoked
  by the upgrade. There is no engine-ID mapping column or provider DDL in this SQL.
  The shipped 0.2.7 to 0.2.8 migration remains unchanged.
- **Runtime schema detection:** satellites resolve control schema/readiness over
  SQLx. The worker creates `_origins` before publishing readiness version `2`;
  worker-only `ApplyAll` manages provider migrations in control, never satellites.
- **Upgrade order and gates:** deploy/restart the new binary and wait for a ready
  control installation before creating satellites. Equal extension schema versions
  are not required. Scenario A must compare like-for-like control installs; B1
  covers all supported old control schemas, and B2 checks retained data and work.
  Fresh satellites must have local identity and no provider schema. These remain
  validation requirements, not assertions that full gates have passed.

<a id="release-blockers"></a>

## Deferred Lifetime Guarantees

The autocommit, short metadata transaction and pre-dispatch source-fencing changes
do not solve the preexisting runtime/task and server-side cancellation problems.
These remain separate review/release considerations, not claims of this feature.

| Gate | Required behavior |
|------|-------------------|
| Admitted source loss | Owned cancellation/cleanup during active work is separate from refusing stale admission. The final check-to-send interval is not atomic with source DROP. |
| Runtime ownership | Close admission, cancel and join every dispatcher descendant/manager/handler on both zero and positive-timeout shutdown. Old acknowledgments must not touch replacement state. |
| Sent SQL | Verify target-backend cancellation and quiescence separately from Rust task abortion before replacing an epoch. Already committed SQL cannot be undone. |
| Sent HTTP | Prevent pre-send work after shutdown; accepted requests may still complete remotely and require application idempotency. |
| Churn/scale | Repeated replacement epochs must not accumulate tasks/connections/permits or double execution limits. Exercise more origins than connection slots with unavailable peers. |

The pinned Duroxide 0.1.30 `Runtime::shutdown` retains only outer dispatcher
handles. A barrier-based live-Tokio reproduction allows a held handler to emit
an in-process notification after shutdown returns for both `Some(0)` and a
positive timeout. This proves detached handler lifetime, not SQL/HTTP effects.
An upstream change should track the complete task tree, signal shutdown on every
path, prevent new dispatch/acknowledgment after the shutdown boundary, and abort
and join remaining children before returning. The regression must hold a handler,
await shutdown, then release the handler barrier and assert no post-stop
notification, live descendant or acknowledgment. A provider-only bump is not
a runtime task-ownership fix.

Separately, pg_durable needs owned SQL cancellation/termination and confirmed
backend drain before it can promise server-side quiescence. Dropping a Rust
future or releasing its permit is not proof that PostgreSQL stopped executing.
A future administrative quiesce/resume API would additionally need persistent
closed-admission state, restart semantics, permissions and a queued-work policy.
None is introduced here. An upstream task-tree fix alone cannot provide these
PostgreSQL-side guarantees, and local SQL cleanup alone cannot join orphaned
Duroxide dispatchers or prevent their late acknowledgments.