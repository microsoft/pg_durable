# AI Prompt: PostgreSQL Provider Performance Analysis

## Context

You are analyzing the performance of the `duroxide-pg` PostgreSQL provider implementation for the Duroxide durable task orchestration framework. Your goal is to identify where time is being spent during test execution and provide actionable recommendations for optimization.

## Setup Instructions

### Prerequisites

1. **Database Connection**: Ensure `DATABASE_URL` is set in `.env` file
2. **Repository**: You're in the `duroxide-pg` workspace root
3. **Tools Available**:
   - Rust/Cargo for running tests
   - `psql` for PostgreSQL queries
   - `pg_stat_statements` extension enabled on the database

### Measurement Configuration

The repository includes scripts for performance measurement:
- `./scripts/start-measurement.sh` - Resets pg_stat_statements
- `./scripts/stop-measurement.sh` - Queries and displays server-side timing stats
- `./scripts/measure-server-performance.sh` - Combined workflow with --track option

## Data Collection Process

### Step 1: Prepare Measurement Environment

```bash
# Clean up old test schemas
./scripts/cleanup_test_schemas.sh

# Start measurement (resets pg_stat_statements)
./scripts/start-measurement.sh
```

### Step 2: Run Tests with Debug Logging

Execute all test suites with debug-level logging to capture detailed timing information:

#### A. Basic Provider Tests

```bash
RUST_LOG=debug cargo test --lib --test basic_tests -- --nocapture 2>&1 | tee logs/basic_tests_debug.log
```

#### B. Provider Validation Tests  

```bash
RUST_LOG=debug cargo test --test postgres_provider_test -- --nocapture 2>&1 | tee logs/provider_validation_debug.log
```

#### C. E2E Sample Tests

```bash
RUST_LOG=debug cargo test --test e2e_samples -- --nocapture 2>&1 | tee logs/e2e_samples_debug.log
```

#### D. Stress Tests

```bash
RUST_LOG=debug cargo run --release --package duroxide-pg-stress --bin pg-stress -- --duration 10 2>&1 | tee logs/stress_test_debug.log
```

### Step 3: Collect Server-Side Statistics

```bash
# Stop measurement and display pg_stat_statements results
./scripts/stop-measurement.sh | tee logs/pg_stat_statements.log
```

### Step 4: Gather All Artifacts

```bash
# Create logs directory if needed
mkdir -p logs

# Already created above:
# - logs/basic_tests_debug.log
# - logs/provider_validation_debug.log
# - logs/e2e_samples_debug.log
# - logs/stress_test_debug.log
# - logs/pg_stat_statements.log
```

## Analysis Instructions

You now have five key data sources. Analyze them systematically:

### 1. Client-Side Timing Analysis (Debug Logs)

**Source**: `logs/*_debug.log` files

**Look for**:
- Lines containing `elapsed=` or `elapsed_secs=` - these show total client → server → client time
- Lines containing `duration_ms=` - these show application-level operation timing
- Patterns like:
  ```
  elapsed=156.154625ms  - CREATE SCHEMA
  elapsed=161.859958ms  - CREATE TABLE
  elapsed=152.401167ms  - SELECT
  ```

**Extract**:
1. Average query elapsed time across different operation types
2. Minimum and maximum elapsed times (identify outliers)
3. Patterns in slow queries (what makes some queries slower?)

### 2. Server-Side Timing Analysis (pg_stat_statements)

**Source**: `logs/pg_stat_statements.log`

**Look for table with columns**:
- `procedure_name` - Which stored procedure
- `Calls` - How many times called
- `Avg (ms)` - Average server-side execution time
- `Min (ms)` - Fastest execution
- `Max (ms)` - Slowest execution

**Extract**:
1. Server-side execution time for each procedure
2. Identify procedures with high variance (large stddev or max >> avg)
3. Compare call counts to understand execution patterns

### 3. Network Overhead Calculation

**Method**: Compare client elapsed time vs server execution time

