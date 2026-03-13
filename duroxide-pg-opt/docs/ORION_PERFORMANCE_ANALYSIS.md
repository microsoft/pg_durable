# Orion/Horizon DB vs Azure PostgreSQL Performance Analysis

**Date:** December 18, 2025  
**Purpose:** Compare database latency characteristics between Azure PostgreSQL and Orion/Horizon DB to understand timer precision test failures.

## Executive Summary

Testing revealed significant performance differences between the two databases:

| Issue | Impact |
|-------|--------|
| **Cold-start latency** | Orion: 200-500ms first operation vs Azure: ~25ms |
| **Per-operation latency** | Orion: ~55ms vs Azure: ~27ms (2x slower) |
| **DDL operations** | Orion: 2-3x slower for CREATE/DROP TABLE |
| **Cumulative effect** | 20 INSERTs take ~1.2s on Orion vs ~0.5s on Azure |

This explains why the `timer_precision_under_load` test fails with ~1800ms error on Orion DB.

---

## Test Environment

### Database Connections

| Database | Connection String |
|----------|------------------|
| **Azure PostgreSQL** | `postgresql://affandar:***@duroxide-pg-westus.postgres.database.azure.com:5432/postgres` |
| **Orion/Horizon DB** | `postgresql://horizonadmin:***@adar-duroxide-hdb-westus3.ee706b367a1e.westus3.oriondb.azure.com:5432/postgres` |

### Test Client
- macOS client running from local machine
- psql command-line client with `\timing on`

---

## Test 1: Server-Side Batch Inserts (PL/pgSQL)

This test measures server-side performance by executing batch INSERTs inside PL/pgSQL DO blocks, which minimizes network round-trip overhead.

### Script: `/tmp/db_perf_test_large.sql`

```sql
\timing on
\echo '=== WARMUP ==='
DROP TABLE IF EXISTS perf_test;
CREATE TABLE perf_test (id SERIAL PRIMARY KEY, data TEXT, visible_at TIMESTAMPTZ, created_at TIMESTAMPTZ DEFAULT NOW());

\echo '=== BATCH 1: 50 INSERTs ==='
DO $$
DECLARE
    start_time TIMESTAMPTZ := clock_timestamp();
    end_time TIMESTAMPTZ;
BEGIN
    FOR i IN 1..50 LOOP
        INSERT INTO perf_test (data, visible_at) VALUES ('item' || i, NOW() + (i * INTERVAL '100 milliseconds'));
    END LOOP;
    end_time := clock_timestamp();
    RAISE NOTICE 'Batch 1 (50 inserts): % ms', EXTRACT(MILLISECOND FROM (end_time - start_time)) + EXTRACT(SECOND FROM (end_time - start_time)) * 1000;
END $$;

\echo '=== BATCH 2: 50 INSERTs ==='
DO $$
DECLARE
    start_time TIMESTAMPTZ := clock_timestamp();
    end_time TIMESTAMPTZ;
BEGIN
    FOR i IN 51..100 LOOP
        INSERT INTO perf_test (data, visible_at) VALUES ('item' || i, NOW() + (i * INTERVAL '100 milliseconds'));
    END LOOP;
    end_time := clock_timestamp();
    RAISE NOTICE 'Batch 2 (50 inserts): % ms', EXTRACT(MILLISECOND FROM (end_time - start_time)) + EXTRACT(SECOND FROM (end_time - start_time)) * 1000;
END $$;

\echo '=== BATCH 3: 50 INSERTs ==='
DO $$
DECLARE
    start_time TIMESTAMPTZ := clock_timestamp();
    end_time TIMESTAMPTZ;
BEGIN
    FOR i IN 101..150 LOOP
        INSERT INTO perf_test (data, visible_at) VALUES ('item' || i, NOW() + (i * INTERVAL '100 milliseconds'));
    END LOOP;
    end_time := clock_timestamp();
    RAISE NOTICE 'Batch 3 (50 inserts): % ms', EXTRACT(MILLISECOND FROM (end_time - start_time)) + EXTRACT(SECOND FROM (end_time - start_time)) * 1000;
END $$;

\echo '=== SELECT Tests ==='
SELECT COUNT(*) FROM perf_test;
SELECT MIN(created_at), MAX(created_at), MAX(created_at) - MIN(created_at) as total_insert_span FROM perf_test;

\echo '=== FETCH Simulation (20 SELECTs with WHERE) ==='
DO $$
DECLARE
    start_time TIMESTAMPTZ := clock_timestamp();
    end_time TIMESTAMPTZ;
    result RECORD;
BEGIN
    FOR i IN 1..20 LOOP
        SELECT * INTO result FROM perf_test WHERE visible_at <= NOW() AND id = i LIMIT 1;
    END LOOP;
    end_time := clock_timestamp();
    RAISE NOTICE '20 SELECT queries: % ms', EXTRACT(MILLISECOND FROM (end_time - start_time)) + EXTRACT(SECOND FROM (end_time - start_time)) * 1000;
END $$;

DROP TABLE perf_test;
```

