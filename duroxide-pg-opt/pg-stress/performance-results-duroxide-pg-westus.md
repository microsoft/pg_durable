
## Run: 2025-11-11 05:26:51 UTC

- **Commit**: `86ec121` (branch: `main`)
- **Duration**: 3s
- **Hostname**: duroxide-pg-westus

### Stress Test Results

```
=== Comparison Table ===
2025-11-11T05:26:50.653883Z  INFO Provider             Config     Completed  Failed     Infra    Config   App      Success %  Orch/sec        Activity/sec    Avg Latency    
2025-11-11T05:26:50.653893Z  INFO ------------------------------------------------------------------------------------------------------------------------------------------------------
2025-11-11T05:26:50.653896Z  INFO PostgreSQL           2:2        20         0          0        0        0        100.00     1.55            7.73            646.80         ms
2025-11-11T05:26:50.653900Z  INFO PostgreSQL           4:4        21         0          0        0        0        100.00     1.89            9.44            529.43         ms
2025-11-11T05:26:50.653906Z  INFO 
✅ All stress tests passed!

Results can be tracked in: stress-test-results-duroxide-pg-westus.md
```

### Server-Side Execution Times

```
📈 Server-Side Execution Times (from pg_stat_statements):

      procedure_name      | Calls | Avg (ms) | Min (ms) | Max (ms) 
--------------------------+-------+----------+----------+----------
 fetch_history            |  3433 |     0.13 |     0.05 |     2.15
 fetch_orchestration_item |   832 |     8.17 |     0.07 |  2931.93
 fetch_work_item          |   515 |     0.31 |     0.04 |     2.98
 ack_worker               |   405 |     0.24 |     0.09 |     1.06
 ack_orchestration_item   |   338 |     0.84 |     0.19 |     4.25
 enqueue_orchestrator     |    81 |     0.49 |     0.07 |     4.04
(6 rows)


=== Network Overhead Analysis ===

Server-side times shown above are PURE execution time on PostgreSQL.
Compare to client elapsed times from stress test logs:

  • West US region: Client elapsed ~70ms
  • Other regions: Client elapsed ~150ms
```

---

## Run: 2025-11-11 05:33:49 UTC

- **Commit**: `86ec121` (branch: `main`)
- **Duration**: 5s
- **Hostname**: duroxide-pg-westus

### Stress Test Results

```
=== Comparison Table ===
[2m2025-11-11T05:33:49.461201Z[0m [32m INFO[0m Provider             Config     Completed  Failed     Infra    Config   App      Success %  Orch/sec        Activity/sec    Avg Latency    
[2m2025-11-11T05:33:49.461206Z[0m [32m INFO[0m ------------------------------------------------------------------------------------------------------------------------------------------------------
[2m2025-11-11T05:33:49.461208Z[0m [32m INFO[0m PostgreSQL           2:2        23         0          0        0        0        100.00     1.47            7.35            680.04         ms
[2m2025-11-11T05:33:49.461212Z[0m [32m INFO[0m PostgreSQL           4:4        23         0          0        0        0        100.00     1.69            8.43            592.78         ms
[2m2025-11-11T05:33:49.461216Z[0m [32m INFO[0m 
✅ All stress tests passed!

Results can be tracked in: stress-test-results-duroxide-pg-westus.md
```

### Server-Side Execution Times

```
📈 Server-Side Execution Times (from pg_stat_statements):

      procedure_name      | Calls | Avg (ms) | Min (ms) | Max (ms) 
--------------------------+-------+----------+----------+----------
 fetch_history            |  4306 |     0.13 |     0.05 |     4.51
 fetch_orchestration_item |   901 |    10.73 |     0.07 |  1064.41
 fetch_work_item          |   564 |     0.29 |     0.04 |     3.21
 ack_worker               |   465 |     0.22 |     0.09 |     0.92
 ack_orchestration_item   |   390 |     0.79 |     0.22 |     4.25
 enqueue_orchestrator     |    93 |     0.35 |     0.07 |     2.05
(6 rows)


=== Network Overhead Analysis ===

Server-side times shown above are PURE execution time on PostgreSQL.
Compare to client elapsed times from stress test logs:

  • West US region: Client elapsed ~70ms
  • Other regions: Client elapsed ~150ms
```

---
