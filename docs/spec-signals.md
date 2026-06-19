# Signals Specification

## Overview

Signals allow external code to send events to running durable functions, enabling human-in-the-loop workflows, webhook callbacks, approval processes, and event-driven orchestration.

## API

### DSL Function: Wait for Signal

```sql
-- Wait forever
df.wait_for_signal('signal_name')

-- Wait with timeout (seconds)
df.wait_for_signal('signal_name', 3600)  -- 1 hour timeout
```

### SQL Function: Send Signal

```sql
-- Send signal to a running instance
SELECT df.signal('instance_id', 'signal_name', '{"data": "value"}');
SELECT df.signal('instance_id', 'signal_name', 'approve');
```

**Parameters:**
- `instance_id` - The durable function instance ID (labels not supported, not unique)
- `signal_name` - Name of the signal to send
- `signal_data` - Optional text payload (defaults to `'{}'`). Valid JSON is preserved as structured JSON; non-JSON text is delivered as a JSON string.

Send a JSON object when workflow SQL expects structured fields such as `data.approved`. Send plain text for simple opaque values such as `approve`.

## Signal Result Format

The `df.wait_for_signal()` function returns a JSON object:

**Signal received:**
```json
{
  "signal_name": "approval",
  "timed_out": false,
  "data": {"approved": true, "approver": "jane@acme.com"}
}
```

**Signal received with plain text payload:**
```json
{
    "signal_name": "approval",
    "timed_out": false,
    "data": "approve"
}
```

**Timeout (when timeout_seconds specified):**
```json
{
  "signal_name": "approval",
  "timed_out": true,
  "data": null
}
```

## Usage Examples

### Basic Signal Wait

```sql
SELECT df.start(
    'SELECT id FROM orders WHERE id = 1' |=> 'order'
    ~> df.wait_for_signal('approval') |=> 'sig'
    ~> 'INSERT INTO audit_log VALUES ($order.id, $sig::jsonb->''data''->>''approver'')',
    'order-approval'
);

-- Later, send the signal
SELECT df.signal('a1b2c3d4', 'approval', '{"approved": true, "approver": "jane"}');
```

### Signal with Timeout

```sql
SELECT df.start(
    'SELECT id FROM orders WHERE id = 1' |=> 'order'
    ~> df.wait_for_signal('approval', 86400) |=> 'sig'  -- 24 hour timeout
    ~> df.if(
        'SELECT NOT ($sig::jsonb->>''timed_out'')::boolean',
        -- Signal received
        df.if(
            'SELECT ($sig::jsonb->''data''->>''approved'')::boolean',
            'UPDATE orders SET status = ''approved'' WHERE id = $order.id',
            'UPDATE orders SET status = ''rejected'' WHERE id = $order.id'
        ),
        -- Timed out
        'UPDATE orders SET status = ''expired'' WHERE id = $order.id'
    ),
    'order-with-timeout'
);
```

### Multi-Party Approval

```sql
SELECT df.start(
    'SELECT id FROM documents WHERE id = 1' |=> 'doc'
    ~> df.join3(
        df.wait_for_signal('legal_approval'),
        df.wait_for_signal('tech_approval'),
        df.wait_for_signal('mgmt_approval')
    ) |=> 'approvals'
    ~> 'UPDATE documents SET status = ''approved'' WHERE id = $doc.id',
    'multi-approval'
);

-- Each approver sends their signal
SELECT df.signal('...', 'legal_approval', '{"approved": true}');
SELECT df.signal('...', 'tech_approval', '{"approved": true}');
SELECT df.signal('...', 'mgmt_approval', '{"approved": true}');
```

### Webhook Callback Pattern

```sql
-- Start a job and wait for external callback
SELECT df.start(
    df.http('{job_api}/start', 'POST', '{"type": "render"}') |=> 'job'
    ~> df.wait_for_signal('job_complete', 3600) |=> 'result'
    ~> df.if(
        'SELECT NOT ($result::jsonb->>''timed_out'')::boolean',
        'INSERT INTO completed_jobs VALUES ($job, $result)',
        'INSERT INTO failed_jobs VALUES ($job, ''timeout'')'
    ),
    'webhook-job'
);

-- External system calls back via API or direct SQL
-- POST /api/signal/{instance_id}/job_complete  -> calls df.signal()
```

---