### Results: Azure PostgreSQL (3 runs)

```
=== RUN 1 ===
CREATE TABLE: 35.186 ms
Batch 1 (50 inserts): 4.120 ms (server-side)
Batch 2 (50 inserts): 1.464 ms (server-side)
Batch 3 (50 inserts): 1.792 ms (server-side)
20 SELECT queries: 1.160 ms (server-side)
DROP TABLE: 30.952 ms

=== RUN 2 ===
CREATE TABLE: 30.886 ms
Batch 1 (50 inserts): 3.724 ms (server-side)
Batch 2 (50 inserts): 1.870 ms (server-side)
Batch 3 (50 inserts): 1.706 ms (server-side)
20 SELECT queries: 0.890 ms (server-side)
DROP TABLE: 27.537 ms

=== RUN 3 ===
CREATE TABLE: 32.630 ms
Batch 1 (50 inserts): 3.440 ms (server-side)
Batch 2 (50 inserts): 1.532 ms (server-side)
Batch 3 (50 inserts): 2.074 ms (server-side)
20 SELECT queries: 1.310 ms (server-side)
DROP TABLE: 31.998 ms
```

### Results: Orion/Horizon DB (3 runs)

```
=== RUN 1 ===
CREATE TABLE: 87.968 ms
Batch 1 (50 inserts): 501.014 ms (server-side) ❌ COLD START
Batch 2 (50 inserts): 0.868 ms (server-side)
Batch 3 (50 inserts): 0.992 ms (server-side)
20 SELECT queries: 0.528 ms (server-side)
DROP TABLE: 109.619 ms

=== RUN 2 ===
CREATE TABLE: 93.237 ms
Batch 1 (50 inserts): 209.896 ms (server-side) ❌ COLD START
Batch 2 (50 inserts): 0.798 ms (server-side)
Batch 3 (50 inserts): 0.950 ms (server-side)
20 SELECT queries: 0.594 ms (server-side)
DROP TABLE: 106.866 ms

=== RUN 3 ===
CREATE TABLE: 96.645 ms
Batch 1 (50 inserts): 280.526 ms (server-side) ❌ COLD START
Batch 2 (50 inserts): 0.770 ms (server-side)
Batch 3 (50 inserts): 0.934 ms (server-side)
20 SELECT queries: 0.504 ms (server-side)
DROP TABLE: 105.732 ms
```

### Test 1 Analysis

| Metric | Azure PostgreSQL | Orion/Horizon DB | Ratio |
|--------|------------------|------------------|-------|
| **Batch 1 (cold)** | 3.4-4.1 ms | **210-501 ms** | 50-150x ❌ |
| **Batch 2-3 (warm)** | 1.5-2.1 ms | 0.8-1.0 ms | 0.5x ✅ |
| **20 SELECTs** | 0.9-1.3 ms | 0.5-0.6 ms | 0.5x ✅ |
| **CREATE TABLE** | 31-35 ms | 88-97 ms | 2.8x |
| **DROP TABLE** | 28-32 ms | 106-110 ms | 3.5x |

**Key Finding:** Orion DB has a massive **cold-start penalty** (200-500ms) on the first batch of operations. Once warm, server-side operations are actually slightly faster than Azure PostgreSQL. However, DDL operations are 2.8-3.5x slower.

---

## Test 2: Realistic Duroxide Pattern (Individual INSERTs)

This test simulates the actual duroxide-pg pattern where each INSERT is a separate client round-trip, which is how the provider actually operates.

### Script: `/tmp/db_perf_realistic.sql`

