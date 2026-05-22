# Proposal: Instance Management API for pg_durable

## Executive Summary

The new duroxide v0.1.11 introduces a comprehensive management API for orchestration lifecycle operations: deleting instances (with force option), bulk deletion, and pruning old executions. This proposal outlines how to integrate these capabilities into pg_durable as SQL functions in the `df` schema.

## Background

### Current State
pg_durable already exposes monitoring functions via `df.list_instances()`, `df.instance_info()`, `df.instance_executions()`, `df.metrics()`, and `df.instance_nodes()` using the duroxide `Client` management API. These are read-only operations.

### What's New in Duroxide
The duroxide v0.1.11 `Client` struct now exposes the following management operations:

| Method | Description |
|--------|-------------|
| `delete_instance(id, force)` | Delete a single instance (cascades to sub-orchestrations) |
| `delete_instance_bulk(filter)` | Delete multiple instances matching filter criteria |
| `get_instance_tree(id)` | Preview cascade deletion impact |
| `prune_executions(id, options)` | Remove old executions from a long-running instance |
| `prune_executions_bulk(filter, options)` | Bulk prune across multiple instances |

### Key Types

```rust
// Filter for selecting instances
struct InstanceFilter {
    instance_ids: Option<Vec<String>>,  // Allowlist of IDs
    completed_before: Option<u64>,       // Completed before timestamp (ms epoch)
    limit: Option<u32>,                  // Max instances to process (default: 1000)
}

// Options for pruning
struct PruneOptions {
    keep_last: Option<u32>,              // Keep last N executions
    completed_before: Option<u64>,       // Only prune executions completed before timestamp
}

// Result of deletion
struct DeleteInstanceResult {
    instances_deleted: u64,
    executions_deleted: u64,
    events_deleted: u64,
    queue_messages_deleted: u64,
}

// Result of pruning
struct PruneResult {
    instances_processed: u64,
    executions_deleted: u64,
    events_deleted: u64,
}

// Instance tree for cascade preview
struct InstanceTree {
    root_id: String,
    all_ids: Vec<String>,
}
```

---

## Proposed API

### 1. Delete Instance

```sql
-- Delete a completed/failed instance
SELECT * FROM df.delete_instance('my-instance-id');

-- Force delete a running instance (use with caution!)
SELECT * FROM df.delete_instance('my-instance-id', force => true);
```

**Function Signature:**
```sql
CREATE FUNCTION df.delete_instance(
    instance_id TEXT,
    force BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    instances_deleted BIGINT,
    executions_deleted BIGINT,
    events_deleted BIGINT,
    queue_messages_deleted BIGINT
);
```

**Behavior:**
- Deletes the instance, all its executions, history events, and pending queue messages
- Cascades to all sub-orchestrations automatically
- Requires `force = true` for running instances
- Returns counts of deleted resources

**Errors:**
- `instance_still_running`: Instance is running and `force = false`
- `cannot_delete_sub_orchestration`: Must delete from root instance
- `instance_not_found`: Instance doesn't exist

### 2. Delete Instances (Bulk)

```sql
-- Delete specific instances by ID
SELECT * FROM df.delete_instances(
    instance_ids => ARRAY['inst-1', 'inst-2', 'inst-3']
);

-- Delete instances completed more than 7 days ago (retention policy)
SELECT * FROM df.delete_instances(
    completed_before => NOW() - INTERVAL '7 days',
    max_count => 500
);

-- Combine filters (AND logic)
SELECT * FROM df.delete_instances(
    completed_before => NOW() - INTERVAL '30 days',
    max_count => 1000
);
```

**Function Signature:**
```sql
CREATE FUNCTION df.delete_instances(
    instance_ids TEXT[] DEFAULT NULL,
    completed_before TIMESTAMPTZ DEFAULT NULL,
    max_count INTEGER DEFAULT 1000
) RETURNS TABLE (
    instances_deleted BIGINT,
    executions_deleted BIGINT,
    events_deleted BIGINT,
    queue_messages_deleted BIGINT
);
```

**Behavior:**
- Only deletes instances in terminal states (Completed, Failed)
- Running instances are silently skipped
- All filter criteria are ANDed together

### 3. Get Instance Tree (Preview Deletion Impact)

```sql
-- Preview what will be deleted
SELECT * FROM df.instance_tree('my-root-instance');
```

