# SPI Implementation Notes

**Date**: 2026-01-13  
**Branch**: feat/spi (or copilot/add-spi-implementation)  
**Spec**: docs/spec-security-model.md

## Overview

This document describes the implementation of SPI-based SQL execution with security context switching in pg_durable. The implementation provides privilege isolation for user SQL by executing it with the submitting user's privileges, not the background worker's privileges.

## Architecture

### Two Execution Planes

The background worker now operates with two separate database connections:

1. **Execution Plane (SPI)**: For executing user SQL with proper privilege isolation
   - Connected via `BackgroundWorker::connect_worker_to_spi()`
   - Used exclusively by `execute_sql` activity
   - Supports `SetUserIdAndSecContext()` for privilege switching

2. **Control Plane (sqlx)**: For duroxide job state management
   - Connected via PostgreSQL connection pool
   - Used by: `load_function_graph`, `update_instance_status`, `update_node_status`
   - Runs with worker's ambient privileges

## Key Components

### 1. Security Context Capture

**Location**: `src/types.rs`

```rust
pub struct SecurityContext {
    pub user_oid: u32,         // From GetUserId() - unforgeable
    pub user_name: String,      // For logging/debugging
    pub search_path: String,    // Restored during execution
    pub is_superuser: bool,     // For audit purposes
}
```

**Captured at**: `df.start()` call time in user's backend process
**Stored in**: `df.instances.security_context` (JSONB column)

### 2. Schema Changes

**Location**: `src/lib.rs`

```sql
CREATE TABLE df.instances (
    ...
    submitted_by OID NOT NULL DEFAULT current_user::regrole::oid,
    security_context JSONB NOT NULL DEFAULT '{}'::jsonb,
    ...
);
```

- `submitted_by`: OID of the user who called `df.start()`
- `security_context`: Full security context as JSON

### 3. Background Worker SPI Connection

**Location**: `src/worker.rs`

```rust
pub extern "C-unwind" fn duroxide_worker_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(...);
    
    // Connect to SPI for executing user SQL
    BackgroundWorker::connect_worker_to_spi(Some("postgres"), None);
    
    // Initialize tokio runtime (single-threaded)
    let rt = tokio::runtime::Builder::new_current_thread()...
}
```

### 4. Execute SQL with Security Context

**Location**: `src/activities/execute_sql.rs`

#### Flow:

1. **Parse Input**: Extract `instance_id` and `query` from JSON input
2. **Acquire SPI Lock**: Prevent concurrent SPI access
3. **Load Security Context**: Query `df.instances` for security_context
4. **Switch Context**: Call `SetUserIdAndSecContext(user_oid, SECURITY_LOCAL_USERID_CHANGE)`
5. **Execute SQL**: Run user query via `Spi::connect()`
6. **Restore Context**: RAII guard ensures restoration even on error/panic

#### Key Safety Features:

- **SPI_LOCK**: Global `Mutex` prevents concurrent SPI operations
- **RAII Guard**: `ContextGuard` struct with `Drop` implementation ensures context restoration
- **Search Path**: Restored to match user's session
- **1-based Indexing**: SPI rows use 1-based column indexing

```rust
static SPI_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

struct ContextGuard(pg_sys::Oid, i32);
impl Drop for ContextGuard {
    fn drop(&mut self) {
        unsafe { pg_sys::SetUserIdAndSecContext(self.0, self.1); }
    }
}
```

### 5. Orchestration Changes

**Location**: `src/orchestrations/execute_function_graph.rs`

Changed from:
```rust
ctx.schedule_activity(activities::execute_sql::NAME, final_query)
```

To:
```rust
let input = serde_json::json!({
    "instance_id": sys_vars.instance_id,
    "query": final_query
});
ctx.schedule_activity(activities::execute_sql::NAME, input.to_string())
```

## Security Properties

### Achieved

✅ **Privilege Isolation**: User SQL runs with submitting user's privileges  
✅ **Escape Prevention**: `RESET ROLE` / `SET ROLE` cannot escalate privileges  
✅ **Context Restoration**: RAII guard ensures context always restored  
✅ **Unforgeable Identity**: User OID from `GetUserId()` cannot be spoofed  
✅ **Single-threaded Safety**: SPI lock + current-thread runtime  

