# PostgreSQL Provider Stress Test Results

This file tracks stress test performance over time for the PostgreSQL provider.

## Baseline (Initial Implementation)

**Date**: 2025-11-10  
**Commit**: `e0a0ddf`  
**Environment**: Local Docker PostgreSQL 17  
**Configuration**:
- max_concurrent: 20
- duration: 5s
- tasks_per_instance: 5
- activity_delay: 10ms

### Results

| Config | Completed | Failed | Success % | Orch/sec | Activity/sec | Avg Latency |
|--------|-----------|--------|-----------|----------|--------------|-------------|
| 1:1    | 91        | 0      | 100.0%    | 13.94    | 69.70        | 71.74ms     |
| 2:2    | 103       | 0      | 100.0%    | 18.02    | 90.09        | 55.50ms     |
| 4:4    | 93        | 0      | 100.0%    | 12.33    | 61.64        | 81.11ms     |

**Notes**:
- All tests passed with 100% success rate
- 2:2 configuration shows best throughput (18.02 orch/sec)
- Latency ranges from 55-81ms for local database
- Some slow query warnings (>1s) observed during high concurrency

---