**Function Signature:**
```sql
CREATE FUNCTION df.instance_tree(
    instance_id TEXT
) RETURNS TABLE (
    root_id TEXT,
    descendant_id TEXT,
    tree_size INTEGER
);
```

**Returns:**
- One row per instance in the tree (root + all sub-orchestrations)
- `tree_size` shows total count (same on all rows for convenience)

### 4. Prune Executions

For long-running workflows using `ContinueAsNew` that accumulate many executions:

```sql
-- Keep only the last 10 executions
SELECT * FROM df.prune_executions(
    instance_id => 'eternal-workflow',
    keep_last => 10
);

-- Prune executions older than 30 days
SELECT * FROM df.prune_executions(
    instance_id => 'eternal-workflow',
    completed_before => NOW() - INTERVAL '30 days'
);

-- Both criteria (AND logic)
SELECT * FROM df.prune_executions(
    instance_id => 'eternal-workflow',
    keep_last => 5,
    completed_before => NOW() - INTERVAL '7 days'
);
```

**Function Signature:**
```sql
CREATE FUNCTION df.prune_executions(
    instance_id TEXT,
    keep_last INTEGER DEFAULT NULL,
    completed_before TIMESTAMPTZ DEFAULT NULL
) RETURNS TABLE (
    instances_processed BIGINT,
    executions_deleted BIGINT,
    events_deleted BIGINT
);
```

**Safety Guarantees:**
- The **current execution is NEVER pruned** regardless of options
- Safe to call on running workflows
- `keep_last = NULL` (or 0 or 1) all prune to current execution only

### 5. Prune Executions (Bulk)

```sql
-- Prune all instances: keep last 10 executions each
SELECT * FROM df.prune_executions_bulk(
    keep_last => 10,
    max_count => 100
);

-- Prune specific instances
SELECT * FROM df.prune_executions_bulk(
    instance_ids => ARRAY['workflow-1', 'workflow-2'],
    keep_last => 5
);
```

**Function Signature:**
```sql
CREATE FUNCTION df.prune_executions_bulk(
    instance_ids TEXT[] DEFAULT NULL,
    completed_before TIMESTAMPTZ DEFAULT NULL,
    keep_last INTEGER DEFAULT NULL,
    prune_before TIMESTAMPTZ DEFAULT NULL,
    max_count INTEGER DEFAULT 1000
) RETURNS TABLE (
    instances_processed BIGINT,
    executions_deleted BIGINT,
    events_deleted BIGINT
);
```

### 6. Reset System Orchestrations

Administrative function to reset all internal system orchestrations (sync-state, future monitoring orchestrations, etc.):

```sql
-- Reset all system orchestrations
SELECT * FROM df.reset_system();

-- Reset with timeout for cancel (default 5 seconds)
SELECT * FROM df.reset_system(cancel_timeout_secs => 10);
```

**Function Signature:**
```sql
CREATE FUNCTION df.reset_system(
    cancel_timeout_secs INTEGER DEFAULT 5
) RETURNS TABLE (
    orchestration_name TEXT,
    action_taken TEXT,      -- 'cancelled', 'force_deleted', 'restarted', 'failed'
    success BOOLEAN
);
```

**Behavior:**
1. Enumerate all system orchestrations (instances with `pg_durable::` prefix)
2. For each orchestration:
   - Try `cancel_instance()` and wait up to `cancel_timeout_secs`
   - If cancel times out or fails, `delete_instance(force=true)`
   - Restart the orchestration via internal start function
3. Return status for each orchestration

**Use Cases:**
- Recovery from stuck system orchestrations
- After duroxide/pg_durable upgrades
- Troubleshooting sync issues

**System Orchestrations (current and planned):**
| ID | Purpose |
|----|---------|
| `pg_durable::sync-state::singleton` | Background state reconciliation |
| `pg_durable::metrics::singleton` | (future) Metrics collection |
| `pg_durable::cleanup::singleton` | (future) Automated retention policy |

---

## Implementation Plan

### Phase 1: Core Functions (Priority)

1. **`df.delete_instance()`** - Single instance deletion with force option
2. **`df.instance_tree()`** - Preview deletion impact
3. **`df.reset_system()`** - Reset system orchestrations

### Phase 2: Bulk Operations

4. **`df.delete_instances()`** - Bulk deletion with filters
5. **`df.prune_executions()`** - Single instance pruning

### Phase 3: Advanced

6. **`df.prune_executions_bulk()`** - Bulk pruning
7. **Background sync orchestration** - Continuous reconciliation