## Implementation

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  User SQL Session                                           │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ SELECT df.signal('inst123', 'approval', '{}');      │    │
│  │   ↓                                                 │    │
│  │ raise_external_event() → Duroxide store             │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Duroxide Store (PostgreSQL)                                │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ duroxide.work_items: ExternalRaised event queued    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Background Worker (Orchestration)                          │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ ctx.schedule_wait("approval").into_event().await    │    │
│  │   ↓                                                 │    │
│  │ Returns signal data, orchestration continues        │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### No Additional Tables

Duroxide handles all event tracking internally via its history/event log. No `df.pending_signals` or `df.received_signals` tables needed.

### DSL Function Implementation

```rust
// src/dsl.rs

#[pg_extern(schema = "df")]
pub fn wait_for_signal(name: &str, timeout_seconds: default!(Option<i32>, "NULL")) -> String {
    let config = serde_json::json!({
        "signal_name": name,
        "timeout_seconds": timeout_seconds
    });
    
    let durofut = Durofut {
        node_id: short_id(),
        node_type: "SIGNAL".to_string(),
        query: Some(config.to_string()),
        result_name: None,
        left_node: None,
        right_node: None,
    };
    durofut.insert_node();
    durofut.to_json()
}
```

### Runtime: SIGNAL Node Handler

```rust
// src/runtime.rs - in execute_node_inner

"signal" => {
    let config_str = node.query.as_ref()
        .ok_or_else(|| format!("SIGNAL node {} has no config", node_id))?;
    
    let config: serde_json::Value = serde_json::from_str(config_str)
        .map_err(|e| format!("Invalid signal config: {}", e))?;
    
    let signal_name = config["signal_name"].as_str()
        .ok_or("Missing signal_name")?;
    let timeout_seconds = config["timeout_seconds"].as_i64();
    
    ctx.trace_info(format!("Waiting for signal: {}", signal_name));
    
    // Use Duroxide's built-in external event API
    let result = if let Some(timeout_secs) = timeout_seconds {
        // Race between signal and timeout using select2
        let signal_fut = ctx.schedule_wait(signal_name);
        let timeout_fut = ctx.schedule_timer(
            std::time::Duration::from_secs(timeout_secs as u64)
        );
        
        match duroxide::select2(signal_fut, timeout_fut).await {
            duroxide::Either::Left(data) => {
                // Signal received
                serde_json::json!({
                    "signal_name": signal_name,
                    "timed_out": false,
                    "data": serde_json::from_str::<serde_json::Value>(&data)
                        .unwrap_or(serde_json::Value::Null)
                })
            }
            duroxide::Either::Right(_) => {
                // Timeout
                serde_json::json!({
                    "signal_name": signal_name,
                    "timed_out": true,
                    "data": null
                })
            }
        }
    } else {
        // Wait forever
        let data = ctx.schedule_wait(signal_name).into_event().await;
        serde_json::json!({
            "signal_name": signal_name,
            "timed_out": false,
            "data": serde_json::from_str::<serde_json::Value>(&data)
                .unwrap_or(serde_json::Value::Null)
        })
    };
    
    // Store result if named
    if let Some(name) = &node.result_name {
        results.insert(name.clone(), result.to_string());
    }
    
    Ok(result.to_string())
}
```

### SQL Function: df.signal()

```rust
// src/dsl.rs

#[pg_extern(schema = "df")]
pub fn signal(
    instance_id: &str,
    signal_name: &str,
    signal_data: default!(&str, "'{}'")
) -> String {
    use crate::runtime::raise_external_event;
    
    match raise_external_event(instance_id, signal_name, signal_data) {
        Ok(_) => "OK".to_string(),
        Err(e) => pgrx::error!("Failed to signal: {}", e),
    }
}
```

### Helper: Raise Event from SQL Context