```sql
\timing on
\echo '=== SETUP ==='
DROP TABLE IF EXISTS perf_test;
CREATE TABLE perf_test (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    queue_name TEXT NOT NULL,
    data JSONB,
    visible_at TIMESTAMPTZ NOT NULL,
    lock_token UUID,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_perf_visible ON perf_test(queue_name, visible_at) WHERE lock_token IS NULL;

\echo ''
\echo '=== WARMUP: Single INSERT ==='
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": "warmup"}', NOW());

\echo ''
\echo '=== 20 Individual INSERTs (simulating enqueue operations) ==='
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 1}', NOW() + INTERVAL '100 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 2}', NOW() + INTERVAL '200 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 3}', NOW() + INTERVAL '300 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 4}', NOW() + INTERVAL '400 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 5}', NOW() + INTERVAL '500 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 6}', NOW() + INTERVAL '600 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 7}', NOW() + INTERVAL '700 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 8}', NOW() + INTERVAL '800 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 9}', NOW() + INTERVAL '900 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 10}', NOW() + INTERVAL '1000 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 11}', NOW() + INTERVAL '1100 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 12}', NOW() + INTERVAL '1200 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 13}', NOW() + INTERVAL '1300 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 14}', NOW() + INTERVAL '1400 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 15}', NOW() + INTERVAL '1500 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 16}', NOW() + INTERVAL '1600 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 17}', NOW() + INTERVAL '1700 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 18}', NOW() + INTERVAL '1800 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 19}', NOW() + INTERVAL '1900 milliseconds');
INSERT INTO perf_test (queue_name, data, visible_at) VALUES ('test-queue', '{"msg": 20}', NOW() + INTERVAL '2000 milliseconds');

\echo ''
\echo '=== FETCH Operations (SELECT + UPDATE pattern like duroxide) ==='
-- Simulating fetch_work_items: SELECT visible items, then UPDATE to lock
SELECT id, data FROM perf_test WHERE queue_name = 'test-queue' AND visible_at <= NOW() AND lock_token IS NULL ORDER BY visible_at LIMIT 5;
UPDATE perf_test SET lock_token = gen_random_uuid() WHERE id IN (SELECT id FROM perf_test WHERE queue_name = 'test-queue' AND visible_at <= NOW() AND lock_token IS NULL ORDER BY visible_at LIMIT 5);

SELECT id, data FROM perf_test WHERE queue_name = 'test-queue' AND visible_at <= NOW() AND lock_token IS NULL ORDER BY visible_at LIMIT 5;
UPDATE perf_test SET lock_token = gen_random_uuid() WHERE id IN (SELECT id FROM perf_test WHERE queue_name = 'test-queue' AND visible_at <= NOW() AND lock_token IS NULL ORDER BY visible_at LIMIT 5);

SELECT id, data FROM perf_test WHERE queue_name = 'test-queue' AND visible_at <= NOW() AND lock_token IS NULL ORDER BY visible_at LIMIT 5;
UPDATE perf_test SET lock_token = gen_random_uuid() WHERE id IN (SELECT id FROM perf_test WHERE queue_name = 'test-queue' AND visible_at <= NOW() AND lock_token IS NULL ORDER BY visible_at LIMIT 5);

\echo ''
\echo '=== Final Stats ==='
SELECT COUNT(*) as remaining_items FROM perf_test;

DROP TABLE perf_test;
```

### Results: Azure PostgreSQL

```
=== SETUP ===
DROP TABLE: 24.248 ms
CREATE TABLE: 41.696 ms
CREATE INDEX: 29.879 ms

=== WARMUP: Single INSERT ===
INSERT 0 1: 24.685 ms

=== 20 Individual INSERTs ===
INSERT 1:  25.867 ms
INSERT 2:  27.363 ms
INSERT 3:  27.618 ms
INSERT 4:  25.777 ms
INSERT 5:  27.467 ms
INSERT 6:  26.504 ms
INSERT 7:  26.652 ms
INSERT 8:  46.107 ms  (outlier)
INSERT 9:  27.177 ms
INSERT 10: 28.161 ms
INSERT 11: 34.116 ms
INSERT 12: 28.399 ms
INSERT 13: 30.757 ms
INSERT 14: 26.677 ms
INSERT 15: 29.116 ms
INSERT 16: 24.257 ms
INSERT 17: 26.039 ms
INSERT 18: 27.327 ms
INSERT 19: 27.063 ms
INSERT 20: 26.401 ms

=== FETCH Operations ===
SELECT: 29.228 ms
UPDATE: 23.814 ms
SELECT: 25.313 ms
UPDATE: 24.121 ms
SELECT: 25.188 ms
UPDATE: 22.855 ms
```

### Results: Orion/Horizon DB