### File Changes

| File | Changes |
|------|---------|
| `src/monitoring.rs` | Add new `#[pg_extern]` functions |
| `src/orchestrations/sync_state.rs` | Background sync orchestration |
| `src/activities/find_orphans.rs` | Activity to find orphan duroxide instances |
| `tests/e2e/sql/XX_delete_instance.sql` | E2E test for deletion |
| `tests/e2e/sql/XX_prune_executions.sql` | E2E test for pruning |
| `tests/e2e/sql/XX_reset_system.sql` | E2E test for system reset |
| `USER_GUIDE.md` | Document new management functions |
| `docs/api-reference.md` | API reference updates |

### Example Implementation (delete_instance)

```rust
/// Delete a durable function instance and all associated data.
/// 
/// Flow: Check preconditions → Delete df.* → Delete duroxide.*
/// If duroxide deletion fails, background sync will reconcile.
#[pg_extern(schema = "df")]
pub fn delete_instance(
    instance_id: &str,
    force: default!(bool, "false"),
) -> TableIterator<
    'static,
    (
        name!(instances_deleted, i64),
        name!(executions_deleted, i64),
        name!(events_deleted, i64),
        name!(queue_messages_deleted, i64),
    ),
> {
    let pg_conn_str = postgres_connection_string();
    let instance_id = instance_id.to_string();

    // Block system orchestration deletion
    if instance_id.starts_with("pg_durable::") {
        warning!("Cannot delete system orchestration: {}", instance_id);
        return TableIterator::new(vec![]);
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            warning!("Failed to create tokio runtime: {}", e);
            return TableIterator::new(vec![]);
        }
    };

    let results = rt.block_on(async {
        let store = match PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA)).await {
            Ok(s) => Arc::new(s),
            Err(e) => {
                warning!("Failed to connect to duroxide store: {}", e);
                return vec![];
            }
        };

        let client = Client::new(store);

        // Step 1: Validate preconditions
        match client.get_instance(&instance_id).await {
            Ok(info) => {
                // Cannot delete sub-orchestrations directly
                if info.parent_id.is_some() {
                    warning!(
                        "Cannot delete sub-orchestration '{}'. Delete root instance instead.",
                        instance_id
                    );
                    return vec![];
                }
                // Running instances require force=true
                if !force && matches!(info.status, InstanceStatus::Running | InstanceStatus::Pending) {
                    warning!(
                        "Instance '{}' is {}. Use force=true to delete running instances.",
                        instance_id, info.status
                    );
                    return vec![];
                }
            }
            Err(e) => {
                warning!("Instance '{}' not found: {:?}", instance_id, e);
                return vec![];
            }
        }

        // Preconditions passed - proceed with deletion
        vec![(instance_id.clone(), force)]
    });

    if results.is_empty() {
        return TableIterator::new(vec![]);
    }

    // Step 2: Delete from df.* tables FIRST (source of truth)
    let _ = Spi::run(&format!(
        "DELETE FROM df.nodes WHERE instance_id = '{}'",
        instance_id.replace('\'', "''")
    ));
    let _ = Spi::run(&format!(
        "DELETE FROM df.instances WHERE id = '{}'",
        instance_id.replace('\'', "''")
    ));

    // Step 3: Delete from duroxide (if this fails, background sync will clean up)
    let final_results = rt.block_on(async {
        let store = match PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA)).await {
            Ok(s) => Arc::new(s),
            Err(e) => {
                warning!("duroxide delete failed (will be reconciled by sync): {}", e);
                return vec![(1i64, 0i64, 0i64, 0i64)]; // df.* deleted, duroxide pending
            }
        };

        let client = Client::new(store);
        
        match client.delete_instance(&instance_id, force).await {
            Ok(result) => vec![(
                result.instances_deleted as i64,
                result.executions_deleted as i64,
                result.events_deleted as i64,
                result.queue_messages_deleted as i64,
            )],
            Err(e) => {
                warning!("duroxide delete failed (will be reconciled by sync): {:?}", e);
                vec![(1i64, 0i64, 0i64, 0i64)] // df.* deleted, duroxide pending
            }
        }
    });

    TableIterator::new(final_results)
}
```

### Example Implementation (reset_system)