```rust
// src/runtime.rs

use std::sync::Arc;
use tokio::runtime::Runtime;

/// Raise an external event to a running orchestration.
/// Called from df.signal() SQL function in user's session.
pub fn raise_external_event(
    instance_id: &str, 
    event_name: &str, 
    data: &str
) -> Result<(), String> {
    let conn_str = postgres_connection_string();
    
    // Create tokio runtime to run async code from sync SQL context
    let rt = Runtime::new()
        .map_err(|e| format!("Failed to create runtime: {}", e))?;
    
    rt.block_on(async {
        let store = duroxide_pg::PostgresProvider::new_with_schema(
            &conn_str, 
            Some(DUROXIDE_SCHEMA)
        )
        .await
        .map_err(|e| format!("Failed to connect to store: {}", e))?;
        
        let client = duroxide::Client::new(Arc::new(store));
        
        client.raise_event(instance_id, event_name, data)
            .await
            .map_err(|e| format!("Failed to raise event: {}", e))
    })
}
```

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Signal to non-existent instance | Error from Duroxide client |
| Signal to completed instance | Error: instance not active |
| Signal name not being waited for | Event queued, delivered when/if waited |
| Timeout before signal | Returns `{"timed_out": true, "data": null}` |
| Multiple signals same name | First one delivered, others queued |

---

## Test Plan

### Unit Tests

```rust
// src/lib.rs

#[pg_test]
fn test_wait_for_signal_creates_valid_node() {
    let json = crate::dsl::wait_for_signal("approval", None);
    let fut = Durofut::from_json(&json);
    assert_eq!(fut.node_type, "SIGNAL");
    
    let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
    assert_eq!(config["signal_name"], "approval");
    assert!(config["timeout_seconds"].is_null());
}

#[pg_test]
fn test_wait_for_signal_with_timeout() {
    let json = crate::dsl::wait_for_signal("approval", Some(3600));
    let fut = Durofut::from_json(&json);
    
    let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
    assert_eq!(config["signal_name"], "approval");
    assert_eq!(config["timeout_seconds"], 3600);
}

#[pg_test]
fn test_signal_via_sql() {
    let result = Spi::get_one::<String>(
        "SELECT df.wait_for_signal('test_signal')"
    ).unwrap().unwrap();
    
    let fut = Durofut::from_json(&result);
    assert_eq!(fut.node_type, "SIGNAL");
}

#[pg_test]
fn test_signal_with_timeout_via_sql() {
    let result = Spi::get_one::<String>(
        "SELECT df.wait_for_signal('test_signal', 60)"
    ).unwrap().unwrap();
    
    let fut = Durofut::from_json(&result);
    let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
    assert_eq!(config["timeout_seconds"], 60);
}
```

### E2E Tests

#### Test File: `tests/e2e/sql/21_signals.sql`

```sql
-- E2E Test: Signals
-- Tests df.wait_for_signal() and df.signal() functionality

-- ============================================================================
-- Setup
-- ============================================================================

DROP TABLE IF EXISTS signal_test_log;
CREATE TABLE signal_test_log (
    id SERIAL PRIMARY KEY,
    msg TEXT,
    data JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================================
-- Test 1: Basic Signal Send/Receive
-- ============================================================================

CREATE TEMP TABLE _test_signal_basic (instance_id TEXT);

INSERT INTO _test_signal_basic SELECT df.start(
    'SELECT 1' |=> 'start'
    ~> df.wait_for_signal('go') |=> 'sig'
    ~> 'INSERT INTO signal_test_log (msg, data) 
        VALUES (''received'', $sig::jsonb)',
    'test-signal-basic'
);

-- Wait a moment for workflow to start and reach wait state
SELECT pg_sleep(1);

-- Send the signal
DO $$
DECLARE
    inst_id TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_basic;
    PERFORM df.signal(inst_id, 'go', '{"value": 42}');
    RAISE NOTICE 'Sent signal to %', inst_id;
END $$;

-- Wait for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_basic;
    RAISE NOTICE 'Testing basic signal: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: basic signal status = %', status;
    END IF;
    
    -- Verify signal data was received
    IF NOT EXISTS (
        SELECT 1 FROM signal_test_log 
        WHERE msg = 'received' 
        AND (data->>'timed_out')::boolean = false
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: signal data not logged correctly';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: signal_basic';
END $$;

DROP TABLE _test_signal_basic;
DELETE FROM signal_test_log;

-- ============================================================================
-- Test 2: Signal Timeout
-- ============================================================================

CREATE TEMP TABLE _test_signal_timeout (instance_id TEXT);

INSERT INTO _test_signal_timeout SELECT df.start(
    df.wait_for_signal('never_arrives', 2) |=> 'sig'  -- 2 second timeout
    ~> 'INSERT INTO signal_test_log (msg, data) 
        VALUES (''timeout_result'', $sig::jsonb)',
    'test-signal-timeout'
);

-- Wait for timeout (should take ~2 seconds)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_timeout;
    RAISE NOTICE 'Testing signal timeout: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 50;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: signal timeout status = %', status;
    END IF;
    
    -- Verify timed_out flag is true
    IF NOT EXISTS (
        SELECT 1 FROM signal_test_log 
        WHERE msg = 'timeout_result' 
        AND (data->>'timed_out')::boolean = true
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: timeout not recorded correctly';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: signal_timeout';
END $$;

DROP TABLE _test_signal_timeout;
DELETE FROM signal_test_log;

-- ============================================================================
-- Test 3: Signal with Data
-- ============================================================================

CREATE TEMP TABLE _test_signal_data (instance_id TEXT);

INSERT INTO _test_signal_data SELECT df.start(
    df.wait_for_signal('approval') |=> 'sig'
    ~> 'INSERT INTO signal_test_log (msg, data) 
        VALUES (
            ''approval_received'', 
            jsonb_build_object(
                ''approved'', ($sig::jsonb->''data''->>''approved'')::boolean,
                ''approver'', $sig::jsonb->''data''->>''approver''
            )
        )',
    'test-signal-data'
);

SELECT pg_sleep(1);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_signal_data;
    
    -- Send signal with data
    PERFORM df.signal(inst_id, 'approval', '{"approved": true, "approver": "jane@acme.com"}');
    RAISE NOTICE 'Testing signal with data: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: signal data status = %', status;
    END IF;
    
    -- Verify data was extracted correctly
    IF NOT EXISTS (
        SELECT 1 FROM signal_test_log 
        WHERE msg = 'approval_received' 
        AND (data->>'approved')::boolean = true
        AND data->>'approver' = 'jane@acme.com'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: signal data not extracted correctly';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: signal_data';
END $$;

DROP TABLE _test_signal_data;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP TABLE signal_test_log;

SELECT 'ALL SIGNAL TESTS PASSED' AS result;
```

