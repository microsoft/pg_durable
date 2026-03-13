# Duroxide PostgreSQL Provider Architecture

This document provides a comprehensive architecture overview of the `duroxide-pg-opt` PostgreSQL provider for the [Duroxide](https://github.com/microsoft/duroxide) durable workflow framework.

## Table of Contents

- [High-Level Architecture](#high-level-architecture)
- [Component Diagram](#component-diagram)
- [Data Flow](#data-flow)
- [Database Schema](#database-schema)
- [Long-Polling Architecture](#long-polling-architecture)
- [Module Structure](#module-structure)
- [Concurrency Model](#concurrency-model)
- [Feature Flags](#feature-flags)

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    Duroxide Runtime                                          │
│                                                                                             │
│  ┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐               │
│  │  Orchestrator       │   │  Activity Worker    │   │   External API      │               │
│  │  Dispatcher(s)      │   │  Dispatcher(s)      │   │   (raise events)    │               │
│  └──────────┬──────────┘   └──────────┬──────────┘   └──────────┬──────────┘               │
│             │                         │                         │                          │
│             │       Provider Trait Interface                    │                          │
│             └────────────────────┬──────────────────────────────┘                          │
│                                  │                                                          │
└──────────────────────────────────┼──────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│                              PostgresProvider                                               │
│                                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                  Rust Layer                                           │  │
│  │                                                                                       │  │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────────────────┐  │  │
│  │  │   Provider    │  │   Notifier    │  │  Migrations   │  │   Fault Injection     │  │  │
│  │  │   (Trait      │  │   (Long-poll  │  │  Runner       │  │   (test feature)      │  │  │
│  │  │   Impl)       │  │   Thread)     │  │               │  │                       │  │  │
│  │  └───────┬───────┘  └───────┬───────┘  └───────────────┘  └───────────────────────┘  │  │
│  │          │                  │                                                         │  │
│  │          │   sqlx PgPool    │    PgListener                                          │  │
│  │          └────────┬─────────┴──────────────────────────────────────────────────────  │  │
│  │                   │                                                                   │  │
│  └───────────────────┼───────────────────────────────────────────────────────────────────┘  │
│                      │                                                                      │
└──────────────────────┼──────────────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                     PostgreSQL                                               │
│                                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────────────────────┐  │
│  │                              Schema: {schema_name}                                     │  │
│  │                                                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │  instances  │  │ executions  │  │   history   │  │ orch_queue  │  │worker_queue │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └──────┬──────┘  └──────┬──────┘  │  │
│  │                                                            │                │         │  │
│  │  ┌─────────────────┐                                       ▼                ▼         │  │
│  │  │ instance_locks  │                              NOTIFY Triggers                     │  │
│  │  └─────────────────┘                                                                  │  │
│  │                                                                                       │  │
│  │  ┌───────────────────────────────────────────────────────────────────────────────┐   │  │
│  │  │                         Stored Procedures (25+)                                │   │  │
│  │  │  fetch_orchestration_item │ ack_orchestration_item │ fetch_work_item │ ...     │   │  │
│  │  └───────────────────────────────────────────────────────────────────────────────┘   │  │
│  │                                                                                       │  │
│  └───────────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                               PostgresProvider Internals                                     │
│                                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│  │                                   PostgresProvider                                   │   │
│  │                                                                                      │   │
│  │   Fields:                                                                            │   │
│  │   ├── pool: Arc<PgPool>           ─────────── Connection pool (10 conns default)    │   │
│  │   ├── schema_name: String         ─────────── Schema isolation (e.g., "public")     │   │
│  │   ├── orch_notify: Option<Arc<Notify>>  ───── Wake channel for orch dispatchers     │   │
│  │   ├── worker_notify: Option<Arc<Notify>> ──── Wake channel for worker dispatchers   │   │
│  │   ├── notifier_handle: Option<JoinHandle<()>> Notifier thread handle                │   │
│  │   └── fault_injector: Option<Arc<FaultInjector>>  (test feature only)               │   │
│  │                                                                                      │   │
│  │   Implements:                                                                        │   │
│  │   ├── duroxide::Provider          ─────────── Core orchestration/work operations    │   │
│  │   └── duroxide::ProviderAdmin     ─────────── Management & observability            │   │
│  │                                                                                      │   │
│  └─────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
│           │                                           │                                     │
│           │ Uses                                      │ Spawns                              │
│           ▼                                           ▼                                     │
│  ┌─────────────────────────┐              ┌───────────────────────────────────────────────┐ │
│  │   MigrationRunner       │              │                  Notifier                     │ │
│  │                         │              │                                               │ │
│  │   • Loads embedded SQL  │              │   Fields:                                     │ │
│  │   • Tracks applied      │              │   ├── pg_listener: PgListener                 │ │
│  │     versions            │              │   ├── pool: PgPool                            │ │
│  │   • Creates tables,     │              │   ├── orch_heap: BinaryHeap<Instant>          │ │
│  │     stored procs        │              │   ├── worker_heap: BinaryHeap<Instant>        │ │
│  │   • Runs on startup     │              │   ├── orch_notify: Arc<Notify>                │ │
│  │                         │              │   ├── worker_notify: Arc<Notify>              │ │
│  └─────────────────────────┘              │   ├── next_refresh: Instant                   │ │
│                                           │   ├── pending_refresh: Option<Receiver>       │ │
│                                           │   └── config: LongPollConfig                  │ │
│                                           │                                               │ │
│                                           │   Responsibilities:                           │ │
│                                           │   • LISTEN for NOTIFY events                  │ │
│                                           │   • Manage timer heaps for delayed items      │ │
│                                           │   • Wake dispatchers at correct times         │ │
│                                           │   • Periodic refresh query                    │ │
│                                           │                                               │ │
│                                           └───────────────────────────────────────────────┘ │
│                                                                                             │
│  ┌─────────────────────────┐              ┌───────────────────────────────────────────────┐ │
│  │   DbCallTimer           │              │               FaultInjector                   │ │
│  │   (db_metrics module)   │              │           (test feature only)                 │ │
│  │                         │              │                                               │ │
│  │   • Zero-cost metrics   │              │   Injectables:                                │ │
│  │   • Records durations   │              │   ├── notifier_disabled                       │ │
│  │   • Tracks SP calls     │              │   ├── clock_skew_ms                           │ │
│  │   • Fetch success rate  │              │   ├── refresh_delay                           │ │
│  │                         │              │   ├── force_reconnect                         │ │
│  │   Feature: db-metrics   │              │   └── refresh_should_error                    │ │
│  │                         │              │                                               │ │
│  └─────────────────────────┘              └───────────────────────────────────────────────┘ │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### Orchestration Item Processing

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                           Orchestration Item Lifecycle                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

   ┌─────────────┐                                                                            
   │   Client    │                                                                            
   └──────┬──────┘                                                                            
          │                                                                                   
          │ 1. Start orchestration                                                            
          ▼                                                                                   
   ┌──────────────────┐     enqueue_for_orchestrator()                                        
   │ Runtime          │ ──────────────────────────────────────────────────────────────────┐   
   └──────────────────┘                                                                   │   
                                                                                          │   
                                                                                          ▼   
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                              PostgreSQL orchestrator_queue                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│  │  INSERT → NOTIFY trigger fires → '{schema}_orch_work' channel                        │   │
│  └─────────────────────────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────┬─────────────────────────────────────────┘
                                                    │                                         
                                                    │ 2. NOTIFY                               
                                                    ▼                                         
          ┌─────────────────────────────────────────────────────────────────────────────┐     
          │                          Notifier Thread                                     │     
          │                                                                             │     
          │   ┌─────────────────────────────────────────────────────────────────────┐   │     
          │   │  if visible_at <= now:                                              │   │     
          │   │      orch_notify.notify_waiters()  ─────────────────────────┐       │   │     
          │   │  else if visible_at <= next_refresh:                        │       │   │     
          │   │      orch_heap.push(visible_at + grace_period)              │       │   │     
          │   │  else:                                                      │       │   │     
          │   │      ignore (refresh will catch)                            │       │   │     
          │   └─────────────────────────────────────────────────────────────│───────┘   │     
          │                                                                 │           │     
          └─────────────────────────────────────────────────────────────────│───────────┘     
                                                                            │                 
                                                    3. Wake signal          │                 
                                                                            ▼                 
          ┌─────────────────────────────────────────────────────────────────────────────┐     
          │                     Orchestrator Dispatcher                                  │     
          │                                                                             │     
          │   ┌─────────────────────────────────────────────────────────────────────┐   │     
          │   │  loop {                                                             │   │     
          │   │      let result = provider.fetch_orchestration_item(                │   │     
          │   │          lock_timeout,                                              │   │     
          │   │          poll_timeout                                               │   │     
          │   │      ).await;                                                       │   │     
          │   │                                                                     │   │     
          │   │      // Inside fetch_orchestration_item:                            │   │     
          │   │      // 1. Try do_fetch() immediately                               │   │     
          │   │      // 2. If None, wait on notify OR timeout                       │   │     
          │   │      // 3. On wake, do_fetch() again                                │   │     
          │   │  }                                                                  │   │     
          │   └─────────────────────────────────────────────────────────────────────┘   │     
          │                                                                             │     
          └─────────────────────────────────────────────────────────────────────────────┘     
                                                    │                                         
                                                    │ 4. fetch_orchestration_item()           
                                                    ▼                                         
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   PostgreSQL                                                 │
│                                                                                             │
│   Stored Procedure: fetch_orchestration_item(p_now_ms, p_lock_timeout_ms)                   │
│   ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│   │  1. Find candidate instance (visible_at <= now, no active lock)                     │   │
│   │  2. Acquire advisory lock: pg_advisory_xact_lock(hashtext(instance_id))             │   │
│   │  3. Re-verify with FOR UPDATE SKIP LOCKED                                           │   │
│   │  4. Insert/update instance_locks with new lock_token                                │   │
│   │  5. Tag queue items with lock_token                                                 │   │
│   │  6. Aggregate history + messages as JSONB                                           │   │
│   │  7. Return (instance_id, history, messages, lock_token, attempt_count)              │   │
│   └─────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
└───────────────────────────────────────────────────┬─────────────────────────────────────────┘
                                                    │                                         
                                                    │ 5. Returns OrchestrationItem            
                                                    ▼                                         
          ┌─────────────────────────────────────────────────────────────────────────────┐     
          │                         Orchestrator                                         │     
          │                                                                             │     
          │   Replay history → Execute user code → Produce decisions                    │     
          │                                                                             │     
          └───────────────────────────────────────────┬─────────────────────────────────┘     
                                                      │                                       
                                                      │ 6. ack_orchestration_item()           
                                                      ▼                                       
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   PostgreSQL                                                 │
│                                                                                             │
│   Stored Procedure: ack_orchestration_item(...)                                             │
│   ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│   │  1. Validate lock_token                                                             │   │
│   │  2. Insert/update instance record with metadata                                     │   │
│   │  3. Insert/update execution record                                                  │   │
│   │  4. Append history_delta to history table                                           │   │
│   │  5. Enqueue worker_items → worker_queue (triggers NOTIFY)                           │   │
│   │  6. Enqueue orchestrator_items → orchestrator_queue (triggers NOTIFY)               │   │
│   │  7. Delete cancelled activities from worker_queue (lock-stealing)                   │   │
│   │  8. Delete processed queue items                                                    │   │
│   │  9. Release instance_lock                                                           │   │
│   └─────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Work Item (Activity) Processing

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                              Activity Work Item Lifecycle                                    │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

          ┌─────────────────────────────────────────────────────────────────────────────┐     
          │              Activity Worker Dispatcher                                      │     
          │                                                                             │     
          │   loop {                                                                    │     
          │       let (work_item, token, attempt) = provider.fetch_work_item(           │     
          │           lock_timeout,                                                     │     
          │           poll_timeout                                                      │     
          │       ).await?;                                                             │     
          │                                                                             │     
          │       // Execute activity                                                   │     
          │       let result = activity_fn(work_item.input).await;                      │     
          │                                                                             │     
          │       // Acknowledge with completion                                        │     
          │       provider.ack_work_item(&token, Some(completion)).await?;              │     
          │   }                                                                         │     
          │                                                                             │     
          └───────────────────────────────────────────┬─────────────────────────────────┘     
                                                      │                                       
                                                      ▼                                       
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    PostgreSQL                                                │
│                                                                                             │
│   fetch_work_item:                        ack_worker:                                       │
│   ┌─────────────────────────┐             ┌─────────────────────────────────────────────┐   │
│   │ 1. SELECT ... FOR UPDATE│             │ 1. DELETE from worker_queue WHERE token     │   │
│   │    SKIP LOCKED          │             │ 2. INSERT completion → orchestrator_queue   │   │
│   │ 2. Generate lock_token  │             │    (triggers NOTIFY → wakes orch dispatcher)│   │
│   │ 3. Update locked_until  │             │                                             │   │
│   │ 4. Increment attempt    │             │                                             │   │
│   └─────────────────────────┘             └─────────────────────────────────────────────┘   │
│                                                                                             │
│   Lock Renewal (for long-running activities):                                               │
│   ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│   │  renew_work_item_lock(token, now_ms, extend_ms)                                     │   │
│   │  → Extends locked_until                                                             │   │
│   │  → Returns execution_status (for cancellation detection)                            │   │
│   └─────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Database Schema

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                              Database Schema (Entity Relationships)                          │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│     ┌─────────────────────────────────┐                                                     │
│     │         instances               │                                                     │
│     │─────────────────────────────────│                                                     │
│     │ PK instance_id: TEXT            │◄─────────────────────────────────┐                  │
│     │    orchestration_name: TEXT     │                                  │                  │
│     │    orchestration_version: TEXT  │                  FK              │                  │
│     │    current_execution_id: BIGINT │─ ─ ─ ─ ─ ─ ─ ─ ─ ┐               │                  │
│     │    parent_instance_id: TEXT     │──────────────────┼───────────────┘ (self-ref)       │
│     │    created_at: TIMESTAMPTZ      │                  │                                  │
│     │    updated_at: TIMESTAMPTZ      │                  │                                  │
│     └─────────────────────────────────┘                  │                                  │
│                    │                                     │                                  │
│                    │ 1:N                                 │                                  │
│                    ▼                                     │                                  │
│     ┌─────────────────────────────────┐                  │                                  │
│     │         executions              │                  │                                  │
│     │─────────────────────────────────│                  │                                  │
│     │ PK instance_id: TEXT            │◄─────────────────┘                                  │
│     │ PK execution_id: BIGINT         │                                                     │
│     │    status: TEXT                 │  (Running, Completed, Failed, ContinuedAsNew)       │
│     │    output: TEXT                 │                                                     │
│     │    started_at: TIMESTAMPTZ      │                                                     │
│     │    completed_at: TIMESTAMPTZ    │                                                     │
│     └─────────────────────────────────┘                                                     │
│                    │                                                                        │
│                    │ 1:N                                                                    │
│                    ▼                                                                        │
│     ┌─────────────────────────────────┐                                                     │
│     │          history                │                                                     │
│     │─────────────────────────────────│                                                     │
│     │ PK instance_id: TEXT            │                                                     │
│     │ PK execution_id: BIGINT         │                                                     │
│     │ PK event_id: BIGINT             │                                                     │
│     │    event_type: TEXT             │  (OrchestrationStarted, ActivityScheduled, ...)     │
│     │    event_data: TEXT (JSON)      │  ◄── Full Event serialized as JSON                  │
│     │    created_at: TIMESTAMPTZ      │                                                     │
│     └─────────────────────────────────┘                                                     │
│                                                                                             │
│  ═══════════════════════════════════════════════════════════════════════════════════════    │
│                                        QUEUES                                               │
│  ═══════════════════════════════════════════════════════════════════════════════════════    │
│                                                                                             │
│     ┌─────────────────────────────────┐       ┌─────────────────────────────────┐           │
│     │      orchestrator_queue         │       │        worker_queue             │           │
│     │─────────────────────────────────│       │─────────────────────────────────│           │
│     │ PK id: BIGSERIAL                │       │ PK id: BIGSERIAL                │           │
│     │    instance_id: TEXT            │       │    work_item: TEXT (JSON)       │           │
│     │    work_item: TEXT (JSON)       │       │    visible_at: TIMESTAMPTZ      │           │
│     │    visible_at: TIMESTAMPTZ      │ ◄──── │    lock_token: TEXT             │           │
│     │    lock_token: TEXT             │  Timer│    locked_until: BIGINT (ms)    │           │
│     │    locked_until: BIGINT (ms)    │ delay │    created_at: TIMESTAMPTZ      │           │
│     │    created_at: TIMESTAMPTZ      │       │    attempt_count: INTEGER       │           │
│     │    attempt_count: INTEGER       │       │                                 │           │
│     │                                 │       │ Indexes:                        │           │
│     │ Indexes:                        │       │ • idx_worker_visible            │           │
│     │ • idx_orch_visible              │       │ • idx_worker_available          │           │
│     │ • idx_orch_instance             │       │                                 │           │
│     │ • idx_orch_lock                 │       │ Trigger:                        │           │
│     │                                 │       │ • notify_worker_work()          │           │
│     │ Trigger:                        │       │   → NOTIFY {schema}_worker_work │           │
│     │ • notify_orch_work()            │       │                                 │           │
│     │   → NOTIFY {schema}_orch_work   │       └─────────────────────────────────┘           │
│     │                                 │                                                     │
│     └─────────────────────────────────┘                                                     │
│                                                                                             │
│  ═══════════════════════════════════════════════════════════════════════════════════════    │
│                                    LOCKING                                                  │
│  ═══════════════════════════════════════════════════════════════════════════════════════    │
│                                                                                             │
│     ┌─────────────────────────────────┐                                                     │
│     │       instance_locks            │                                                     │
│     │─────────────────────────────────│                                                     │
│     │ PK instance_id: TEXT            │                                                     │
│     │    lock_token: TEXT             │  ◄── Unique per fetch, validated on ack            │
│     │    locked_until: BIGINT (ms)    │  ◄── Unix epoch ms, enables lock expiration        │
│     │    locked_at: BIGINT (ms)       │                                                     │
│     │                                 │                                                     │
│     │ Index:                          │                                                     │
│     │ • idx_instance_locks_locked_until                                                     │
│     │                                 │                                                     │
│     └─────────────────────────────────┘                                                     │
│                                                                                             │
│  ═══════════════════════════════════════════════════════════════════════════════════════    │
│                                   METADATA                                                  │
│  ═══════════════════════════════════════════════════════════════════════════════════════    │
│                                                                                             │
│     ┌─────────────────────────────────┐                                                     │
│     │      _duroxide_migrations       │                                                     │
│     │─────────────────────────────────│                                                     │
│     │ PK version: BIGINT              │                                                     │
│     │    name: TEXT                   │                                                     │
│     │    applied_at: TIMESTAMPTZ      │                                                     │
│     └─────────────────────────────────┘                                                     │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Long-Polling Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                           Long-Polling Notification Flow                                     │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

WITHOUT Long-Polling (idle system):
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│   4 dispatchers × 20 polls/sec × 2 queues = 160 queries/sec (constant)                      │
│                                                                                             │
│   Dispatcher ──► Query ──► None ──► Sleep 50ms ──► Query ──► None ──► Sleep ──► ...        │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

WITH Long-Polling (idle system):
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│   1 refresh query per 60s = ~0.03 queries/sec (99.98% reduction)                            │
│                                                                                             │
│   Dispatcher ──► Query ──► None ──► Wait on Notify ─────────────────────────────────────►   │
│                                          ▲                                                  │
│                                          │ Woken by NOTIFY or timer                        │
│   Notifier   ──► LISTEN ─────────────────┘                                                  │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

Detailed Notifier Thread Loop:
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│                              ┌─────────────────────────────┐                                │
│                              │       Main Loop             │                                │
│                              └──────────────┬──────────────┘                                │
│                                             │                                               │
│                                             ▼                                               │
│                              ┌─────────────────────────────┐                                │
│                              │   Calculate next_wake:      │                                │
│                              │   min(earliest_timer,       │                                │
│                              │       next_refresh)         │                                │
│                              └──────────────┬──────────────┘                                │
│                                             │                                               │
│                                             ▼                                               │
│                    ┌────────────────────────────────────────────────┐                       │
│                    │                   select!                       │                       │
│                    │                                                │                       │
│     ┌──────────────┼──────────────────┬─────────────────────────────┼───────────────┐       │
│     │              │                  │                             │               │       │
│     ▼              │                  ▼                             │               ▼       │
│  ┌──────────┐      │           ┌─────────────┐                      │        ┌───────────┐  │
│  │ NOTIFY   │      │           │ Timer fires │                      │        │ Refresh   │  │
│  │ received │      │           │ or refresh  │                      │        │ completes │  │
│  └────┬─────┘      │           │ due         │                      │        └─────┬─────┘  │
│       │            │           └──────┬──────┘                      │              │        │
│       ▼            │                  │                             │              ▼        │
│  ┌──────────────┐  │                  ▼                             │   ┌────────────────┐  │
│  │ Parse        │  │           ┌─────────────────┐                  │   │ Add timers to  │  │
│  │ visible_at   │  │           │ Pop expired     │                  │   │ heap from      │  │
│  │ from payload │  │           │ timers, wake    │                  │   │ query results  │  │
│  └──────┬───────┘  │           │ dispatchers     │                  │   │                │  │
│         │          │           └─────────────────┘                  │   │ Schedule next  │  │
│         ▼          │                  │                             │   │ refresh        │  │
│  ┌────────────────────────────────────┼─────────────────────────────┼───┴────────────────┐  │
│  │                          Decision Tree                           │                    │  │
│  │                                                                  │                    │  │
│  │   visible_at <= now?  ──YES──►  notify_waiters() immediately     │                    │  │
│  │         │                                                        │                    │  │
│  │        NO                                                        │                    │  │
│  │         │                                                        │                    │  │
│  │         ▼                                                        │                    │  │
│  │   visible_at <= next_refresh?                                    │                    │  │
│  │         │                                                        │                    │  │
│  │   ──YES──►  heap.push(visible_at + 100ms grace)                  │                    │  │
│  │         │                                                        │                    │  │
│  │   ──NO───►  Ignore (refresh query will catch it)                 │                    │  │
│  │                                                                  │                    │  │
│  └──────────────────────────────────────────────────────────────────┘                    │  │
│                                                                                          │  │
└──────────────────────────────────────────────────────────────────────────────────────────┘  │
                                                                                              │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

Timer Precision (100ms Grace Period):
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│   visible_at          visible_at + 100ms         fetch query                                │
│       │                      │                       │                                      │
│       ▼                      ▼                       ▼                                      │
│   ────┼──────────────────────┼───────────────────────┼───────►  time                        │
│       │                      │                       │                                      │
│       │   ◄── grace ──►      │                       │                                      │
│       │      period          │                       │                                      │
│       │      100ms           │                       │                                      │
│       │                      │                       │                                      │
│    Row becomes            Timer fires,          SELECT succeeds                             │
│    queryable              wake dispatchers      (row definitely visible)                    │
│                                                                                             │
│   Grace period absorbs:                                                                     │
│   • Clock skew between nodes (NTP ~50ms)                                                    │
│   • Tokio timer jitter                                                                      │
│   • Transaction commit timing                                                               │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Module Structure

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   Crate Structure                                            │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

duroxide-pg-opt/
│
├── src/
│   │
│   ├── lib.rs                 ◄── Crate root, re-exports public API
│   │   │
│   │   ├── PostgresProvider        ◄── Main provider struct
│   │   ├── LongPollConfig          ◄── Long-polling configuration
│   │   └── FaultInjector           ◄── (test-fault-injection feature)
│   │
│   ├── provider.rs            ◄── PostgresProvider implementation
│   │   │
│   │   ├── impl Provider           ◄── Core operations
│   │   │   ├── fetch_orchestration_item()
│   │   │   ├── ack_orchestration_item()
│   │   │   ├── abandon_orchestration_item()
│   │   │   ├── renew_orchestration_item_lock()
│   │   │   ├── fetch_work_item()
│   │   │   ├── ack_work_item()
│   │   │   ├── abandon_work_item()
│   │   │   ├── renew_work_item_lock()
│   │   │   ├── enqueue_for_orchestrator()
│   │   │   ├── enqueue_for_worker()
│   │   │   ├── read() / read_with_execution()
│   │   │   └── append_with_execution()
│   │   │
│   │   └── impl ProviderAdmin      ◄── Management operations
│   │       ├── list_instances() / list_instances_by_status()
│   │       ├── list_executions()
│   │       ├── get_instance_info() / get_execution_info()
│   │       ├── get_system_metrics() / get_queue_depths()
│   │       ├── list_children() / get_parent_id()
│   │       ├── delete_instances_atomic() / delete_instance_bulk()
│   │       └── prune_executions() / prune_executions_bulk()
│   │
│   ├── notifier.rs            ◄── Long-polling notifier thread
│   │   │
│   │   ├── LongPollConfig          ◄── Configuration struct
│   │   ├── Notifier                ◄── Background thread struct
│   │   │   ├── run()               ◄── Main select! loop
│   │   │   ├── handle_notify()     ◄── Process NOTIFY payload
│   │   │   ├── pop_and_wake_expired_timers()
│   │   │   ├── maybe_start_refresh()
│   │   │   ├── handle_refresh_result()
│   │   │   └── handle_reconnect()
│   │   │
│   │   └── Helper functions
│   │       ├── parse_notify_action()   ◄── Pure, testable
│   │       └── timers_from_refresh()   ◄── Pure, testable
│   │
│   ├── migrations.rs          ◄── Schema migration runner
│   │   │
│   │   └── MigrationRunner
│   │       ├── migrate()           ◄── Run pending migrations
│   │       ├── load_migrations()   ◄── From embedded SQL files
│   │       ├── split_sql_statements() ◄── Handle $$ quoting
│   │       └── apply_migration()
│   │
│   ├── db_metrics.rs          ◄── Database instrumentation (db-metrics feature)
│   │   │
│   │   ├── DbOperation enum        ◄── StoredProcedure, Select, Insert, ...
│   │   ├── FetchType enum          ◄── Orchestration, WorkItem
│   │   ├── DbCallTimer             ◄── RAII duration recorder
│   │   ├── record_db_call()
│   │   ├── record_fetch_result()
│   │   └── record_fetch_attempt()
│   │
│   └── fault_injection.rs     ◄── Test fault injection (test-fault-injection feature)
│       │
│       └── FaultInjector
│           ├── disable_notifier()
│           ├── set_clock_skew() / set_clock_skew_signed()
│           ├── set_refresh_delay()
│           ├── trigger_reconnect()
│           └── set_refresh_should_error()
│
├── migrations/                ◄── Embedded SQL migrations
│   ├── 0001_initial_schema.sql    ◄── Tables, indexes, stored procedures
│   ├── 0002_add_deletion_and_pruning_support.sql
│   └── README.md
│
├── tests/                     ◄── Integration tests
│   ├── postgres_provider_test.rs  ◄── Provider validation (61 tests)
│   ├── longpoll_tests.rs
│   ├── fault_injection_tests.rs
│   ├── stress_tests.rs
│   └── ...
│
└── pg-stress/                 ◄── Stress test binary
    └── src/
        ├── lib.rs             ◄── PostgresStressFactory
        └── bin/pg-stress.rs   ◄── CLI entry point
```

---

## Concurrency Model

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                              Concurrent Access Patterns                                      │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

Instance-Level Locking (Orchestrator Queue):
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│   Dispatcher A                              Dispatcher B                                    │
│       │                                         │                                           │
│       │  fetch_orchestration_item()             │  fetch_orchestration_item()               │
│       │         │                               │         │                                 │
│       ▼         ▼                               ▼         ▼                                 │
│   ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                        PostgreSQL (fetch_orchestration_item SP)                      │   │
│   │                                                                                     │   │
│   │  Phase 1: Find candidate instance (lightweight query)                               │   │
│   │           SELECT instance_id ... LIMIT 1                                            │   │
│   │                    │                                                                │   │
│   │  Phase 2: Acquire advisory lock                                                     │   │
│   │           pg_advisory_xact_lock(hashtext(instance_id))                              │   │
│   │                    │                                                                │   │
│   │                    ├──────────────────────────────────────────┐                     │   │
│   │                    ▼                                          │ (waits)             │   │
│   │  Phase 3: Re-verify with FOR UPDATE SKIP LOCKED               │                     │   │
│   │           If lost race → find next candidate                  │                     │   │
│   │                    │                                          │                     │   │
│   │  Phase 4: Insert into instance_locks (ON CONFLICT check)      │                     │   │
│   │                    │                                          │                     │   │
│   │  Phase 5: Return item                                         │                     │   │
│   │                    │                                          │                     │   │
│   │                    ▼                                          ▼                     │   │
│   │              Item returned                             Gets different instance      │   │
│   │                                                        OR returns None              │   │
│   │                                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
│   Key Properties:                                                                           │
│   ✓ Instance exclusivity: Only one dispatcher can hold an instance at a time               │
│   ✓ No deadlocks: Advisory locks released at transaction end                               │
│   ✓ SKIP LOCKED: Contending dispatchers don't block, find other work                       │
│   ✓ Lock expiration: Crashed dispatchers don't hold locks forever                          │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

Worker Queue (Simpler Pattern):
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│   Worker A                                  Worker B                                        │
│       │                                         │                                           │
│       │  fetch_work_item()                      │  fetch_work_item()                        │
│       ▼                                         ▼                                           │
│   ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          PostgreSQL (fetch_work_item SP)                             │   │
│   │                                                                                     │   │
│   │  SELECT id, work_item FROM worker_queue                                             │   │
│   │  WHERE visible_at <= NOW() AND (lock_token IS NULL OR locked_until <= now_ms)       │   │
│   │  ORDER BY id                                                                        │   │
│   │  LIMIT 1                                                                            │   │
│   │  FOR UPDATE SKIP LOCKED                                                             │   │
│   │       │                                          │                                  │   │
│   │       │                                          │                                  │   │
│   │       ▼                                          ▼                                  │   │
│   │   Locks row #1                              Locks row #2 (or None)                  │   │
│   │   Updates lock_token, locked_until          Updates lock_token, locked_until        │   │
│   │                                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
│   Key Properties:                                                                           │
│   ✓ FIFO ordering: ORDER BY id ensures oldest items processed first                        │
│   ✓ No starvation: SKIP LOCKED means no waiting                                            │
│   ✓ Lock timeout: Activities can renew locks for long-running work                         │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

Lock Renewal Pattern:
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│   Activity Worker (long-running activity)                                                   │
│                                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                                                                     │   │
│   │   fetch_work_item()  ─────►  Execute activity  ─────►  ack_work_item()              │   │
│   │         │                          │                         │                      │   │
│   │         │                          │  (every 10s)            │                      │   │
│   │         │                          ▼                         │                      │   │
│   │         │            ┌──────────────────────────┐            │                      │   │
│   │         │            │  renew_work_item_lock()  │            │                      │   │
│   │         │            │                          │            │                      │   │
│   │         │            │  Returns:                │            │                      │   │
│   │         │            │  • "Running" → continue  │            │                      │   │
│   │         │            │  • "Completed" → cancel  │            │                      │   │
│   │         │            │  • "Failed" → cancel     │            │                      │   │
│   │         │            │  • NULL → orphaned       │            │                      │   │
│   │         │            └──────────────────────────┘            │                      │   │
│   │         │                                                    │                      │   │
│   │         └────────────── lock_timeout (e.g., 30s) ────────────┘                      │   │
│   │                                                                                     │   │
│   │   If lock not renewed within timeout:                                               │   │
│   │   • Lock expires                                                                    │   │
│   │   • Another worker can pick up the work                                             │   │
│   │   • Original worker's ack fails (invalid token)                                     │   │
│   │                                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Feature Flags

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    Cargo Features                                            │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│   ┌──────────────────────────────────┐                                                      │
│   │  test-fault-injection (default)  │                                                      │
│   │                                  │                                                      │
│   │  Enables:                        │                                                      │
│   │  • FaultInjector struct          │                                                      │
│   │  • Clock skew simulation         │                                                      │
│   │  • Notifier disable              │                                                      │
│   │  • Refresh delays/errors         │                                                      │
│   │  • Connection drop simulation    │                                                      │
│   │                                  │                                                      │
│   │  Used by:                        │                                                      │
│   │  • fault_injection_tests.rs      │                                                      │
│   │  • Resilience testing            │                                                      │
│   │                                  │                                                      │
│   └──────────────────────────────────┘                                                      │
│                                                                                             │
│   ┌──────────────────────────────────┐                                                      │
│   │  db-metrics                      │                                                      │
│   │                                  │                                                      │
│   │  Enables:                        │                                                      │
│   │  • Zero-cost metrics recording   │                                                      │
│   │  • DbCallTimer RAII guard        │                                                      │
│   │  • Fetch success/empty tracking  │                                                      │
│   │  • Duration histograms           │                                                      │
│   │                                  │                                                      │
│   │  Metrics exported:               │                                                      │
│   │  • duroxide.db.calls             │                                                      │
│   │  • duroxide.db.sp_calls          │                                                      │
│   │  • duroxide.db.call_duration_ms  │                                                      │
│   │  • duroxide.fetch.attempts       │                                                      │
│   │  • duroxide.fetch.items          │                                                      │
│   │  • duroxide.fetch.loaded         │                                                      │
│   │  • duroxide.fetch.empty          │                                                      │
│   │  • duroxide.fetch.*_duration_ms  │                                                      │
│   │                                  │                                                      │
│   │  Used by:                        │                                                      │
│   │  • perf_tests.rs                 │                                                      │
│   │  • Long-poll effectiveness       │                                                      │
│   │    comparison                    │                                                      │
│   │                                  │                                                      │
│   └──────────────────────────────────┘                                                      │
│                                                                                             │
│   Feature Combinations:                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                                                                     │   │
│   │  Production:      cargo build --release (no extra features)                         │   │
│   │                   → Long-poll enabled, no metrics overhead                          │   │
│   │                                                                                     │   │
│   │  Testing:         cargo test                                                        │   │
│   │                   → test-fault-injection enabled by default                         │   │
│   │                                                                                     │   │
│   │  Perf Analysis:   cargo test --features db-metrics -- --test-threads=1             │   │
│   │                   → Metrics recorded for analysis                                   │   │
│   │                                                                                     │   │
│   │  Fault Tests:     cargo test --test fault_injection_tests --features               │   │
│   │                   test-fault-injection --run-ignored ignored-only                   │   │
│   │                                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Stored Procedures Summary

| Procedure | Purpose |
|-----------|---------|
| `fetch_orchestration_item` | Atomically fetch and lock orchestration work |
| `ack_orchestration_item` | Commit history, enqueue work, release lock |
| `abandon_orchestration_item` | Release lock without committing |
| `renew_orchestration_item_lock` | Extend lock timeout |
| `fetch_work_item` | Fetch and lock activity work |
| `ack_worker` | Complete activity, enqueue result |
| `abandon_work_item` | Release worker lock |
| `renew_work_item_lock` | Extend worker lock, return execution status |
| `enqueue_orchestrator_work` | Add work to orchestrator queue |
| `enqueue_worker_work` | Add work to worker queue |
| `fetch_history` | Read history for latest execution |
| `fetch_history_with_execution` | Read history for specific execution |
| `append_history` | Append events to history |
| `list_instances` | List all instances |
| `list_instances_by_status` | Filter instances by status |
| `list_executions` | List executions for instance |
| `latest_execution_id` | Get current execution ID |
| `get_instance_info` | Get instance metadata |
| `get_execution_info` | Get execution metadata |
| `get_system_metrics` | Aggregate system stats |
| `get_queue_depths` | Queue sizes for monitoring |
| `list_children` | Get child instances |
| `get_parent_id` | Get parent instance |
| `delete_instances_atomic` | Cascade delete with safety checks |
| `prune_executions` | Remove old executions |
| `cleanup_schema` | Drop all tables (testing) |

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Stored Procedures for all operations** | Atomic transactions, reduced round-trips, database-level locking |
| **Rust-generated timestamps** | Single clock source, predictable behavior, testable with mock clocks |
| **Instance-level locks (separate table)** | Enables message batching, prevents message interleaving |
| **LISTEN/NOTIFY for long-poll** | Native PostgreSQL, no external dependencies, schema-isolated channels |
| **Timer heap in notifier** | Precise timer firing, no polling for scheduled work |
| **Grace period (100ms)** | Absorbs clock skew, timer jitter, transaction commit timing |
| **Advisory locks for fetch** | No deadlocks, automatic cleanup, combined with SKIP LOCKED |
| **JSON serialization in DB** | Flexibility, no schema changes for event types, duroxide compatibility |
| **Embedded migrations** | Self-contained deployment, automatic schema setup |