```rust
/// Known system orchestration IDs
const SYSTEM_ORCHESTRATIONS: &[(&str, &str)] = &[
    ("pg_durable::sync-state::singleton", "sync-state"),
    // Future: ("pg_durable::metrics::singleton", "metrics"),
    // Future: ("pg_durable::cleanup::singleton", "cleanup"),
];

/// Reset all system orchestrations: cancel → force delete → restart
#[pg_extern(schema = "df")]
pub fn reset_system(
    cancel_timeout_secs: default!(i32, "5"),
) -> TableIterator<
    'static,
    (
        name!(orchestration_name, String),
        name!(action_taken, String),
        name!(success, bool),
    ),
> {
    let pg_conn_str = postgres_connection_string();
    let timeout = std::time::Duration::from_secs(cancel_timeout_secs.max(1) as u64);

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            warning!("Failed to create tokio runtime: {}", e);
            return TableIterator::new(vec![]);
        }
    };

    let results = rt.block_on(async {
        let store = match PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA)).await {
            Ok(s) => Arc::new(s),
            Err(e) => {
                warning!("Failed to connect to duroxide store: {}", e);
                return vec![];
            }
        };

        let client = Client::new(store.clone());
        let mut results = Vec::new();

        for (instance_id, name) in SYSTEM_ORCHESTRATIONS {
            let mut action = "none";
            let mut success = true;

            // Step 1: Check if running
            let is_running = match client.get_instance(instance_id).await {
                Ok(info) => matches!(info.status, InstanceStatus::Running | InstanceStatus::Pending),
                Err(_) => false, // Not found, nothing to cancel
            };

            if is_running {
                // Step 2: Try graceful cancel
                action = "cancelled";
                if let Err(_) = client.cancel_instance(instance_id, "system reset").await {
                    // Cancel failed, will force delete
                }

                // Wait for cancellation with timeout
                let start = std::time::Instant::now();
                loop {
                    if start.elapsed() > timeout {
                        break;
                    }
                    match client.get_instance(instance_id).await {
                        Ok(info) if !matches!(info.status, InstanceStatus::Running | InstanceStatus::Pending) => {
                            break; // Successfully cancelled
                        }
                        _ => tokio::time::sleep(std::time::Duration::from_millis(100)).await,
                    }
                }

                // Step 3: Check if still running, force delete if needed
                let still_running = match client.get_instance(instance_id).await {
                    Ok(info) => matches!(info.status, InstanceStatus::Running | InstanceStatus::Pending),
                    Err(_) => false,
                };

                if still_running {
                    action = "force_deleted";
                    if let Err(e) = client.delete_instance(instance_id, true).await {
                        warning!("Failed to force delete {}: {:?}", instance_id, e);
                        success = false;
                    }
                }
            }

            // Step 4: Restart the orchestration
            if success {
                action = if action == "none" { "restarted" } else { action };
                if let Err(e) = start_system_orchestration(&client, instance_id, name).await {
                    warning!("Failed to restart {}: {:?}", instance_id, e);
                    action = "failed";
                    success = false;
                } else {
                    action = "restarted";
                }
            }

            results.push((name.to_string(), action.to_string(), success));
        }

        results
    });

    TableIterator::new(results)
}

/// Start a system orchestration by name
async fn start_system_orchestration(
    client: &Client,
    instance_id: &str,
    _name: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // System orchestrations are started with empty input
    // The orchestration name is derived from the instance_id pattern
    let orchestration_name = match instance_id {
        "pg_durable::sync-state::singleton" => "pg_durable::orchestration::sync-state",
        // Future orchestrations here
        _ => return Err("Unknown system orchestration".into()),
    };
    
    client.start_orchestration(
        instance_id,
        orchestration_name,
        serde_json::json!({}),
    ).await?;
    
    Ok(())
}
```

---

## Usage Patterns

### Retention Policy (Cron Job)

```sql
-- Run daily to clean up old completed instances
SELECT * FROM df.delete_instances(
    completed_before => NOW() - INTERVAL '30 days',
    max_count => 10000
);
```

### Graceful Instance Cleanup

```sql
-- Cancel first, wait, then delete
SELECT df.cancel('stuck-instance', 'Admin cleanup');
-- Wait for cancellation...
SELECT pg_sleep(5);
SELECT * FROM df.delete_instance('stuck-instance');

-- Or force delete if truly stuck
SELECT * FROM df.delete_instance('stuck-instance', force => true);
```

### Execution History Maintenance

```sql
-- For eternal workflows, keep history manageable
SELECT * FROM df.prune_executions('eternal-poller', keep_last => 100);
```