---

## Documentation Updates

### USER_GUIDE.md Addition

Add new section after "Durable Function Variables":

```markdown
## Signals

Signals allow external code to send events to running durable functions. This enables:
- Human-in-the-loop approval workflows
- Webhook callbacks from external systems
- Event-driven coordination between processes

### Waiting for a Signal

```sql
-- Wait forever
df.wait_for_signal('signal_name')

-- Wait with timeout (seconds)
df.wait_for_signal('signal_name', 3600)  -- 1 hour
```

### Sending a Signal

```sql
SELECT df.signal('instance_id', 'signal_name', '{"data": "value"}');
```

### Signal Result Format

```json
{
  "signal_name": "approval",
  "timed_out": false,
  "data": {"approved": true}
}
```

### Example: Order Approval

```sql
SELECT df.start(
    'SELECT id, total FROM orders WHERE id = 1' |=> 'order'
    ~> df.wait_for_signal('approval', 86400) |=> 'sig'
    ~> df.if(
        'SELECT NOT ($sig::jsonb->>''timed_out'')::boolean 
            AND ($sig::jsonb->''data''->>''approved'')::boolean',
        'UPDATE orders SET status = ''approved'' WHERE id = $order.id',
        'UPDATE orders SET status = ''rejected'' WHERE id = $order.id'
    ),
    'order-approval'
);

-- Approve the order
SELECT df.signal('a1b2c3d4', 'approval', '{"approved": true}');
```
```

### DSL Reference Table Addition

| Function | Description | Example |
|----------|-------------|---------|
| `df.wait_for_signal(name)` | Wait for external signal | `df.wait_for_signal('approval')` |
| `df.wait_for_signal(name, timeout)` | Wait with timeout (seconds) | `df.wait_for_signal('approval', 3600)` |
| `df.signal(instance_id, name, data)` | Send signal to instance | `df.signal('a1b2', 'go', '{}')` |

---

## Implementation Checklist

- [x] Add `df.wait_for_signal()` DSL function
- [x] Add SIGNAL node type to `Durofut`
- [x] Add SIGNAL handler in `execute_node_inner`
- [x] Add `df.signal()` SQL function
- [x] Add `raise_external_event()` helper
- [x] Add unit tests
- [x] Add E2E test file `21_signals.sql`
- [x] Update USER_GUIDE.md
- [x] Update DSL Reference table
- [x] Add to Quick Reference Card

**Implementation completed: December 2024**
