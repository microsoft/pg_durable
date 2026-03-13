# PostgreSQL Provider Stress Test Results - Azure West US (duroxide-pg-westus)

This file tracks stress test performance for the PostgreSQL provider running on Azure PostgreSQL in the West US region.

## Baseline (After Region Move)

**Date**: 2025-11-11  
**Commit**: `c96aa2b`  
**Environment**: Azure PostgreSQL West US (duroxide-pg-westus.postgres.database.azure.com)  
**Configuration**:
- max_concurrent: 20
- duration: 10s
- tasks_per_instance: 5
- activity_delay: 10ms
- Note: 1:1 configuration skipped (too slow for remote)

### Results

| Config | Completed | Failed | Success % | Orch/sec | Activity/sec | Avg Latency |
|--------|-----------|--------|-----------|----------|--------------|-------------|
| 2:2    | 24        | 0      | 100.0%    | 0.86     | 4.30         | 1,163ms     |
| 4:4    | 26        | 0      | 100.0%    | 1.17     | 5.86         | 854ms       |

### Comparison to Original Region

| Metric | Original | West US | Improvement |
|--------|----------|---------|-------------|
| RTT | 152ms | 70ms | **2.2× faster** |
| Throughput (2:2) | 0.36 orch/sec | 0.86 orch/sec | **2.4× faster** |
| Throughput (4:4) | 0.50 orch/sec | 1.17 orch/sec | **2.3× faster** |
| Latency (2:2) | 2,745ms | 1,163ms | **58% reduction** |
| Latency (4:4) | 2,005ms | 854ms | **57% reduction** |

**Notes**:
- All tests passed with 100% success rate
- 4:4 configuration shows best throughput (1.17 orch/sec)
- Latency reduced by 58% due to lower network RTT (152ms → 70ms)
- Network RTT still accounts for ~85% of total latency
- Moving to same region as client provided 2.3× improvement
- Query timings range from 50-200ms (avg ~70ms)

**Key Insight**: Each 2× reduction in RTT yields approximately 2× improvement in throughput.

---

