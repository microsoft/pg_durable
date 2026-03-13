# Long-Poll Comparison Test Results

**Date**: December 20, 2024  
**Commit**: `e91bc95ccb0d47fb82009a963babab09805d1624`  
**Branch**: `longpoll_final`  
**Database**: Remote PostgreSQL

## Test Configuration

| Parameter | Value |
|-----------|-------|
| `max_concurrent` | 3 |
| `duration_secs` | 30 |
| `tasks_per_instance` | 5 |
| `activity_delay_ms` | 1000 (1 second) |
| `orch_concurrency` | 2 |
| `worker_concurrency` | 2 |

## Summary

With a remote database, long-polling shows modest improvements. The network latency already dominates, reducing the benefit of eliminating empty polls. Work item fetches show the clearest improvement (73% reduction in empty fetches).

## Results Comparison

| Metric | Long-Poll DISABLED | Long-Poll ENABLED | Improvement |
|--------|-------------------|-------------------|-------------|
| **Total DB Calls** | 1,041 | 1,089 | -4.6% (slight increase) |
| **DB Calls per Orch** | 104.1 | 108.9 | -4.6% |
| **Orch Fetch Effectiveness** | 0.479 | 0.488 | 1.9% better |
| **Work Item Fetch Effectiveness** | 0.769 | 0.926 | **20.4% better** |
| **Combined Fetch Effectiveness** | 0.581 | 0.623 | 7.2% better |
| **Orch Empty Fetches** | 63 | 62 | 1.6% reduction |
| **Work Item Empty Fetches** | 15 | 4 | **73% reduction** |
| `fetch_orchestration_item` calls | 382 | 396 | +3.7% |
| `fetch_work_item` calls | 65 | 54 | **17% reduction** |

## Detailed Output

### Long-Poll DISABLED (Baseline)

```
============================================================
DB METRICS SUMMARY: stress_test_longpoll_comparison_DISABLED (100ms activity delay)
============================================================
Completed orchestrations: 10
Total activities:         50
Total DB calls:           1041
DB calls per orch:        104.1

--- Long-Poll Effectiveness ---
  Orchestration:     58 items /    121 attempts = 0.479 effectiveness
  Work Items:        50 items /     65 attempts = 0.769 effectiveness
  Combined:         108 items /    186 attempts = 0.581 effectiveness

--- Loaded vs Empty Fetches ---
  Orchestration:     58 loaded /     63 empty (47.9% loaded)
  Work Items:        50 loaded /     15 empty (76.9% loaded)

Calls by operation:
  sp_call                    1041

Calls by stored procedure:
  fetch_history                                   474
  fetch_orchestration_item                        382
  fetch_work_item                                  65
  ack_orchestration_item                           58
  ack_worker                                       50
  enqueue_orchestrator_work                        10
  get_system_metrics                                1
  get_queue_depths                                  1
============================================================

Test duration: 44.08s
```

### Long-Poll ENABLED

```
============================================================
DB METRICS SUMMARY: stress_test_longpoll_comparison_ENABLED (100ms activity delay)
============================================================
Completed orchestrations: 10
Total activities:         50
Total DB calls:           1089
DB calls per orch:        108.9

--- Long-Poll Effectiveness ---
  Orchestration:     59 items /    121 attempts = 0.488 effectiveness
  Work Items:        50 items /     54 attempts = 0.926 effectiveness
  Combined:         109 items /    175 attempts = 0.623 effectiveness

--- Loaded vs Empty Fetches ---
  Orchestration:     59 loaded /     62 empty (48.8% loaded)
  Work Items:        50 loaded /      4 empty (92.6% loaded)

Calls by operation:
  sp_call                    1089

Calls by stored procedure:
  fetch_history                                   518
  fetch_orchestration_item                        396
  ack_orchestration_item                           59
  fetch_work_item                                  54
  ack_worker                                       50
  enqueue_orchestrator_work                        10
  get_queue_depths                                  1
  get_system_metrics                                1
============================================================

Test duration: 49.43s
```

## Key Findings

1. **Less dramatic improvement than local** - With the remote database, the network latency already dominates, so fewer orchestrations complete in the 30s window (10 vs 14 locally).

2. **Work item fetches improved significantly** - Empty work item fetches dropped from 15 to 4 (73% reduction), and effectiveness went from 77% to 93%.

3. **Orchestration fetches similar** - Both modes had ~48% loaded fetches. The remote network latency means less aggressive polling is already happening.

4. **Higher baseline effectiveness** - Remote polling is already slower (due to network RTT), so there's naturally less "empty polling" compared to local.

5. **Longer test duration observed** - 44s/49s vs 37s locally, showing the impact of network latency.

## Comparison with Local Results

| Metric | Local DISABLED | Local ENABLED | Remote DISABLED | Remote ENABLED |
|--------|---------------|---------------|-----------------|----------------|
| Completed Orchestrations | 14 | 14 | 10 | 10 |
| Total DB Calls | 3,086 | 1,857 | 1,041 | 1,089 |
| Orch Empty Fetches | 405 | 119 | 63 | 62 |
| Work Empty Fetches | 8 | 2 | 15 | 4 |

The local database shows much more aggressive polling (405 empty fetches vs 63), which is why long-polling provides a larger benefit locally (70% reduction) compared to remote (minimal reduction for orchestration fetches).
