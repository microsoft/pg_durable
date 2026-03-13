# Long-Polling Design Session: LLM-Assisted Architecture Refinement

> This document captures the iterative design process between a developer and an LLM (GitHub Copilot/Claude) to design a long-polling system for a PostgreSQL-backed durable task framework. It demonstrates how to use an LLM as a design partner to explore, refine, and validate architectural decisions.

**Date:** December 16, 2025  
**Context:** duroxide-pg - A Rust PostgreSQL provider for durable task orchestration

---

## Session Overview

The goal was to reduce idle database query load from ~160 queries/second to near-zero using PostgreSQL's LISTEN/NOTIFY mechanism, while maintaining precise timer handling for delayed work items.

---

## Part 1: Starting Point - Simplification Request

### User
> "the optimized polling document has too many moving parts, simplify"

### LLM Response
Proposed a simpler architecture with the core principle:

**"Notifier is smart. Dispatchers are dumb."**

- Single notifier thread handles all LISTEN/NOTIFY and timer management
- Dispatchers just fetch, wait for wake signal, fetch again
- No complex coordination between dispatchers

---

## Part 2: Clock Source Analysis

### User
> Questioned whether timestamps were coming from the database or Rust

### LLM Analysis
Discovered mixed clock sources in the codebase:
- Some stored procedures used `NOW()` (database clock)
- Some timestamps came from Rust's `SystemTime::now()`

### Key Insight
> "The PostgreSQL database **never** generates timestamps via `NOW()` or `CURRENT_TIMESTAMP`. This ensures a single clock source, avoiding subtle bugs from clock skew between application servers and the database server."

### Resulting Changes
1. Created migration to update all stored procedures to accept `p_now_ms BIGINT` parameter
2. Updated all provider calls to pass `Self::now_millis()`
3. Removed all `DEFAULT CURRENT_TIMESTAMP` from schema
4. Enforced `NOT NULL` on all timestamp columns

---

## Part 3: Timer Grace Period Discussion

### User
> "how will the timer_grace_period help with the clock skew between nodes?"

### Initial LLM Explanation (INCORRECT)
Explained grace period helps when notifier node's clock is ahead of the node that created the timer:

```
Node A (creates timer):  clock = T+0
  → sets visible_at = T+5

Node B (notifier):       clock = T+0.1 (100ms ahead)
  → schedules wake for T+5
  → fires at T+5 (Node B's clock)
  → but Node A's clock is only at T+4.9
```

### User Challenge
> "node B's notifier and dispatchers have the same clock. if the message says it is visible at T+5, node B which is ahead by 0.1s will schedule a 4.9s timer instead of a 5s timer. And then upon firing, the dispatcher will wake up and compare current time which will be T+5 (even on node B) with the message time which will also be T+5 and should technically just work?"

### LLM Correction
> "You're absolutely right. The epoch timestamp is the anchor. Each node calculates the correct delay for its own clock perspective. **It just works.**"

Realized the grace period doesn't help with inter-node clock skew at all - the design is inherently resilient because:
- Timestamps are absolute epoch values
- Each node's notifier and dispatchers share the same clock
- The math works out regardless of skew

### User Refinement
> "So the dangerous part is if the dispatcher, for whatever reason wakes up before T+5, e.g at maybe T+4.99, the query it lands would miss the message at T+5. So the actual grace period needs to be added to the computed delay."

### Final Correct Implementation
```rust
// CORRECT: Add grace to the DELAY, not to visible_at
let delay_ms = (visible_at_ms - now_ms) + grace_period_ms;
let fire_at = Instant::now() + Duration::from_millis(delay_ms);
```

NOT:
```rust
// WRONG: Adding grace to absolute time
let fire_at_ms = visible_at_ms + grace_period_ms;
```

---

## Part 4: Database Clock Cleanup

### User
> "the refresh query has NOW(), so it is using the database clock which isn't right per what we discussed. scan through the proposal and weed out any database based timers"

### LLM Action
Found and fixed refresh queries that were using `NOW()`:

**Before:**
```sql
WHERE visible_at > NOW()
  AND visible_at <= $1
```

**After:**
```sql
WHERE (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT > $1
  AND (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT <= $2
```

Both `$1` (now_ms) and `$2` (window_end_ms) come from Rust clock.

---

## Part 5: Code Reuse Discussion

