# SlateDB Azure Blob Storage Provider - Design Proposal

## Executive Summary

Design a Duroxide provider using **SlateDB** as the storage engine backed by **Azure Blob Storage**. This combines SlateDB's embedded LSM-tree database with Azure's scalable cloud storage for a serverless-friendly, cost-effective orchestration backend.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│               Duroxide Runtime (Stateless Workers)           │
│  ┌────────────────┐            ┌────────────────┐          │
│  │ Orchestration  │            │ Worker         │          │
│  │ Dispatcher     │            │ Dispatcher     │          │
│  └────────────────┘            └────────────────┘          │
│         ↓                              ↓                     │
│    ┌─────────────────────────────────────────────┐         │
│    │   SlateDB Provider (Embedded)               │         │
│    │   - In-process LSM tree                     │         │
│    │   - Local cache & memtable                  │         │
│    │   - Write-ahead log (WAL)                   │         │
│    └─────────────────────────────────────────────┘         │
│                        ↓                                     │
└────────────────────────┼─────────────────────────────────────┘
                         ↓
           ┌─────────────────────────────┐
           │   Azure Blob Storage         │
           │   ┌─────────────────────┐   │
           │   │ SST Files (History) │   │
           │   │ WAL Segments        │   │
           │   │ Manifest Files      │   │
           │   └─────────────────────┘   │
           │                             │
           │   Blob Leases (Locking)     │
           └─────────────────────────────┘
```

## Key Design Decisions

### 1. **Embedded SlateDB per Worker** (Recommended)
- Each Duroxide worker process runs its own embedded SlateDB instance
- SlateDB handles local caching, memtables, and compaction
- Azure Blob Storage provides the durable, shared storage layer
- Optimistic concurrency with blob leases for coordination

### 2. **Data Layout in Azure Blob Storage**

```
Container: duroxide-{environment}/
├── instances/
│   ├── {instance_id}/
│   │   ├── metadata.json              # Instance metadata
│   │   ├── execution_{id}/
│   │   │   ├── events.sst            # SlateDB SST files (history)
│   │   │   ├── manifest.json         # SlateDB manifest
│   │   │   └── wal/                  # Write-ahead log segments
│   │   └── locks/
│   │       └── instance.lease        # Blob lease for instance lock
│   └── ...
├── queues/
│   ├── orchestrator/
│   │   └── {instance_id}.json        # Work items (with blob leases)
│   └── worker/
│       └── {item_id}.json            # Activity work items
└── slatedb/
    ├── sst/                          # SlateDB SST files
    ├── wal/                          # SlateDB WAL segments  
    └── manifest/                     # SlateDB manifests
```

### 3. **Locking Strategy: Azure Blob Leases**

Azure Blob Storage provides native locking via **blob leases** (30-60 second locks):

```rust
// Acquire instance lock
let lease_id = blob_client
    .acquire_lease(Duration::from_secs(30))
    .await?;

// Lock is automatically released after 30s or explicit release
blob_client.release_lease(lease_id).await?;
```

This gives us:
- ✅ Distributed locking without external coordination
- ✅ Automatic lock expiration (crash recovery)
- ✅ Native Azure service (no extra infrastructure)

## Implementation Plan

### Phase 1: SlateDB Integration (Foundation)

**Goal**: Get SlateDB working with Azure Blob Storage as the object store.

```rust
use slatedb::{DbOptions, Db};
use slatedb::object_store::ObjectStore;

pub struct SlateDbAzureProvider {
    db: Arc<Db>,
    azure_client: Arc<BlobServiceClient>,
    container_name: String,
}