### Pre-Deletion Audit

```sql
-- Check what will be deleted
SELECT * FROM df.instance_tree('parent-workflow');
-- Returns: parent-workflow, child-1, child-2, etc.
```

### Reset System Orchestrations

```sql
-- Reset all system orchestrations (useful after upgrades or when stuck)
SELECT * FROM df.reset_system();

-- Example output:
--  orchestration_name |  action_taken  | success
-- --------------------+----------------+---------
--  sync-state         | restarted      | t

-- With longer timeout for graceful cancel
SELECT * FROM df.reset_system(cancel_timeout_secs => 30);
```

---

## Consistency Between `df.*` and `duroxide.*` Tables

### The Problem

pg_durable maintains two storage layers:
- **`df.instances`, `df.nodes`** - User-facing metadata, function graph (source of truth)
- **`duroxide.*`** - Runtime state (history, executions, queues)

These must stay in sync. The design principle: **`df.instances` is the source of truth**. If a row exists in `duroxide.*` but not in `df.instances`, it should be cleaned up.

### Solution: Delete-First with Background Reconciliation

#### 1. Deletion Flow in `df.delete_instance()`

The deletion order is intentional: **first df.*, then duroxide.***

```rust
// In df.delete_instance():

// 1. PRE-CHECK: Validate preconditions that would make duroxide delete fail
//    This prevents leaving df.* deleted but duroxide.* intact
let status = client.get_instance(&instance_id).await?;
if !force && status.is_running() {
    return Err("Instance is running. Use force=true to delete running instances.");
}
if status.parent_id.is_some() {
    return Err("Cannot delete sub-orchestration. Delete the root instance instead.");
}

// 2. DELETE from df.* tables (source of truth)
Spi::run(&format!("DELETE FROM df.nodes WHERE instance_id = '{}'", instance_id));
Spi::run(&format!("DELETE FROM df.instances WHERE id = '{}'", instance_id));

// 3. DELETE from duroxide via Client API
//    If this fails, background sync will clean it up later
let result = client.delete_instance(&instance_id, force).await;
match result {
    Ok(r) => return Ok(r),
    Err(e) => {
        // Log warning - background sync will reconcile
        warning!("duroxide delete failed (will be reconciled): {}", e);
        return Ok(DeleteResult::pending_reconciliation());
    }
}
```

**Why this order?**
- `df.instances` is the source of truth for "what should exist"
- If duroxide deletion fails, background sync will force-delete it
- If we deleted duroxide first and df.* deletion failed, we'd lose user data

#### 2. Background Sync Orchestration (Reconciliation)

An eternal orchestration runs in the background worker, ensuring duroxide state matches df.instances:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  pg_durable::orchestration::sync-state (eternal singleton)               │
│                                                                          │
│   ┌───────────────┐    ┌───────────────┐    ┌─────────┐                 │
│   │ Find Orphan   │───►│ Force Delete  │───►│ Sleep   │───┐             │
│   │ Duroxide Inst │    │ via Client    │    │ 5 min   │   │             │
│   └───────────────┘    └───────────────┘    └─────────┘   │             │
│          ▲                                                │             │
│          └──────────── ContinueAsNew ◄────────────────────┘             │
└──────────────────────────────────────────────────────────────────────────┘
```

**Reconciliation Logic:**

```sql
-- Find duroxide instances with no matching df.instances entry
SELECT di.instance_id
FROM duroxide.instances di
LEFT JOIN df.instances dfi ON di.instance_id = dfi.id
WHERE dfi.id IS NULL
  AND di.instance_id NOT LIKE 'pg_durable::%'  -- Exclude system orchestrations
  AND di.parent_id IS NULL;                     -- Only root instances