For each stored procedure:
```
Network overhead = Client elapsed - Server execution
Network % = (Network overhead / Client elapsed) × 100
```

**Example**:
```
fetch_orchestration_item:
  Client elapsed: 70ms (from debug logs)
  Server execution: 3.36ms (from pg_stat_statements)
  Network overhead: 66.64ms
  Network %: 95.2%
```

**Questions to answer**:
1. What percentage of total time is network overhead?
2. Which operations are most impacted by network latency?
3. Are there operations with high server-side execution time?

### 4. Operation Frequency Analysis

**Count operations per test type**:
- How many `fetch_orchestration_item` calls per orchestration?
- How many `fetch_work_item` calls per activity?
- How many `read` (fetch_history) calls per orchestration turn?

**Look for**:
- Redundant operations (unnecessary polling)
- Operations that could be batched
- Chatty patterns (many small calls vs few large calls)

### 5. Bottleneck Identification

**Classify time spent into categories**:

1. **Network RTT** - Calculated from (Client elapsed - Server execution) × Call count
2. **Server Execution** - From pg_stat_statements mean_exec_time × Call count  
3. **Application Logic** - Time between database calls (orchestration logic, activity execution)

**Example breakdown for single orchestration**:
```
Total orchestration latency: 1,200ms
- Network RTT: 1,050ms (87%) - 15 calls × 70ms
- Server execution: 45ms (4%) - Sum of all procedure times
- Application logic: 105ms (9%) - Orchestration + activity code
```

## Expected Patterns to Identify

### Pattern 1: Network Dominance (Remote Database)

**Symptom**: 
- Client elapsed >> Server execution (10-100× difference)
- Network accounts for 90-99% of total time

**Example**:
```
Operation: fetch_orchestration_item
  Calls: 200
  Client elapsed: 70ms each = 14,000ms total
  Server execution: 3ms each = 600ms total
  Network overhead: 67ms × 200 = 13,400ms (96% of time)
```

**Recommendation**: Co-locate runtime with database (VNet integration, same region)

### Pattern 2: Chatty Operations

**Symptom**:
- High call counts for operations that could be batched
- Many sequential roundtrips

**Example**:
```
Worker operations per orchestration:
  fetch_work_item × 5 = 5 roundtrips
  ack_worker × 5 = 5 roundtrips
  Total: 10 roundtrips × 70ms = 700ms
```

**Recommendation**: Batch worker operations (requires runtime changes)

### Pattern 3: Server-Side Bottlenecks

**Symptom**:
- High server execution time (>50ms)
- Large standard deviation (inconsistent performance)
- Max >> Avg (occasional slow queries)

**Example**:
```
fetch_orchestration_item:
  Avg: 8.17ms
  Max: 2931.93ms  ← OUTLIER
  StdDev: 191.34ms ← HIGH VARIANCE
```

**Investigation**:
- Lock contention (FOR UPDATE SKIP LOCKED under high concurrency)
- Missing indexes
- Query plan issues

### Pattern 4: Client-Side Polling

**Symptom**:
- High call count for read operations
- `fetch_history` called multiple times per orchestration

**Example**:
```
fetch_history calls: 1,195
  Per orchestration: ~25 calls (polling for completion)
  Time wasted: 25 × 70ms = 1,750ms
```

**Recommendation**: Reduce polling frequency, use longer wait intervals

## Analysis Template

Provide your analysis in this structure:

### Executive Summary

[3-5 sentence summary of key findings and primary bottleneck]

### Timing Breakdown

**Total Time Distribution**:
```
Category               | Time (ms) | % of Total
-----------------------|-----------|------------
Network RTT            | X,XXX     | XX%
Server Execution       | XXX       | X%
Application Logic      | XXX       | X%
```

### Per-Operation Analysis

For each major operation (fetch_orchestration_item, ack_orchestration_item, fetch_work_item, etc.):

**Operation**: [name]
- **Call count**: X
- **Client elapsed**: Xms average
- **Server execution**: Xms average
- **Network overhead**: Xms (X%)
- **Bottleneck**: [Network/Server/Application]
- **Recommendation**: [Specific action]