impl SlateDbAzureProvider {
    pub async fn new(
        connection_string: &str,
        container_name: &str,
    ) -> Result<Self> {
        // Create Azure Blob object store adapter
        let object_store = AzureBlobObjectStore::new(connection_string, container_name)?;
        
        // Initialize SlateDB with Azure backend
        let options = DbOptions::default();
        let db = Db::open_with_opts("duroxide", object_store, options).await?;
        
        Ok(Self {
            db: Arc::new(db),
            azure_client: Arc::new(BlobServiceClient::from_connection_string(connection_string)?),
            container_name: container_name.to_string(),
        })
    }
}
```

**Key Questions:**
1. Does SlateDB have native Azure Blob support, or do we need an adapter?
2. What's the performance profile of SlateDB on remote storage (vs local disk)?

### Phase 2: History Storage (Append-Only)

SlateDB is perfect for append-only history storage:

```rust
#[async_trait::async_trait]
impl Provider for SlateDbAzureProvider {
    async fn append_with_execution(
        &self,
        instance: &str,
        execution_id: u64,
        new_events: Vec<Event>,
    ) -> Result<(), ProviderError> {
        for event in new_events {
            let key = format!("history:{}:{}:{:06}", instance, execution_id, event.event_id());
            let value = serde_json::to_vec(&event)?;
            
            self.db.put(key.as_bytes(), &value).await?;
        }
        
        Ok(())
    }
    
    async fn read(&self, instance: &str) -> Result<Vec<Event>, ProviderError> {
        let exec_id = self.latest_execution_id(instance).await?;
        let prefix = format!("history:{}:{}:", instance, exec_id);
        
        let mut events = Vec::new();
        let mut iter = self.db.scan_prefix(prefix.as_bytes()).await?;
        
        while let Some((_, value)) = iter.next().await? {
            events.push(serde_json::from_slice(&value)?);
        }
        
        Ok(events)
    }
}
```

**Benefits:**
- SlateDB's LSM tree is optimized for sequential writes (perfect for history)
- Built-in compaction reduces storage costs
- Range scans for reading history by execution_id

### Phase 3: Queue Implementation Options

**Option A: SlateDB-Only Queues (Simple but Limited)**

Store queue items in SlateDB with timestamp-based keys:

```rust
// Enqueue
let key = format!("queue:orch:{}:{}", visible_at_ms, uuid);
db.put(key.as_bytes(), work_item_json).await?;

// Dequeue with lock
let (key, work_item) = db.scan_prefix(b"queue:orch:")
    .next()
    .await?
    .ok_or("Empty queue")?;

// Acquire Azure Blob Lease for locking
let lease_id = acquire_lease_for_key(&key).await?;
```

❌ **Issues:**
- No native peek-lock in SlateDB
- Need to coordinate with Azure Blob leases
- Complex lease management

**Option B: Azure Queue Storage for Queues (Recommended)**

Use native Azure Queue Storage for work queues:

```rust
use azure_storage_queues::QueueClient;

pub struct SlateDbAzureProvider {
    db: Arc<Db>,  // SlateDB for history
    orch_queue: Arc<QueueClient>,  // Azure Queue for orchestrator
    worker_queue: Arc<QueueClient>, // Azure Queue for workers
}

impl Provider for SlateDbAzureProvider {
    async fn fetch_work_item(&self, lock_timeout: Duration) -> Result<Option<(WorkItem, String)>, ProviderError> {
        // Azure Queue has native peek-lock (visibility timeout)
        let message = self.worker_queue
            .get_messages()
            .number_of_messages(1)
            .visibility_timeout(lock_timeout)
            .execute()
            .await?
            .messages
            .into_iter()
            .next();
        
        if let Some(msg) = message {
            let work_item = serde_json::from_str(&msg.message_text)?;
            let lock_token = format!("{}:{}", msg.message_id, msg.pop_receipt);
            Ok(Some((work_item, lock_token)))
        } else {
            Ok(None)
        }
    }
    
    async fn ack_work_item(&self, token: &str, completion: WorkItem) -> Result<(), ProviderError> {
        let (msg_id, pop_receipt) = parse_token(token)?;
        
        // Delete from worker queue
        self.worker_queue
            .delete_message(msg_id, pop_receipt)
            .await?;
        
        // Enqueue completion to orchestrator queue
        self.enqueue_for_orchestrator(completion, None).await?;
        
        Ok(())
    }
}
```

✅ **Benefits:**
- Native peek-lock semantics
- Automatic visibility timeout (lock expiration)
- Built-in message renewal
- Highly scalable (Azure manages all complexity)

**Option C: Hybrid - Azure Table Storage for Queues**

Use Azure Table Storage for more SQL-like queue operations:

```rust
// Table: orchestrator_queue
// PartitionKey: instance_id
// RowKey: queue_item_id
// Properties: work_item (JSON), visible_at, lock_token, locked_until