```

For each orphan found:
```rust
// Force delete - the df.instances entry is already gone
client.delete_instance(&orphan_id, true).await?;
```

**Key behaviors:**
- **Singleton pattern**: Only one instance runs (ID: `pg_durable::sync-state::singleton`)
- **Auto-start**: Worker starts it if not running
- **ContinueAsNew**: Keeps execution history bounded (every 100 iterations)
- **Force delete**: Always uses `force=true` since we're cleaning up orphans
- **Root-only**: Deletes root instances; sub-orchestrations cascade automatically

**Activities:**
- `find-orphan-duroxide-instances`: Query for duroxide instances without df.instances
- `force-delete-duroxide-instance`: Call `client.delete_instance(id, force=true)`
- `cleanup-orphan-df-nodes`: Delete `df.nodes` with no parent `df.instances` (defensive)

**User control:**
```sql
SELECT * FROM df.sync_status();        -- Check last run, next run, orphans found
SELECT df.sync_now();                  -- Trigger immediate sync
SELECT df.set_sync_interval('10 min'); -- Change interval (default: 5 min)
SELECT df.disable_sync();              -- Stop background sync
```

#### 3. Precondition Checks

The `df.delete_instance()` precondition check queries duroxide state:

| Check | How | Error if Fails |
|-------|-----|----------------|
| Instance exists | `client.get_instance()` | "Instance not found" |
| Not running (unless force) | Check status | "Instance is running. Use force=true" |
| Not a sub-orchestration | Check parent_id | "Cannot delete sub-orchestration. Delete root instance." |
| Not a system orchestration | Check ID prefix | "Cannot delete system orchestration" |

```rust
async fn validate_delete_preconditions(
    client: &Client,
    instance_id: &str,
    force: bool,
) -> Result<(), String> {
    // Block deletion of system orchestrations
    if instance_id.starts_with("pg_durable::") {
        return Err("Cannot delete system orchestration".into());
    }
    
    let info = client.get_instance(instance_id).await
        .map_err(|_| format!("Instance '{}' not found", instance_id))?;
    
    // Must delete from root
    if info.parent_id.is_some() {
        return Err(format!(
            "Cannot delete sub-orchestration '{}'. Delete root instance '{}' instead.",
            instance_id,
            info.root_id.unwrap_or_default()
        ));
    }
    
    // Running instances require force
    if !force && matches!(info.status, InstanceStatus::Running | InstanceStatus::Pending) {
        return Err(format!(
            "Instance '{}' is {}. Use force=true to delete running instances.",
            instance_id, info.status
        ));
    }
    
    Ok(())
}
```

#### 4. On-Demand Verification

```sql
-- Diagnostic: find inconsistencies without fixing
SELECT * FROM df.verify_consistency();

-- Returns:
--   orphan_duroxide_instances: duroxide entries without df.instances
--   orphan_df_nodes: df.nodes without parent df.instances  
--   total_df_instances: count in df.instances
--   total_duroxide_instances: count in duroxide.instances
```

### System Orchestration Convention

System orchestrations (like sync-state) use the `pg_durable::` prefix and are:
- **Exempt from cleanup**: Queries filter `WHERE instance_id NOT LIKE 'pg_durable::%'`
- **Cannot be user-deleted**: `df.delete_instance()` rejects them
- **Not tracked in df.instances**: They're internal, started directly by worker
- **Self-managing**: duroxide's `prune_executions` handles their history

---

## Security Considerations

1. **Privilege Requirements**: These are destructive operations - should require appropriate PostgreSQL roles
2. **Force Delete Warning**: Force-deleting running instances only removes database state; in-flight tokio tasks may continue until worker notices
3. **Audit Trail**: Consider logging deletions for compliance (could add to `df.audit_log` table in future)

---

## Open Questions

1. **Should force-delete first cancel the instance?** Duroxide recommends `cancel_instance` first for graceful termination. Should `df.delete_instance(..., force => true)` automatically cancel first?

2. **Should we add a `df.cleanup()` convenience function?** A single function that runs retention policy cleanup:
   ```sql
   SELECT * FROM df.cleanup(
       retention_days => 30,
       keep_executions => 10
   );
   ```

3. **Naming consistency**: Should we use `df.delete_instances` (plural) or `df.delete_instances_bulk`?

4. **Error handling**: Should errors raise exceptions or return empty results with warnings? Current monitoring functions return empty results; destructive operations might warrant exceptions.

---

## Timeline Estimate

| Phase | Effort | Description |
|-------|--------|-------------|
| Phase 1 | 2-3 days | Core delete + tree functions |
| Phase 2 | 2 days | Bulk operations |
| Phase 3 | 1 day | Bulk pruning |
| Testing | 2 days | E2E tests for all scenarios |
| Docs | 1 day | User guide and API reference |

**Total: ~8-10 days**

---

## References

- [duroxide Client API (docs.rs)](https://docs.rs/duroxide/0.1.11/duroxide/client/struct.Client.html)
- [duroxide management types](https://docs.rs/duroxide/0.1.11/duroxide/providers/management/index.html)
- Current pg_durable monitoring: [src/monitoring.rs](../src/monitoring.rs)