```
=== SETUP ===
DROP TABLE: 51.038 ms
CREATE TABLE: 91.982 ms
CREATE INDEX: 54.465 ms

=== WARMUP: Single INSERT ===
INSERT 0 1: 208.916 ms  ❌ COLD START

=== 20 Individual INSERTs ===
INSERT 1:  64.029 ms
INSERT 2:  58.081 ms
INSERT 3:  53.611 ms
INSERT 4:  54.417 ms
INSERT 5:  53.071 ms
INSERT 6:  53.805 ms
INSERT 7:  54.132 ms
INSERT 8:  53.046 ms
INSERT 9:  54.980 ms
INSERT 10: 49.890 ms
INSERT 11: 53.119 ms
INSERT 12: 54.471 ms
INSERT 13: 53.545 ms
INSERT 14: 54.808 ms
INSERT 15: 61.985 ms
INSERT 16: 54.403 ms
INSERT 17: 54.489 ms
INSERT 18: 57.757 ms
INSERT 19: 49.988 ms
INSERT 20: 52.358 ms

=== FETCH Operations ===
SELECT: 61.997 ms
UPDATE: 49.666 ms
SELECT: 52.741 ms
UPDATE: 51.822 ms
SELECT: 57.579 ms
UPDATE: 59.156 ms
```

### Test 2 Analysis

| Metric | Azure PostgreSQL | Orion/Horizon DB | Ratio |
|--------|------------------|------------------|-------|
| **Warmup INSERT** | 25 ms | **209 ms** | 8.4x ❌ |
| **Individual INSERT avg** | 27 ms | **55 ms** | 2.0x |
| **Individual INSERT min** | 24 ms | 50 ms | 2.1x |
| **Individual INSERT max** | 46 ms | 64 ms | 1.4x |
| **SELECT (fetch)** | 25-29 ms | 52-62 ms | 2.0x |
| **UPDATE (lock)** | 23-24 ms | 50-59 ms | 2.1x |
| **CREATE TABLE** | 42 ms | 92 ms | 2.2x |
| **CREATE INDEX** | 30 ms | 54 ms | 1.8x |

**Key Finding:** Every individual operation on Orion DB takes approximately **2x longer** than Azure PostgreSQL due to network latency. The cold-start penalty adds an additional ~200ms on the first operation.

---

## Impact on `timer_precision_under_load` Test

The test performs 20 individual INSERT operations before starting to fetch items:

### Cumulative INSERT Time

| Database | Calculation | Total Time |
|----------|-------------|------------|
| **Azure PostgreSQL** | 20 × 27ms | **~540ms** |
| **Orion/Horizon DB** | 209ms (cold) + 19 × 55ms | **~1,254ms** |

### Why the Test Fails

The test measures timing error as `actual_delivery_time - expected_visible_at_time`.

1. All 20 items are scheduled with `visible_at` times relative to the start of the insert loop
2. On Orion DB, the insert loop takes ~1.2 seconds to complete
3. By the time the first item is fetched, it's already ~1.2 seconds late
4. Each subsequent item inherits this delay, plus additional fetch latency

**Test Result:** p95 error of **1857ms** on Orion DB vs **214ms** on Azure PostgreSQL.

---

## Conclusions

### Root Causes

1. **Cold-Start Latency**: Orion DB exhibits 200-500ms latency on the first operation after idle periods, likely due to:
   - Connection pool warm-up
   - Query plan caching
   - Storage layer initialization

2. **Network Latency**: Base round-trip time to Orion DB is ~55ms vs ~25ms for Azure PostgreSQL (2x difference)

3. **DDL Overhead**: Schema operations (CREATE/DROP) are 2-3.5x slower on Orion DB

### Recommendations

1. **Connection Warming**: Implement a warmup query on provider initialization to absorb the cold-start penalty

2. **Batch Operations**: Where possible, use batch INSERTs instead of individual operations (server-side batching shows Orion is actually competitive once warm)

3. **Adjust Test Thresholds**: For Orion DB compatibility, increase `base_delay_ms` to account for insert loop duration, or measure timing from after the insert loop completes

4. **Connection Pooling**: Ensure connection pool is pre-warmed and maintains persistent connections to avoid repeated cold-starts

---

## Raw Test Commands

```bash
# Test 1: Server-side batch inserts
PGPASSWORD="***" psql -h duroxide-pg-westus.postgres.database.azure.com -U affandar -d postgres -f /tmp/db_perf_test_large.sql
PGPASSWORD="***" psql -h adar-duroxide-hdb-westus3.ee706b367a1e.westus3.oriondb.azure.com -U horizonadmin -d postgres -f /tmp/db_perf_test_large.sql

# Test 2: Realistic duroxide pattern
PGPASSWORD="***" psql -h duroxide-pg-westus.postgres.database.azure.com -U affandar -d postgres -f /tmp/db_perf_realistic.sql
PGPASSWORD="***" psql -h adar-duroxide-hdb-westus3.ee706b367a1e.westus3.oriondb.azure.com -U horizonadmin -d postgres -f /tmp/db_perf_realistic.sql
```
