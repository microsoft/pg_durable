# PostgreSQL Provider Stress Test Results - Azure (duroxide-pg)

This file tracks stress test performance over time for the PostgreSQL provider running on Azure PostgreSQL.

## Baseline (Initial Implementation)

**Date**: 2025-11-10  
**Commit**: `7a10fd5`  
**Environment**: Azure PostgreSQL (duroxide-pg.postgres.database.azure.com)  
**Configuration**:
- max_concurrent: 20
- duration: 10s
- tasks_per_instance: 5
- activity_delay: 10ms
- Note: 1:1 configuration skipped (too slow for high-latency networks)

### Results

| Config | Completed | Failed | Success % | Orch/sec | Activity/sec | Avg Latency |
|--------|-----------|--------|-----------|----------|--------------|-------------|
| 2:2    | 20        | 0      | 100.0%    | 0.36     | 1.82         | 2745ms      |
| 4:4    | 22        | 0      | 100.0%    | 0.50     | 2.49         | 2005ms      |

**Notes**:
- All tests passed with 100% success rate
- 4:4 configuration shows better throughput (0.50 orch/sec)
- High latency (2-3 seconds) due to network RTT to Azure
- Throughput ~40× lower than local due to network overhead
- Stored procedures critical for remote viability (minimize roundtrips)

---

