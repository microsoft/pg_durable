# Duroxide Provider Trait Split — Design Document

**Status:** Draft  
**Created:** 2026-03-05  
**Scope:** Changes to `duroxide` crate + `pg_durable` extension  
**Goal:** Enable building a native pg_durable provider that eliminates the `duroxide-pg-opt` dependency

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current Architecture](#2-current-architecture)
3. [Proposed Architecture](#3-proposed-architecture)
4. [Duroxide Changes](#4-duroxide-changes)
5. [pg_durable Changes](#5-pg_durable-changes)
6. [Migration Path](#6-migration-path)
7. [Open Questions](#7-open-questions)
8. [Appendix: Current Call Traces](#appendix-current-call-traces)

---

## 1. Problem Statement

pg_durable is a PostgreSQL extension that runs **inside** the database server. It has two
execution contexts:

| Context | What | Thread model |
|---------|------|-------------|
| **Backend processes** | User SQL sessions calling `df.start()`, `df.status()`, etc. | Single-threaded per process, synchronous |
| **Background worker** (BGW) | Runs the Duroxide runtime's dispatch loops | Single OS thread running tokio `current_thread` |

Today, **both** contexts depend on `duroxide-pg-opt` (an external crate implementing the
Duroxide `Provider` trait via sqlx TCP connections) and require a tokio async runtime.

This creates several problems for backend processes:

| Problem | Impact |
|---------|--------|
| TCP loopback to self | Each backend opens TCP connections back to the same PG instance it's running inside |
| Tokio runtime per session | A `tokio::Runtime` is created (and cached) in every backend that calls `df.start()` |
| Connection pool per session | An sqlx `PgPool` is created inside `PostgresProvider` for each backend |
| Authentication overhead | TCP connections require pg_hba authentication — the extension authenticates to itself |
| Dependency weight | `duroxide-pg-opt`, `sqlx`, `tokio` all linked into the extension, used from backend code |

**All of this is unnecessary.** Backend operations are simple, synchronous, request-response
calls: "insert a row into the orchestrator queue" or "read a status column." PostgreSQL's
SPI (Server Programming Interface) can do these directly, in-process, with zero network
overhead.

The blocker is that Duroxide's `Provider` trait is:
```rust
#[async_trait]
pub trait Provider: Any + Send + Sync { ... }
```

This trait **cannot be implemented** using SPI because:
- `Send + Sync` — SPI handles are `!Send + !Sync` (tied to the backend's single thread)
- `async` — SPI is synchronous; there's no future to poll
- Shared via `Arc<dyn Provider>` — designed for concurrent access from multiple tokio tasks

### What We Want

A way for pg_durable backends to call duroxide client operations (start, cancel, signal,
status, metrics) **synchronously, on the backend thread, without tokio or network I/O**,
while the background worker continues using the full async `Provider` for its dispatch loops.

---

## 2. Current Architecture

### 2.1 Call Flow: `df.start()`

```
User SQL: SELECT df.start(df.sql('SELECT 1'), 'my-instance')

  pg_durable backend process:
    dsl.rs::start()
      → client.rs::start_durable_function()
        → get_client_runtime()          ← OnceLock<tokio::Runtime>
        → get_duroxide_client()         ← OnceLock<duroxide::Client>
            → PostgresProvider::new()   ← creates sqlx PgPool (TCP!)
            → Client::new(Arc::new(provider))
        → rt.block_on(async {
            client.start_orchestration(instance_id, fn_name, input).await
              → store.enqueue_for_orchestrator(WorkItem::StartOrchestration{..}, None).await
                → sqlx::query("SELECT duroxide.enqueue_orchestrator_work($1,$2,$3,$4,$5,$6,$7)")
                    .execute(&pool).await     ← TCP round-trip to self!
          })
```

### 2.2 Call Flow: `df.list_instances()`

```
User SQL: SELECT * FROM df.list_instances()

  pg_durable backend process:
    monitoring.rs::list_instances()
      → tokio::runtime::Builder::new_current_thread().build()   ← NEW runtime every call!
      → rt.block_on(async {
          PostgresProvider::new()                                ← NEW pool every call!
          Client::new(Arc::new(provider))
          client.list_all_instances().await
            → provider.as_management_capability()
              → ProviderAdmin::list_instances().await
                → sqlx::query("SELECT duroxide.list_instances()").fetch_all(&pool).await
        })
```

### 2.3 Call Flow: Background Worker

```
BGW process (src/worker.rs):
  duroxide_worker_main()
    → tokio::runtime::Builder::new_current_thread().build()   ← single long-lived runtime
    → rt.block_on(run_duroxide_runtime())
      → PostgresProvider::new()                               ← single long-lived pool
      → Runtime::start_with_store(Arc::new(provider), activities, orchestrations)
        → spawns orchestration dispatcher  ← calls provider.fetch_orchestration_item() in loop
        → spawns worker dispatcher         ← calls provider.fetch_work_item() in loop
        → spawns lock renewal tasks        ← calls provider.renew_*_lock() concurrently
        → spawns session manager           ← calls provider.renew_session_lock() periodically
```

### 2.4 Provider Methods by Consumer

| Provider Method | Backend? | BGW? | Notes |
|----------------|----------|------|-------|
| `enqueue_for_orchestrator` | ✅ | ✅ (via ack) | Client ops + runtime re-enqueue |
| `read` | ✅ | ✅ | Status queries + replay |
| `get_custom_status` | ✅ | — | Status polling |
| `ProviderAdmin::*` | ✅ | — | Monitoring/metrics |
| `fetch_orchestration_item` | — | ✅ | Peek-lock dispatch |
| `ack_orchestration_item` | — | ✅ | Atomic commit |
| `abandon_orchestration_item` | — | ✅ | Error recovery |
| `fetch_work_item` | — | ✅ | Activity dispatch |
| `ack_work_item` | — | ✅ | Activity completion |
| `abandon_work_item` | — | ✅ | Activity error |
| `enqueue_for_worker` | — | ✅ | Schedule activities |
| `renew_*_lock` | — | ✅ | Lock extension |
| `renew_session_lock` | — | ✅ | Session affinity |
| `cleanup_orphaned_sessions` | — | ✅ | Session cleanup |
| `read_with_execution` | — | ✅ | Testing only |
| `append_with_execution` | — | ✅ | Testing only |

The split is clean: **backends only need 4 capabilities** (enqueue, read, custom_status,
admin queries). Everything else is runtime-only.

---

## 3. Proposed Architecture

### 3.1 Two Traits, Two Clients

```
                          duroxide crate
                    ┌────────────────────────┐
                    │                        │
    Sync path:      │  ProviderClient        │  trait (sync, no Send/Sync)
                    │    enqueue_for_orch()   │
                    │    read()              │
                    │    get_custom_status()  │
                    │    as_mgmt_capability() │
                    │                        │
                    │  SyncClient<P>          │  struct (uses ProviderClient)
                    │    start_orchestration()│
                    │    cancel_instance()    │
                    │    raise_event()        │
                    │    get_orch_status()    │
                    │    list_instances()     │  (via ProviderClientAdmin)
                    │    get_instance_info()  │
                    │    get_system_metrics() │
                    │                        │
    Async path:     │  Provider              │  trait (async, Send+Sync) — unchanged
                    │    (all current methods)│
                    │                        │
                    │  Client                 │  struct (uses Provider) — unchanged
                    │    (all current methods)│
                    └────────────────────────┘

                          pg_durable crate
                    ┌────────────────────────┐
                    │                        │
    Backend:        │  SpiProvider            │  implements ProviderClient
                    │    SPI calls to         │  (sync, !Send, !Sync)
                    │    duroxide.* stored    │
                    │    procedures           │
                    │                        │
    BGW:            │  PgNativeProvider       │  implements Provider
                    │    sqlx calls to        │  (async, Send+Sync)
                    │    duroxide.* stored    │
                    │    procedures           │
                    │                        │
                    │  NO duroxide-pg-opt     │
                    └────────────────────────┘
```

### 3.2 Backend Call Flow (After)

```
User SQL: SELECT df.start(df.sql('SELECT 1'), 'my-instance')

  pg_durable backend process:
    dsl.rs::start()
      → client.rs::start_durable_function()
        → SpiProvider::new()              ← zero-cost, no connections
        → SyncClient::new(&mut provider)
        → client.start_orchestration(instance_id, fn_name, input)
          → provider.enqueue_for_orchestrator(WorkItem::StartOrchestration{..}, None)
            → Spi::connect(|spi| {
                spi.select("SELECT duroxide.enqueue_orchestrator_work($1,$2,$3,$4,$5,$6,$7)", ...)
              })                          ← in-process, zero network, sub-millisecond
```

No tokio. No TCP. No connection pool. No `Send + Sync`. Just a direct function call
to a stored procedure that's already loaded in the same process.

### 3.3 BGW Call Flow (After)

```
BGW process (src/worker.rs):
  duroxide_worker_main()
    → tokio::runtime::Builder::new_current_thread().build()
    → rt.block_on(run_duroxide_runtime())
      → PgNativeProvider::new(&pg_conn_str)      ← sqlx pool (UDS preferred)
      → Runtime::start_with_store(Arc::new(provider), activities, orchestrations)
        → (same as today, but pg_durable owns the Provider impl)
```

The BGW path stays async, but pg_durable implements `Provider` directly against the
duroxide stored procedures instead of depending on `duroxide-pg-opt`. The stored
procedures are already shipped as part of pg_durable's extension SQL
(`sql/duroxide_install.sql`), so the Provider just needs to call them with sqlx.

---

## 4. Duroxide Changes

### 4.1 New File: `src/providers/client_provider.rs`

Two new traits:

```rust
/// Synchronous provider for client control-plane operations.
/// No Send, no Sync, no async — just plain method calls.
pub trait ProviderClient {
    // === Required ===

    /// Enqueue a WorkItem to the orchestrator queue.
    /// Used for start, cancel, signal, enqueue_event.
    fn enqueue_for_orchestrator(
        &mut self,
        item: WorkItem,
        delay: Option<Duration>,
    ) -> Result<(), ProviderError>;

    /// Read latest execution history for status queries.
    fn read(&self, instance: &str) -> Result<Vec<Event>, ProviderError>;

    // === Optional (defaults provided) ===

    /// Lightweight custom status polling.
    fn get_custom_status(
        &self, _instance: &str, _last_seen_version: u64,
    ) -> Result<Option<(Option<String>, u64)>, ProviderError> { Ok(None) }

    /// Management capability discovery.
    fn as_management_capability(&self) -> Option<&dyn ProviderClientAdmin> { None }

    fn name(&self) -> &str { "unknown" }
    fn version(&self) -> &str { "0.0.0" }
}

/// Synchronous admin/management queries.
pub trait ProviderClientAdmin {
    fn list_instances(&self) -> Result<Vec<String>, ProviderError>;
    fn list_instances_by_status(&self, status: &str) -> Result<Vec<String>, ProviderError>;
    fn get_instance_info(&self, instance: &str) -> Result<InstanceInfo, ProviderError>;
    fn get_execution_info(&self, instance: &str, exec_id: u64) -> Result<ExecutionInfo, ProviderError>;
    fn get_system_metrics(&self) -> Result<SystemMetrics, ProviderError>;
    fn get_queue_depths(&self) -> Result<QueueDepths, ProviderError>;
    fn list_executions(&self, instance: &str) -> Result<Vec<u64>, ProviderError>;
    // ... (mirrors ProviderAdmin)
}
```

### 4.2 New File: `src/client/sync_client.rs`

A synchronous client that mirrors the async `Client`'s control-plane API:

```rust
/// Synchronous client for duroxide operations.
///
/// Unlike `Client` (which requires `Arc<dyn Provider>` and an async runtime),
/// `SyncClient` takes `&mut impl ProviderClient` and calls methods directly.
pub struct SyncClient<'a, P: ProviderClient> {
    provider: &'a mut P,
}

impl<'a, P: ProviderClient> SyncClient<'a, P> {
    pub fn new(provider: &'a mut P) -> Self {
        Self { provider }
    }

    pub fn start_orchestration(
        &mut self,
        instance: impl Into<String>,
        orchestration: impl Into<String>,
        input: impl Into<String>,
    ) -> Result<(), ClientError> {
        let item = WorkItem::StartOrchestration {
            instance: instance.into(),
            orchestration: orchestration.into(),
            input: input.into(),
            version: None,
            parent_instance: None,
            parent_id: None,
            execution_id: crate::INITIAL_EXECUTION_ID,
        };
        self.provider
            .enqueue_for_orchestrator(item, None)
            .map_err(ClientError::from)
    }

    pub fn cancel_instance(
        &mut self,
        instance: impl Into<String>,
        reason: impl Into<String>,
    ) -> Result<(), ClientError> {
        let item = WorkItem::CancelInstance {
            instance: instance.into(),
            reason: reason.into(),
        };
        self.provider
            .enqueue_for_orchestrator(item, None)
            .map_err(ClientError::from)
    }

    pub fn raise_event(
        &mut self,
        instance: impl Into<String>,
        event_name: impl Into<String>,
        data: impl Into<String>,
    ) -> Result<(), ClientError> {
        let item = WorkItem::ExternalRaised {
            instance: instance.into(),
            name: event_name.into(),
            data: data.into(),
        };
        self.provider
            .enqueue_for_orchestrator(item, None)
            .map_err(ClientError::from)
    }

    pub fn enqueue_event(
        &mut self,
        instance: impl Into<String>,
        queue: impl Into<String>,
        data: impl Into<String>,
    ) -> Result<(), ClientError> {
        let item = WorkItem::QueueMessage {
            instance: instance.into(),
            name: queue.into(),
            data: data.into(),
        };
        self.provider
            .enqueue_for_orchestrator(item, None)
            .map_err(ClientError::from)
    }

    /// Get orchestration status by reading history.
    ///
    /// Logic mirrors `Client::get_orchestration_status()` exactly:
    /// reads history, scans for terminal events, returns status.
    pub fn get_orchestration_status(
        &self,
        instance: &str,
    ) -> Result<OrchestrationStatus, ClientError> {
        let hist = self.provider.read(instance).map_err(ClientError::from)?;

        let (custom_status, custom_status_version) =
            match self.provider.get_custom_status(instance, 0) {
                Ok(Some((cs, v))) => (cs, v),
                _ => (None, 0),
            };

        // Scan for terminal events (same logic as async Client)
        for e in hist.iter().rev() {
            match &e.kind {
                EventKind::OrchestrationCompleted { output } => {
                    return Ok(OrchestrationStatus::Completed {
                        output: output.clone(),
                        custom_status,
                        custom_status_version,
                    });
                }
                EventKind::OrchestrationFailed { details } => {
                    return Ok(OrchestrationStatus::Failed {
                        details: details.clone(),
                        custom_status,
                        custom_status_version,
                    });
                }
                _ => {}
            }
        }

        if hist.is_empty() {
            Ok(OrchestrationStatus::NotFound)
        } else {
            Ok(OrchestrationStatus::Running {
                custom_status,
                custom_status_version,
            })
        }
    }

    // Management operations (delegate to ProviderClientAdmin)

    pub fn list_all_instances(&self) -> Result<Vec<String>, ClientError> { ... }
    pub fn get_instance_info(&self, instance: &str) -> Result<InstanceInfo, ClientError> { ... }
    pub fn get_system_metrics(&self) -> Result<SystemMetrics, ClientError> { ... }
    // ... etc
}
```

### 4.3 Module Registration

```rust
// src/providers/mod.rs — add:
pub mod client_provider;
pub use client_provider::{ProviderClient, ProviderClientAdmin};

// src/client/mod.rs — add:
pub mod sync_client;
pub use sync_client::SyncClient;

// src/lib.rs — add re-exports:
pub use client::SyncClient;
pub use providers::{ProviderClient, ProviderClientAdmin};
```

### 4.4 Blanket Implementation (Optional)

Any async `Provider` can automatically be used as a `ProviderClient` if you have
a tokio runtime available. This enables testing and gradual migration:

```rust
// This is NOT a blanket impl (would conflict). Instead, it's a wrapper:
pub struct BlockingProviderClient<'a> {
    provider: &'a dyn Provider,
    runtime: &'a tokio::runtime::Runtime,
}

impl ProviderClient for BlockingProviderClient<'_> {
    fn enqueue_for_orchestrator(&mut self, item: WorkItem, delay: Option<Duration>)
        -> Result<(), ProviderError>
    {
        self.runtime.block_on(self.provider.enqueue_for_orchestrator(item, delay))
    }

    fn read(&self, instance: &str) -> Result<Vec<Event>, ProviderError> {
        self.runtime.block_on(self.provider.read(instance))
    }
    // ...
}
```

This wrapper would live behind a feature flag (e.g., `tokio-compat`) since it pulls
in a tokio dependency. It's useful for testing `SyncClient` against the existing
SQLite provider.

### 4.5 Changes Summary

| What | Type | Breaking? |
|------|------|-----------|
| `ProviderClient` trait | New | No |
| `ProviderClientAdmin` trait | New | No |
| `SyncClient` struct | New | No |
| `BlockingProviderClient` wrapper | New, feature-gated | No |
| Existing `Provider` trait | Unchanged | No |
| Existing `Client` struct | Unchanged | No |

**Zero breaking changes to duroxide's public API.** This is purely additive.

---

## 5. pg_durable Changes

### 5.1 New: `SpiProvider` (for Backend Processes)

Implements `ProviderClient` + `ProviderClientAdmin` using pgrx SPI:

```rust
// src/spi_provider.rs

use duroxide::providers::{ProviderClient, ProviderClientAdmin, ProviderError, WorkItem};
use duroxide::Event;
use pgrx::prelude::*;
use std::time::Duration;

/// Native PostgreSQL provider using SPI for synchronous in-process access.
///
/// This provider calls the duroxide stored procedures directly via SPI,
/// with zero network overhead. It is !Send + !Sync by design.
pub struct SpiProvider;

impl SpiProvider {
    pub fn new() -> Self {
        Self
    }
}

impl ProviderClient for SpiProvider {
    fn enqueue_for_orchestrator(
        &mut self,
        item: WorkItem,
        delay: Option<Duration>,
    ) -> Result<(), ProviderError> {
        let work_item_json = serde_json::to_string(&item)
            .map_err(|e| ProviderError::permanent("enqueue", format!("serialize: {e}")))?;

        let instance_id = extract_instance_id(&item)?;
        let now_ms = current_time_ms();
        let visible_at = compute_visible_at(&item, delay, now_ms);

        Spi::connect(|client| {
            client.select(
                "SELECT duroxide.enqueue_orchestrator_work($1, $2, $3, $4, $5, $6, $7)",
                None,
                vec![
                    (PgBuiltInOids::TEXTOID.oid(), instance_id.into_datum()),
                    (PgBuiltInOids::TEXTOID.oid(), work_item_json.into_datum()),
                    (PgBuiltInOids::TIMESTAMPTZOID.oid(), visible_at.into_datum()),
                    (PgBuiltInOids::INT8OID.oid(), (now_ms as i64).into_datum()),
                    (PgBuiltInOids::TEXTOID.oid(), None::<String>.into_datum()),  // orch_name
                    (PgBuiltInOids::TEXTOID.oid(), None::<String>.into_datum()),  // orch_version
                    (PgBuiltInOids::INT8OID.oid(), None::<i64>.into_datum()),     // execution_id
                ],
            )
            .map_err(|e| ProviderError::permanent("enqueue", format!("SPI: {e:?}")))?;
            Ok(())
        })
    }

    fn read(&self, instance: &str) -> Result<Vec<Event>, ProviderError> {
        Spi::connect(|client| {
            let rows = client.select(
                "SELECT event_data FROM duroxide.history h
                 JOIN duroxide.instances i ON h.instance_id = i.instance_id
                    AND h.execution_id = i.current_execution_id
                 WHERE h.instance_id = $1
                 ORDER BY h.event_id",
                None,
                vec![(PgBuiltInOids::TEXTOID.oid(), instance.into_datum())],
            ).map_err(|e| ProviderError::permanent("read", format!("SPI: {e:?}")))?;

            let mut events = Vec::new();
            for row in rows {
                if let Some(json) = row.get::<String>(1) {
                    let event: Event = serde_json::from_str(&json)
                        .map_err(|e| ProviderError::permanent("read", format!("deserialize: {e}")))?;
                    events.push(event);
                }
            }
            Ok(events)
        })
    }

    fn get_custom_status(
        &self,
        instance: &str,
        _last_seen_version: u64,
    ) -> Result<Option<(Option<String>, u64)>, ProviderError> {
        Spi::connect(|client| {
            let result = client.select(
                "SELECT custom_status, custom_status_version FROM duroxide.instances WHERE instance_id = $1",
                None,
                vec![(PgBuiltInOids::TEXTOID.oid(), instance.into_datum())],
            ).map_err(|e| ProviderError::permanent("get_custom_status", format!("SPI: {e:?}")))?;

            if let Some(row) = result.first() {
                let status = row.get::<String>(1);
                let version = row.get::<i64>(2).unwrap_or(0) as u64;
                Ok(Some((status, version)))
            } else {
                Ok(None)
            }
        })
    }

    fn as_management_capability(&self) -> Option<&dyn ProviderClientAdmin> {
        Some(self as &dyn ProviderClientAdmin)
    }

    fn name(&self) -> &str { "pg_durable::spi" }
    fn version(&self) -> &str { env!("CARGO_PKG_VERSION") }
}

impl ProviderClientAdmin for SpiProvider {
    fn list_instances(&self) -> Result<Vec<String>, ProviderError> {
        Spi::connect(|client| {
            let rows = client.select("SELECT * FROM duroxide.list_instances()", None, vec![])
                .map_err(|e| ProviderError::permanent("list_instances", format!("{e:?}")))?;
            Ok(rows.map(|r| r.get::<String>(1).unwrap_or_default()).collect())
        })
    }

    fn get_system_metrics(&self) -> Result<SystemMetrics, ProviderError> {
        Spi::connect(|client| {
            let row = client.select("SELECT * FROM duroxide.get_system_metrics()", None, vec![])
                .map_err(|e| ProviderError::permanent("metrics", format!("{e:?}")))?;
            // Parse into SystemMetrics...
            todo!()
        })
    }

    // ... other admin methods follow same SPI pattern
}
```

### 5.2 New: `PgNativeProvider` (for Background Worker)

Implements the full async `Provider` trait using sqlx, replacing `duroxide-pg-opt`:

```rust
// src/pg_provider.rs

use duroxide::providers::*;
use sqlx::PgPool;
use std::sync::Arc;

/// Native async Provider for the pg_durable background worker.
///
/// Calls the same duroxide.* stored procedures that duroxide-pg-opt uses,
/// but owned by pg_durable. This eliminates the external dependency.
pub struct PgNativeProvider {
    pool: Arc<PgPool>,
    schema: String,
}

impl PgNativeProvider {
    pub async fn new(connection_string: &str) -> Result<Self, ProviderError> {
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(5)
            .connect(connection_string)
            .await
            .map_err(|e| ProviderError::permanent("connect", format!("{e}")))?;

        Ok(Self {
            pool: Arc::new(pool),
            schema: "duroxide".to_string(),
        })
    }
}

#[async_trait::async_trait]
impl Provider for PgNativeProvider {
    async fn enqueue_for_orchestrator(
        &self,
        item: WorkItem,
        delay: Option<Duration>,
    ) -> Result<(), ProviderError> {
        // Same logic as SpiProvider but using sqlx
        let work_item_json = serde_json::to_string(&item)...;
        let instance_id = extract_instance_id(&item)?;
        sqlx::query(&format!(
            "SELECT {}.enqueue_orchestrator_work($1,$2,$3,$4,$5,$6,$7)",
            self.schema
        ))
        .bind(instance_id)
        .bind(&work_item_json)
        // ... same parameters
        .execute(&*self.pool)
        .await
        .map_err(|e| ProviderError::transient("enqueue", format!("{e}")))?;
        Ok(())
    }

    async fn fetch_orchestration_item(
        &self,
        lock_timeout: Duration,
        poll_timeout: Duration,
        filter: Option<&DispatcherCapabilityFilter>,
    ) -> Result<Option<(OrchestrationItem, String, u32)>, ProviderError> {
        // Call duroxide.fetch_orchestration_item() stored procedure
        // Parse result into OrchestrationItem
        // This is the most complex method (~200 lines in duroxide-pg-opt)
        todo!()
    }

    async fn ack_orchestration_item(
        &self,
        lock_token: &str,
        execution_id: u64,
        history_delta: Vec<Event>,
        worker_items: Vec<WorkItem>,
        orchestrator_items: Vec<WorkItem>,
        metadata: ExecutionMetadata,
        cancelled_activities: Vec<ScheduledActivityIdentifier>,
    ) -> Result<(), ProviderError> {
        // Call duroxide.ack_orchestration_item() stored procedure
        // This is an atomic multi-step operation
        todo!()
    }

    // ... ~15 more methods, each calling a stored procedure
}
```

### 5.3 Updated: `src/client.rs` (Simplified)

```rust
// BEFORE: 97 lines with OnceLock<Runtime>, OnceLock<Client>, PostgresProvider, tokio
// AFTER: ~30 lines, no async, no tokio, no connection pool

use duroxide::SyncClient;
use crate::spi_provider::SpiProvider;

pub fn start_durable_function(
    function_name: &str,
    instance_id: &str,
    input: &str,
) -> Result<(), String> {
    let mut provider = SpiProvider::new();
    let mut client = SyncClient::new(&mut provider);
    client
        .start_orchestration(instance_id, function_name, input)
        .map_err(|e| format!("Failed to start: {e:?}"))
}

pub fn cancel_durable_function(instance_id: &str, reason: &str) -> Result<(), String> {
    let mut provider = SpiProvider::new();
    let mut client = SyncClient::new(&mut provider);
    client
        .cancel_instance(instance_id, reason)
        .map_err(|e| format!("Failed to cancel: {e:?}"))
}

pub fn raise_external_event(instance_id: &str, event_name: &str, data: &str) -> Result<(), String> {
    let mut provider = SpiProvider::new();
    let mut client = SyncClient::new(&mut provider);
    client
        .raise_event(instance_id, event_name, data)
        .map_err(|e| format!("Failed to raise event: {e:?}"))
}
```

### 5.4 Updated: `src/monitoring.rs` (Simplified)

```rust
// BEFORE: Creates NEW tokio runtime + NEW PostgresProvider for EVERY call
// AFTER: Direct SPI, zero overhead

use duroxide::SyncClient;
use crate::spi_provider::SpiProvider;

#[pg_extern(schema = "df")]
pub fn list_instances(...) -> TableIterator<...> {
    let provider = SpiProvider::new();
    let admin = provider.as_management_capability().unwrap();
    let instances = admin.list_instances()
        .map_err(|e| error!("Failed: {e:?}")).unwrap();
    // ... convert to TableIterator
}
```

### 5.5 Updated: `src/worker.rs`

```rust
// BEFORE: PostgresProvider::new_with_config(...)
// AFTER: PgNativeProvider::new(...)

use crate::pg_provider::PgNativeProvider;

async fn initialize_duroxide_runtime(...) -> Option<Arc<runtime::Runtime>> {
    let store = Arc::new(
        PgNativeProvider::new(pg_conn_str)
            .await
            .map_err(|e| log!("Failed to create provider: {e}"))
            .ok()?
    );
    // ... rest unchanged
    let duroxide_runtime = runtime::Runtime::start_with_store(store, activities, orchestrations).await;
    Some(duroxide_runtime)
}
```

### 5.6 Updated: `Cargo.toml`

```toml
# REMOVED:
# duroxide-pg-opt = { git = "...", branch = "...", package = "duroxide-pg-opt" }

# KEPT (still needed for BGW + activities):
duroxide = "=0.1.20"
tokio = { version = "1", features = ["rt", "sync", "time"] }  # only needed for BGW
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "json"] }  # only for BGW + activities
```

### 5.7 Impact Summary

| Component | Before | After |
|-----------|--------|-------|
| `client.rs` | tokio + sqlx + duroxide-pg-opt | SPI only |
| `monitoring.rs` | tokio + sqlx + duroxide-pg-opt (per call!) | SPI only |
| `explain.rs` | tokio + sqlx + duroxide-pg-opt | SPI only |
| `worker.rs` | duroxide-pg-opt | PgNativeProvider (sqlx) |
| `Cargo.toml` | depends on duroxide-pg-opt | no duroxide-pg-opt |
| Backend memory | tokio Runtime + sqlx Pool per session | zero additional |
| Backend latency | TCP round-trip (~1-5ms) | SPI (~0.01ms) |

---

## 6. Migration Path

### Phase 1: Duroxide Changes (non-breaking, additive)

1. Add `ProviderClient` trait (`src/providers/client_provider.rs`)
2. Add `ProviderClientAdmin` trait (same file)
3. Add `SyncClient` struct (`src/client/sync_client.rs`)
4. Add `BlockingProviderClient` wrapper (behind `tokio-compat` feature)
5. Register in `mod.rs` / `lib.rs`, add re-exports
6. Add unit tests using `BlockingProviderClient` + SQLite provider
7. **Ship as part of next duroxide release** (fully backward-compatible)

### Phase 2: pg_durable — Backend SPI Provider

1. Add `src/spi_provider.rs` implementing `ProviderClient` + `ProviderClientAdmin`
2. Rewrite `src/client.rs` to use `SyncClient<SpiProvider>`
3. Rewrite `src/monitoring.rs` to use `SpiProvider` directly
4. Update `src/explain.rs` to use `SpiProvider`
5. Remove `backend_provider_config()` from `types.rs`
6. Run E2E tests — backends no longer touch tokio or sqlx

### Phase 3: pg_durable — BGW Native Provider

1. Add `src/pg_provider.rs` implementing full `Provider` trait
2. Port methods from `duroxide-pg-opt/src/provider.rs` (~2200 lines)
   - Stored procedures do the heavy lifting; provider methods are ~50-100 lines each
   - Most complex: `fetch_orchestration_item` and `ack_orchestration_item`
3. Update `src/worker.rs` to use `PgNativeProvider`
4. Remove `duroxide-pg-opt` from `Cargo.toml`
5. Remove `worker_provider_config()` from `types.rs`
6. Run full E2E test suite

### Phase 3 Alternative: Keep duroxide-pg-opt for BGW

If Phase 3 is too much effort initially, the BGW can continue using `duroxide-pg-opt`.
Phase 2 alone delivers 90% of the value (eliminating tokio/sqlx from all backend processes).
Phase 3 can be done later if/when `duroxide-pg-opt` maintenance becomes a burden.

**Recommended approach:** Do Phase 1 + Phase 2 first. Evaluate Phase 3 based on
maintenance experience with duroxide-pg-opt.

---

## 7. Open Questions

### 7.1 For Duroxide Authors

1. **Trait naming:** Is `ProviderClient` the right name? Alternatives: `SyncProvider`,
   `ClientProvider`, `ProviderControlPlane`. The name should convey "sync subset of Provider
   for client operations."

2. **`&mut self` vs `&self`:** The POC uses `&mut self` for `enqueue_for_orchestrator` since
   SPI handles aren't reentrant. But `&self` would allow sharing a provider reference for
   read operations. Should `read()` and `get_custom_status()` take `&self` while
   `enqueue_for_orchestrator` takes `&mut self`? (Current design: `&mut self` for writes,
   `&self` for reads.)

3. **Should `Provider` extend `ProviderClient`?** If so, any async `Provider` automatically
   satisfies `ProviderClient` (with an auto-generated blocking wrapper). This would
   formalize the "superset" relationship. However, it means `Provider` would need both
   sync and async versions of `enqueue_for_orchestrator`, which is awkward.

4. **Feature gating:** Should `ProviderClient` and `SyncClient` be behind a feature flag
   (e.g., `sync-client`) or always available? Since they add no dependencies, "always
   available" seems simplest.

5. **Where does `extract_instance_id` live?** Both `SpiProvider` and `PgNativeProvider`
   need to extract instance_id from a `WorkItem`. This logic exists in `duroxide-pg-opt`
   today. Should duroxide provide a `WorkItem::instance_id()` method? (Currently the match
   is repeated in every provider.)

### 7.2 For pg_durable

1. **SPI vs direct table access:** SPI calls stored procedures, which is clean and
   matches what `duroxide-pg-opt` does. But for simple reads (e.g., status), a direct
   `SELECT` might be simpler. Should `SpiProvider` mix stored procedure calls and direct
   queries?

2. **Error mapping:** SPI errors are different from sqlx errors. Both map to `ProviderError`,
   but the error messages will differ. Is this acceptable?

3. **Phase 3 effort:** Porting `duroxide-pg-opt` is ~2200 lines. How much is mechanical
   (change sqlx query syntax to use schema-qualified names) vs requiring understanding of
   complex semantics (lock management, long-polling, notifications)?

4. **UDS for BGW:** Regardless of native provider, the BGW should prefer Unix Domain Sockets
   over TCP loopback. This is an orthogonal optimization that can be done immediately.

---

## Appendix: Current Call Traces

### A.1 What `Client::start_orchestration()` Actually Does

```rust
// duroxide/src/client/mod.rs
pub async fn start_orchestration(&self, instance, orchestration, input) -> Result<(), ClientError> {
    let item = WorkItem::StartOrchestration {
        instance: instance.into(),
        orchestration: orchestration.into(),
        input: input.into(),
        version: None,
        parent_instance: None,
        parent_id: None,
        execution_id: INITIAL_EXECUTION_ID,  // = 1
    };
    self.store.enqueue_for_orchestrator(item, None).await?;
    Ok(())
}
```

It constructs a `WorkItem::StartOrchestration` and calls `enqueue_for_orchestrator`.
That's it. The same pattern applies to `cancel_instance` (`WorkItem::CancelInstance`),
`raise_event` (`WorkItem::ExternalRaised`), and `enqueue_event` (`WorkItem::QueueMessage`).

### A.2 What `enqueue_for_orchestrator()` Does in duroxide-pg-opt

```rust
// duroxide-pg-opt/src/provider.rs
async fn enqueue_for_orchestrator(&self, item: WorkItem, delay: Option<Duration>) -> Result<(), ProviderError> {
    let work_item_json = serde_json::to_string(&item)?;
    let instance_id = extract_instance_id(&item);
    let visible_at = compute_visible_at(&item, delay);

    sqlx::query("SELECT duroxide.enqueue_orchestrator_work($1,$2,$3,$4,$5,$6,$7)")
        .bind(instance_id)
        .bind(&work_item_json)
        .bind(visible_at)          // TIMESTAMPTZ
        .bind(now_ms)              // BIGINT
        .bind::<Option<String>>(None)  // orchestration_name (NULL — not set on enqueue)
        .bind::<Option<String>>(None)  // orchestration_version (NULL)
        .bind::<Option<i64>>(None)     // execution_id (NULL)
        .execute(&*self.pool)
        .await?;
    Ok(())
}
```

This is a single stored procedure call. The SPI equivalent is trivial.

### A.3 What `Client::get_orchestration_status()` Does

```rust
// duroxide/src/client/mod.rs
pub async fn get_orchestration_status(&self, instance: &str) -> Result<OrchestrationStatus, ClientError> {
    let hist = self.store.read(instance).await?;
    let (custom_status, custom_status_version) = self.store.get_custom_status(instance, 0).await...;

    for e in hist.iter().rev() {
        match &e.kind {
            EventKind::OrchestrationCompleted { output } => return Ok(Completed { ... }),
            EventKind::OrchestrationFailed { details } => return Ok(Failed { ... }),
            _ => {}
        }
    }

    if hist.is_empty() { NotFound } else { Running { ... } }
}
```

Two provider calls (`read` + `get_custom_status`), then pure in-memory logic.
Perfectly suited for synchronous execution.

### A.4 Provider Methods Used by the Runtime (BGW Only)

The Duroxide runtime (`Runtime::start_with_store`) spawns these concurrent tasks:

1. **Orchestration dispatcher** (default 2 concurrent):
   - `fetch_orchestration_item()` — long-poll, returns locked batch
   - Runs orchestration (deterministic replay)
   - `ack_orchestration_item()` — atomic commit
   - On error: `abandon_orchestration_item()`

2. **Worker dispatcher** (default 2 concurrent):
   - `fetch_work_item()` — long-poll, returns locked activity
   - Executes activity (calls user code)
   - `ack_work_item()` — ack completion
   - `renew_work_item_lock()` — periodic extension during long activities
   - On error: `abandon_work_item()`

3. **Lock renewal** (1 per in-flight item):
   - `renew_orchestration_item_lock()` — extend lock during long replays

4. **Session manager**:
   - `renew_session_lock()` — heartbeat sessions
   - `cleanup_orphaned_sessions()` — clean up dead sessions

These all require `async + Send + Sync` because they run as concurrent tokio tasks
sharing `Arc<dyn Provider>`. This is why the full `Provider` trait cannot use SPI.