### User
> "is handle_reconnect code any different from the first time connection code or are we going to reuse it?"

### LLM Analysis
Identified that both paths need:
1. `PgListener::connect_with(&pool)`
2. `.listen("{schema}_orch_work")`
3. `.listen("{schema}_worker_work")`

Proposed shared helper:
```rust
async fn subscribe_channels(&mut self) -> Result<(), Error> {
    self.pg_listener
        .listen(&format!("{}_orch_work", self.schema_name))
        .await?;
    self.pg_listener
        .listen(&format!("{}_worker_work", self.schema_name))
        .await?;
    Ok(())
}
```

With:
- `new()` calls `subscribe_channels()`
- `handle_reconnect()` calls sleep + reconnect + `subscribe_channels()` + wake all

---

## Part 6: Fetch Timeout Behavior

### User
> "fetch_orchestration_item -> if it timeouts then return to the caller i.e the runtime, it will reissue the fetch after idle sleep time and the first thing the fetch will do is do_fetch() again"

### LLM Correction
Changed from:
```rust
select! {
    _ = notify.notified() => { }
    _ = sleep(poll_timeout) => { }
}
// Always fetch after select
return self.do_fetch_orchestration_item(lock_timeout).await;
```

To:
```rust
select! {
    _ = notify.notified() => {
        // Woken by notifier - fetch now
        return self.do_fetch_orchestration_item(lock_timeout).await;
    }
    _ = sleep(poll_timeout) => {
        // Timeout - return None, let runtime handle idle sleep
        // Next call will do_fetch() as first step anyway
        return Ok(None);
    }
}
```

---

## Part 7: Test Coverage Gap

### User
> "need a test in which the visible_at is T-5 as well, it should be processed immediately"

### LLM Action
Added test case:
```
| notify_past_visible_at_wakes_immediately | Notifier running | NOTIFY with visible_at = now - 5s | notify_waiters() called immediately (already visible) |
```

---

## Part 8: Precision Discussion

### User
> "what's the overall precision of the time"

### LLM Analysis
Traced the full chain:
1. **Rust**: `SystemTime::now()` → `duration.as_millis() as i64` → **ms precision**
2. **To PostgreSQL**: `TO_TIMESTAMP(p_now_ms / 1000.0)` → converts ms back to timestamp
3. **PostgreSQL storage**: `TIMESTAMPTZ` has **microsecond** precision internally
4. **From PostgreSQL**: `(EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT` → back to **ms**

**Conclusion:** Millisecond precision (limited by Rust conversion), which is plenty for duroxide timers where the 100ms grace period dwarfs any sub-ms concerns.

---

## Part 9: Default Configuration

### User
> "ok but lets set the default to true"

### LLM Action
Changed `LongPollConfig::default()`:
```rust
Self {
    enabled: true,  // Changed from false
    notifier_poll_interval: Duration::from_secs(60),
    timer_grace_period: Duration::from_millis(100),
}
```

---

## Key Lessons from This Session

### 1. Challenge Assumptions
The user caught an incorrect explanation about clock skew. The LLM's initial reasoning was plausible but wrong - the user's domain knowledge corrected it.

### 2. Trace Data Flow
Understanding timestamp precision required tracing through Rust → PostgreSQL → Rust conversions.

### 3. Consistency Matters
Finding `NOW()` in the refresh query while claiming "no database clocks" showed the importance of systematic review.

### 4. Simplify Redundancy
The timeout → fetch again pattern was redundant since the next call would fetch anyway.

### 5. Edge Cases in Tests
Adding the T-5 (past visible_at) test case ensures immediate processing is covered.

---

## Artifacts Produced

1. **LONG_POLLING_DESIGN.md** - Complete design document with:
   - Architecture diagrams
   - Rust code snippets
   - SQL triggers
   - Test plan

2. **Migration updates** - Consolidated single migration with:
   - All timestamps from Rust clock
   - NOT NULL constraints without defaults
   - Stored procedures accepting `p_now_ms`

3. **Implementation plan** - Phased approach:
   - Phase 1: Database triggers
   - Phase 2: Core infrastructure
   - Phase 3: Dispatcher integration
   - Phase 4-5: Unit and integration tests
   - Phase 6: Stabilization
   - Future: Resilience, performance, stress tests

---

## Next Steps

Ready to implement Phase 1: Add NOTIFY triggers to the migration.