### Identified Bottlenecks

1. **[Bottleneck Name]**
   - **Impact**: High/Medium/Low
   - **Root cause**: [Explanation]
   - **Evidence**: [Data from logs/stats]
   - **Recommendation**: [Specific fix]
   - **Expected improvement**: [Quantified if possible]

### Optimization Priorities

Rank optimizations by impact:

1. **[Top Priority]** - Expected X% improvement
2. **[Second Priority]** - Expected X% improvement
3. **[Third Priority]** - Expected X% improvement

### Code-Level Recommendations

If server-side bottlenecks are identified, provide specific code changes:

```sql
-- Example: Add index
CREATE INDEX idx_xyz ON table_name(column);

-- Example: Optimize query
-- BEFORE: SELECT * FROM...
-- AFTER: SELECT col1, col2 FROM... WHERE indexed_col = ...
```

### Infrastructure Recommendations

If network is the bottleneck:

- [ ] Move database to same region as runtime (Expected: X× improvement)
- [ ] Use VNet integration / Private Link (Expected: X× improvement)  
- [ ] Deploy runtime in same datacenter (Expected: X× improvement)

## Sample Questions to Answer

Use the data to answer these questions:

1. **What is the average network RTT?** (Client elapsed - Server execution)
2. **What percentage of time is spent on network vs server vs application?**
3. **Which stored procedure is slowest on the server?** Why?
4. **Are there any procedures with high variance?** (Check stddev and max)
5. **How many roundtrips per orchestration?** Can any be eliminated?
6. **Are there any missing indexes causing slow queries?**
7. **Is lock contention an issue?** (Check fetch_orchestration_item max time)
8. **How does performance compare between local and remote databases?**
9. **What would be the impact of reducing network RTT to <5ms?**
10. **Are there opportunities for query batching?**

## Output Format

Provide your analysis as a markdown document with:
- Executive summary
- Detailed breakdown by category
- Specific, actionable recommendations
- Code examples where applicable
- Quantified expected improvements

## Example Analysis Output

```markdown
# Performance Analysis Report

## Executive Summary

The PostgreSQL provider shows excellent server-side performance (<10ms average execution) but is severely bottlenecked by network latency. Network RTT accounts for 95% of total time on remote databases. The stored procedures are already optimal; further improvements require infrastructure changes (co-location) or runtime architecture changes (batching).

## Timing Breakdown

Total test suite time: 45 seconds

**Time Distribution**:
- Network RTT: 39,600ms (88%)
- Server Execution: 2,800ms (6%)
- Application Logic: 2,600ms (6%)

## Per-Operation Analysis

### fetch_orchestration_item
- **Calls**: 933
- **Client elapsed**: 70ms avg
- **Server execution**: 3.36ms avg
- **Network overhead**: 66.64ms (95%)
- **Total impact**: 933 × 66.64ms = 62,171ms network overhead
- **Bottleneck**: Network
- **Recommendation**: Infrastructure - co-locate runtime with database

[... continue for each operation ...]

## Identified Bottlenecks

### 1. Network Latency (CRITICAL)
- **Impact**: HIGH - 95% of total time
- **Root cause**: 70ms RTT to Azure West US
- **Evidence**: pg_stat shows 3-8ms server time, client logs show 70ms elapsed
- **Recommendation**: Deploy runtime in same VNet as PostgreSQL
- **Expected improvement**: 70ms → 3ms = 23× faster

[... continue for each bottleneck ...]
```

## Files to Reference

- `docs/REMOTE_PERFORMANCE_ANALYSIS.md` - Previous analysis
- `docs/REGION_COMPARISON.md` - Regional performance comparison
- `docs/SERVER_SIDE_TIMING_ANALYSIS.md` - Detailed timing breakdown
- `STRESS_TEST_SUMMARY.md` - Stress test baseline results

Use these as reference but perform fresh analysis on the new data.