// Benefits:
// - Query by partition key (all items for an instance)
// - Conditional updates for locking (ETag-based optimistic concurrency)
// - More flexible than Queue Storage
// - Still serverless and scalable
```

### Phase 4: Instance Locking with Blob Leases

```rust
async fn acquire_instance_lock(
    &self,
    instance: &str,
    lock_timeout: Duration,
) -> Result<String, ProviderError> {
    let blob_path = format!("locks/{}.lock", instance);
    let blob_client = self.azure_client
        .container_client(&self.container_name)
        .blob_client(&blob_path);
    
    // Create blob if it doesn't exist
    if !blob_client.exists().await? {
        blob_client.put_block_blob(b"").await?;
    }
    
    // Acquire lease (native distributed lock)
    let lease = blob_client
        .acquire_lease(lock_timeout)
        .await
        .map_err(|e| {
            if is_lease_already_acquired(&e) {
                ProviderError::retryable("acquire_lock", "Instance already locked")
            } else {
                ProviderError::permanent("acquire_lock", e.to_string())
            }
        })?;
    
    Ok(lease.lease_id)
}

async fn release_instance_lock(
    &self,
    instance: &str,
    lease_id: &str,
) -> Result<(), ProviderError> {
    let blob_path = format!("locks/{}.lock", instance);
    let blob_client = self.azure_client
        .container_client(&self.container_name)
        .blob_client(&blob_path);
    
    blob_client
        .release_lease(lease_id)
        .await
        .map_err(|e| Self::azure_to_provider_error("release_lock", e))?;
    
    Ok(())
}
```

## Architecture Comparison

| Aspect | PostgreSQL | SlateDB + Azure |
|--------|-----------|-----------------|
| **Deployment** | Requires PG server | Serverless (just code + storage) |
| **Cost** | VM + storage | Storage only (~10x cheaper) |
| **Latency** | 20-50ms | 50-200ms (network to Azure) |
| **Scalability** | Limited by PG instance | Unlimited (Azure scales automatically) |
| **Transactions** | Native ACID | Optimistic with retries |
| **Setup** | Complex | Simple (connection string only) |
| **Debugging** | SQL tools | Limited (blob browser) |

## Recommended Implementation Strategy

### **Hybrid Approach** (Best of Both Worlds)

1. **SlateDB for History** (90% of data)
   - Append-only event log
   - LSM tree optimized for writes
   - Efficient range scans

2. **Azure Queue Storage for Work Queues** (10% of data)
   - Native peek-lock semantics
   - Automatic visibility timeouts
   - Battle-tested reliability

3. **Azure Blob Leases for Instance Locking**
   - Native distributed locks
   - Automatic expiration
   - No external coordination needed

### Atomicity Strategy

**Challenge**: No distributed transactions across SlateDB, Queue Storage, and Blob leases.

**Solution**: Use **idempotency keys** and **event sourcing** principles:

```rust
async fn ack_orchestration_item(
    &self,
    lock_token: &str,
    execution_id: u64,
    history_delta: Vec<Event>,
    worker_items: Vec<WorkItem>,
    orchestrator_items: Vec<WorkItem>,
    metadata: ExecutionMetadata,
) -> Result<(), ProviderError> {
    // Step 1: Append history to SlateDB (idempotent - events have unique IDs)
    for event in history_delta {
        let key = format!("history:{}:{}:{:06}", instance, execution_id, event.event_id());
        self.db.put(key.as_bytes(), serde_json::to_vec(&event)?).await?;
    }
    
    // Step 2: Update metadata in SlateDB
    if let Some(status) = metadata.status {
        let key = format!("exec:{}:{}", instance, execution_id);
        self.db.put(key.as_bytes(), serde_json::to_vec(&ExecutionInfo {
            status,
            output: metadata.output,
            ..
        })?).await?;
    }
    
    // Step 3: Enqueue worker items (Azure Queue - at-least-once)
    for item in worker_items {
        self.worker_queue
            .put_message(serde_json::to_string(&item)?)
            .await?;
    }
    
    // Step 4: Enqueue orchestrator items (Azure Queue - at-least-once)
    for item in orchestrator_items {
        let instance = extract_instance(&item);
        let delay = extract_timer_delay(&item);
        
        self.orch_queue
            .put_message(serde_json::to_string(&item)?)
            .visibility_timeout(delay)
            .await?;
    }
    
    // Step 5: Release instance lock (Azure Blob Lease)
    self.release_instance_lock(instance, lock_token).await?;
    
    // Note: Not fully atomic, but:
    // - History append is idempotent (duplicate event_ids rejected)
    // - Queue enqueues are at-least-once (runtime handles duplicates)
    // - Worst case: message reprocessed after crash (acceptable)
    
    Ok(())
}
```

## Performance Analysis

### Expected Latencies

**Read Path** (fetch_orchestration_item):
```
Blob lease acquire:     ~50ms  (Azure API call)
SlateDB range scan:     ~20ms  (read from cache/blob)
Queue message get:      ~30ms  (Azure Queue API)
─────────────────────────────
Total:                 ~100ms  (2-5x slower than PostgreSQL)
```

**Write Path** (ack_orchestration_item):
```
SlateDB writes:         ~30ms  (memtable + WAL)
Queue enqueues:         ~50ms  (Azure Queue batch)
Blob lease release:     ~20ms  (Azure API call)
─────────────────────────────
Total:                 ~100ms  (2-3x slower than PostgreSQL)
```

### Optimizations

1. **Local Caching**: SlateDB maintains a local cache, reducing blob reads
2. **Batch Operations**: Use Azure batch APIs for multiple queue enqueues
3. **Regional Deployment**: Deploy workers in same Azure region as storage
4. **Block Blob Streaming**: Use block blobs for large SST files

## Implementation Roadmap

### Phase 1: Prototype (1-2 weeks)
- [ ] Research SlateDB Azure Blob Storage support
- [ ] Create minimal SlateDB + Azure client wrapper
- [ ] Implement basic read/write operations
- [ ] Validate data persists correctly

### Phase 2: Core Provider (2-3 weeks)
- [ ] Implement Provider trait methods
- [ ] Azure Queue integration for work queues
- [ ] Blob lease-based instance locking
- [ ] Basic error handling and retries

### Phase 3: Reliability (1-2 weeks)
- [ ] Run duroxide provider validation tests
- [ ] Handle edge cases (lease expiration, partial failures)
- [ ] Implement proper idempotency
- [ ] Add comprehensive logging

### Phase 4: Performance (1-2 weeks)
- [ ] Benchmark vs PostgreSQL provider
- [ ] Optimize hot paths (caching, batching)
- [ ] Tune SlateDB compaction settings
- [ ] Add metrics and observability

### Phase 5: Production (1 week)
- [ ] Production deployment guide
- [ ] Monitoring and alerting setup
- [ ] Cost analysis and optimization
- [ ] Failover and disaster recovery

## Open Questions

### Technical

1. **SlateDB Azure Support**: Does SlateDB have built-in Azure Blob support, or do we need to implement an `ObjectStore` adapter?

2. **Compaction**: How does SlateDB compaction work with Azure Blob Storage? Will background compaction cause issues with blob leases?

3. **Cold Start**: What's the initialization time for SlateDB when all data is in cold blob storage?

4. **Consistency**: Can we achieve sufficient consistency guarantees without distributed transactions?

### Operational

5. **Multi-Region**: How do we handle multi-region deployments? (SlateDB is single-writer per path)

6. **Storage Costs**: What's the cost impact of SlateDB's SST files vs PostgreSQL's compressed tables?

7. **Debugging**: How do we debug issues without SQL query tools? Need custom tooling for SlateDB?

8. **Schema Evolution**: How do we handle migrations with blob storage? (No ALTER TABLE equivalent)

## Alternative Architectures

### Alternative 1: Pure Azure Services (No SlateDB)

```
History:        Azure Table Storage (NoSQL)
Queues:         Azure Queue Storage
Locking:        Azure Blob Leases
Transactions:   Optimistic with ETags
```

**Pros**: 
- All-Azure, no third-party dependencies
- Simpler architecture
- Native tooling (Azure Portal, CLI)

**Cons**:
- Less efficient for append-only history
- No LSM tree benefits (compaction, caching)
- Higher Azure Table Storage costs

### Alternative 2: SlateDB + Coordination Service

```
History:        SlateDB on Azure Blob
Queues:         SlateDB on Azure Blob  
Locking:        Redis/etcd for coordination
```

**Pros**:
- Single storage engine (simpler code)
- Better queue performance than blobs

**Cons**:
- Requires external coordination service (more infrastructure)
- Defeats serverless goal

## Cost Analysis (Rough Estimates)

**PostgreSQL Provider** (Baseline):
```
Azure Database for PostgreSQL: $50-500/month (depending on tier)
Storage: Included
IOPS: Included
Total: $50-500/month
```

**SlateDB Azure Provider** (Proposed):
```
Azure Blob Storage: $0.02/GB/month
Blob operations: $0.05 per 10k ops
Queue operations: $0.05 per 10k ops
Total: ~$5-50/month (10-100x cheaper for similar workload)
```

**Breakeven**: At high throughput (millions of operations/day), costs converge. At low-medium throughput, blob storage is significantly cheaper.

## Recommended Next Steps

1. **Experiment with SlateDB**: Create a simple prototype to validate Azure Blob integration
   ```bash
   cargo new slatedb-azure-test
   # Add SlateDB and Azure SDK dependencies
   # Test basic put/get/scan operations
   ```

2. **Benchmark Latency**: Measure actual latencies for:
   - SlateDB write to Azure Blob
   - SlateDB read with cold cache
   - Azure Queue enqueue/dequeue
   - Blob lease acquire/release

3. **Validate SlateDB Features**:
   - Check if Azure Blob object store adapter exists
   - Test compaction behavior with remote storage
   - Verify crash recovery works correctly

4. **Prototype fetch_orchestration_item**: Build the most complex operation end-to-end to validate feasibility

## Decision Matrix

| Priority | PostgreSQL | SlateDB + Azure |
|----------|-----------|-----------------|
| **Low Latency** | ✅ Best (20-50ms) | ⚠️ Good (50-200ms) |
| **Serverless** | ❌ Needs server | ✅ Fully serverless |
| **Low Cost** | ❌ $50+/month | ✅ $5-50/month |
| **Simple Ops** | ⚠️ Moderate | ✅ Very simple |
| **Debugging** | ✅ SQL tools | ⚠️ Limited |
| **ACID** | ✅ Native | ⚠️ Optimistic |
| **Production Ready** | ✅ Battle-tested | ⚠️ Experimental |

## Recommendation

**For Production**: Start with PostgreSQL provider (battle-tested, predictable)

**For Experimentation**: Build SlateDB + Azure provider as:
- Learning exercise
- Cost-optimized option for low-throughput workloads
- Serverless deployment model
- Future hedge against database vendor lock-in

The hybrid approach (SlateDB for history + Azure Queue for queues) gives the best balance of:
- ✅ Simplicity (native Azure services)
- ✅ Performance (optimized for each use case)
- ✅ Cost (cheap blob storage for history)
- ✅ Reliability (proven Azure services)

---

## Questions for You

1. **What's your primary goal?** Cost optimization, serverless deployment, or just exploring alternatives?

2. **What throughput do you expect?** (orchestrations/sec, total instances)

3. **Are you okay with 50-200ms latencies?** (vs 20-50ms with PostgreSQL)

4. **Do you need multi-region?** If yes, SlateDB's single-writer model needs careful design.

5. **Have you used SlateDB before?** Should we do a prototype first to validate assumptions?

Let me know your thoughts and I can refine the proposal or start implementation!


