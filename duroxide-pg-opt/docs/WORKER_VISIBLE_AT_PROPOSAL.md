# Proposal: Add `visible_at` to Worker Queue

## Problem

Currently the worker queue uses `created_at` for NOTIFY payloads, but abandoned items with retry delays should have future visibility. This causes:

1. **Immediate NOTIFY wake-ups** for items that shouldn't be fetched yet
2. **Inconsistent handling** between orchestrator and worker queues
3. **Wasted poll cycles** - dispatchers wake up only to find no visible work

### Current Behavior

```sql
-- Worker queue has no visible_at column
CREATE TABLE worker_queue (
    id BIGSERIAL PRIMARY KEY,
    work_item TEXT NOT NULL,
    lock_token TEXT,
    locked_until BIGINT,
    created_at TIMESTAMPTZ NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0
);

-- Trigger uses created_at (always in the past)
PERFORM pg_notify(TG_TABLE_SCHEMA || '_worker_work',
    (EXTRACT(EPOCH FROM NEW.created_at) * 1000)::BIGINT::TEXT);
```

When `abandon_work_item` is called with a delay, the item keeps its lock until `locked_until` expires. But:
- No NOTIFY fires for the delayed re-visibility
- The notifier can't schedule a timer for when the item becomes available

---

## Proposed Changes

### 1. Database Schema

Add `visible_at` column to `worker_queue`:

```sql
-- In worker_queue table definition
CREATE TABLE worker_queue (
    id BIGSERIAL PRIMARY KEY,
    work_item TEXT NOT NULL,
    visible_at TIMESTAMPTZ NOT NULL,  -- NEW: when item becomes fetchable
    lock_token TEXT,
    locked_until BIGINT,
    created_at TIMESTAMPTZ NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0
);

-- Update index to include visible_at
CREATE INDEX IF NOT EXISTS idx_worker_available 
    ON worker_queue(visible_at, lock_token, id);
```

### 2. Trigger Function

Update `notify_worker_work()` to use `visible_at`:

```sql
CREATE OR REPLACE FUNCTION notify_worker_work()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        TG_TABLE_SCHEMA || '_worker_work',
        (EXTRACT(EPOCH FROM NEW.visible_at) * 1000)::BIGINT::TEXT
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### 3. Stored Procedures

#### `enqueue_worker_work`

Set `visible_at` to NOW():

```sql
CREATE OR REPLACE FUNCTION enqueue_worker_work(
    p_work_item TEXT,
    p_now_ms BIGINT
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO worker_queue (work_item, visible_at, created_at)
    VALUES (
        p_work_item, 
        TO_TIMESTAMP(p_now_ms / 1000.0),  -- visible_at = now
        TO_TIMESTAMP(p_now_ms / 1000.0)
    );
END;
$$ LANGUAGE plpgsql;
```

#### `fetch_work_item`

Filter by visibility:

```sql
SELECT q.id INTO v_id
FROM worker_queue q
WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)  -- NEW: visibility check
  AND (q.lock_token IS NULL OR q.locked_until <= p_now_ms)
ORDER BY q.visible_at, q.id  -- Order by visible_at first
LIMIT 1
FOR UPDATE OF q SKIP LOCKED;
```

#### `abandon_work_item`

Update `visible_at` instead of just `locked_until`:

```sql
CREATE OR REPLACE FUNCTION abandon_work_item(
    p_lock_token TEXT,
    p_now_ms BIGINT,
    p_delay_ms BIGINT DEFAULT NULL,
    p_ignore_attempt BOOLEAN DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
    v_visible_at TIMESTAMPTZ;
BEGIN
    IF p_delay_ms IS NOT NULL AND p_delay_ms > 0 THEN
        v_visible_at := TO_TIMESTAMP((p_now_ms + p_delay_ms) / 1000.0);
    ELSE
        v_visible_at := TO_TIMESTAMP(p_now_ms / 1000.0);
    END IF;
    
    UPDATE worker_queue
    SET lock_token = NULL,
        locked_until = NULL,
        visible_at = v_visible_at,
        attempt_count = CASE 
            WHEN p_ignore_attempt THEN GREATEST(0, attempt_count - 1)
            ELSE attempt_count
        END
    WHERE lock_token = p_lock_token;
    
    -- ... error handling
END;
$$ LANGUAGE plpgsql;
```

#### `ack_orchestration_item`

Update worker item insertion to include `visible_at`:

```sql
-- In the worker_items insertion section
INSERT INTO worker_queue (work_item, visible_at, created_at)
SELECT elem::TEXT, v_now_ts, v_now_ts
FROM JSONB_ARRAY_ELEMENTS(p_worker_items) AS elem;
```

### 4. Notifier Refresh Query

Update to query worker queue for future timers:

```rust
// In src/notifier.rs, maybe_start_refresh()

// Currently:
let worker_timers: Vec<i64> = Vec::new();

// Change to:
let worker_timers = sqlx::query_scalar::<_, i64>(&format!(
    "SELECT (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT
     FROM {}.worker_queue
     WHERE (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT > $1
       AND (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT <= $2
       AND lock_token IS NULL",
    schema
))
.bind(now_ms)
.bind(window_end_ms)
.fetch_all(&pool)
.await
.unwrap_or_default();
```

---

## Migration Strategy

Create new migration file: `0005_add_worker_visible_at.sql`

```sql
-- Add visible_at column with default for existing rows
ALTER TABLE worker_queue 
ADD COLUMN IF NOT EXISTS visible_at TIMESTAMPTZ;

-- Backfill existing rows
UPDATE worker_queue 
SET visible_at = created_at 
WHERE visible_at IS NULL;

-- Make NOT NULL after backfill
ALTER TABLE worker_queue 
ALTER COLUMN visible_at SET NOT NULL;

-- Update index
DROP INDEX IF EXISTS idx_worker_available;
CREATE INDEX idx_worker_available ON worker_queue(visible_at, lock_token, id);

-- Then recreate all affected stored procedures...
```

For fresh installs, update `0001_initial_schema.sql` directly.

---

## Files to Modify

| File | Change |
|------|--------|
| `migrations/0001_initial_schema.sql` | Add `visible_at` column, update trigger, update all worker procedures |
| `migrations/0005_add_worker_visible_at.sql` | New migration for existing deployments |
| `src/notifier.rs` | Add worker queue to refresh query |

---

## Testing

1. Unit tests for notifier with worker timers
2. Integration test: abandon with delay, verify fetch respects visibility
3. E2E test: activity retry with backoff, verify timing

---

## Benefits

1. **Consistent behavior** - Both queues handle delayed visibility the same way
2. **Proper long-poll integration** - Notifier can schedule timers for delayed worker items
3. **Reduced wasted polls** - No wake-ups for items that aren't visible yet
4. **Correct NOTIFY payloads** - Reflects actual visibility, not creation time