### Not Implemented (Out of Scope)

❌ Row-Level Security (RLS) on df.instances  
❌ HTTP activity security (SSRF protection, allowlists)  
❌ Workflow variables (df.vars) RLS isolation  
❌ Secrets management (df.secrets)  

## Code Paths

### User Session → df.start()
```
User SQL Session
  ↓
df.start(query, label)
  ↓
SecurityContext::capture()  [GetUserId(), current_user, search_path]
  ↓
INSERT INTO df.instances (submitted_by, security_context, ...)
  ↓
duroxide Client.start_orchestration()
```

### Background Worker → execute_sql
```
duroxide Runtime
  ↓
execute_function_graph orchestration
  ↓
execute_sql_node() → schedule_activity(execute_sql)
  ↓
execute_sql activity
  ↓
SPI_LOCK.lock()
  ↓
load_security_context(instance_id)  [query df.instances]
  ↓
execute_sql_with_security_context()
  ├─ Save current context (worker's)
  ├─ Switch: SetUserIdAndSecContext(user_oid, SECURITY_LOCAL_USERID_CHANGE)
  ├─ Execute user SQL via Spi::connect()
  └─ Restore: ContextGuard.drop() → SetUserIdAndSecContext(saved)
```

## Testing Strategy

### Unit Tests (Recommended)

1. **SecurityContext::capture()**: Verify captures correct user_oid
2. **Context Switch**: Test `SetUserIdAndSecContext` saves/restores properly
3. **RAII Guard**: Verify context restored even on panic

### E2E Tests (Critical)

Based on spec-security-model.md Section 10:

- **E2E-SEC-01**: Basic privilege isolation (user A can't access user B's tables)
- **E2E-SEC-02**: RESET ROLE escape prevention
- **E2E-SEC-03**: SET ROLE escalation prevention
- **E2E-SEC-11**: execute_sql error path (returns Err, worker continues)
- **E2E-SEC-12**: execute_sql panic + restart (duroxide resumes)

### Manual Testing

```sql
-- Create two users
CREATE USER alice;
CREATE USER bob;
GRANT EXECUTE ON FUNCTION df.start TO alice, bob;
GRANT EXECUTE ON FUNCTION df.sql TO alice, bob;

-- Alice creates a table
SET ROLE alice;
CREATE TABLE alice_data (secret text);
INSERT INTO alice_data VALUES ('alice secret');

-- Alice can access her table via df
SELECT df.start(df.sql('SELECT * FROM alice_data'), 'alice-job');
-- Should complete successfully

-- Bob tries to access Alice's table
SET ROLE bob;
SELECT df.start(df.sql('SELECT * FROM alice_data'), 'bob-attack');
-- Should fail with "permission denied for table alice_data"
```

## Dependencies

**Added**:
- `once_cell = "1.19"` (for SPI_LOCK)

**No changes to**:
- pgrx (still 0.16.1)
- sqlx (still used for control plane)
- duroxide / duroxide-pg-opt (unchanged)

## Known Limitations

1. **Single-threaded SPI**: Only one SPI operation at a time (head-of-line blocking)
2. **No cross-database**: Security context is per-database
3. **SECURITY DEFINER**: Calling df.start() from SECURITY DEFINER function captures definer's identity (documented behavior)
4. **No RLS**: Users can see all instances in df.instances (would need additional RLS implementation)

## Future Work

1. **RLS on df.instances**: Add row-level security policies
2. **Multiple workers**: Run N background workers to avoid head-of-line blocking
3. **HTTP security**: Implement SSRF protection and URL allowlists
4. **Subtransactions**: Wrap user SQL in savepoints for better error isolation
5. **Audit logging**: Log all privilege escalations and SECURITY DEFINER invocations

## References

- **Spec**: `docs/spec-security-model.md`
- **Architecture**: `docs/ARCHITECTURE.md`
- **PostgreSQL Internals**:
  - `src/backend/utils/init/miscinit.c`: SetUserIdAndSecContext
  - `src/backend/executor/spi.c`: SPI implementation
  - `src/include/utils/acl.h`: Permission checking

## Commit History

1. Initial SPI implementation with security context
2. Fix SPI row indexing (1-based)
