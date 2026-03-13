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

Long-polling reduces DB calls by **17%** and orchestration empty fetches by **43%** on this remote database.

## Results Comparison

| Metric | Long-Poll DISABLED | Long-Poll ENABLED | Improvement |
|--------|-------------------|-------------------|-------------|
| **Total DB Calls** | 1,728 | 1,427 | **17.4% reduction** |
| **DB Calls per Orch** | 144.0 | 118.9 | **17.4% reduction** |
| **Orch Fetch Effectiveness** | 0.305 | 0.447 | **46.6% better** |
| **Work Item Fetch Effectiveness** | 0.882 | 0.938 | 6.3% better |
| **Combined Fetch Effectiveness** | 0.439 | 0.587 | **33.7% better** |
| **Orch Empty Fetches** | 157 | 89 | **43.3% reduction** |
| **Work Item Empty Fetches** | 8 | 4 | 50% reduction |
| `fetch_orchestration_item` calls | 779 | 473 | **39.3% reduction** |

## Detailed Output

### Long-Poll DISABLED (Baseline)

```
============================================================
DB METRICS SUMMARY: stress_test_longpoll_comparison_DISABLED (100ms activity delay)
============================================================
Completed orchestrations: 12
Total activities:         60
Total DB calls:           1728
DB calls per orch:        144.0

--- Long-Poll Effectiveness ---
  Orchestration:     69 items /    226 attempts = 0.305 effectiveness
  Work Items:        60 items /     68 attempts = 0.882 effectiveness
  Combined:         129 items /    294 attempts = 0.439 effectiveness

--- Loaded vs Empty Fetches ---
  Orchestration:     69 loaded /    157 empty (30.5% loaded)
  Work Items:        60 loaded /      8 empty (88.2% loaded)

Calls by operation:
  sp_call                    1728

Calls by stored procedure:
  fetch_orchestration_item                        779
  fetch_history                                   738
  ack_orchestration_item                           69
  fetch_work_item                                  68
  ack_worker                                       60
  enqueue_orchestrator_work                        12
  get_queue_depths                                  1
  get_system_metrics                                1
============================================================

Test duration: 43.07s
```

### Long-Poll ENABLED

```
============================================================
DB METRICS SUMMARY: stress_test_longpoll_comparison_ENABLED (100ms activity delay)
============================================================
Completed orchestrations: 12
Total activities:         60
Total DB calls:           1427
DB calls per orch:        118.9

--- Long-Poll Effectiveness ---
  Orchestration:     72 items /    161 attempts = 0.447 effectiveness
  Work Items:        60 items /     64 attempts = 0.938 effectiveness
  Combined:         132 items /    225 attempts = 0.587 effectiveness

--- Loaded vs Empty Fetches ---
  Orchestration:     72 loaded /     89 empty (44.7% loaded)
  Work Items:        60 loaded /      4 empty (93.8% loaded)

Calls by operation:
  sp_call                    1427

Calls by stored procedure:
  fetch_history                                   744
  fetch_orchestration_item                        473
  ack_orchestration_item                           72
  fetch_work_item                                  64
  ack_worker                                       60
  enqueue_orchestrator_work                        12
  get_queue_depths                                  1
  get_system_metrics                                1
============================================================

Test duration: 42.10s
```

## Key Findings

1. **Better improvement than horizondb** - 17% DB call reduction vs essentially no improvement on horizondb.

2. **Significant orchestration fetch improvement** - Empty fetches dropped from 157 to 89 (43% reduction), and effectiveness improved from 30.5% to 44.7%.

3. **`fetch_orchestration_item` calls reduced by 39%** - From 779 to 473 calls.

4. **12 orchestrations completed** - Better than horizondb (10), suggesting lower network latency to this database.

5. **Work items already efficient** - Work item fetches were already ~88% loaded, with modest improvement to 94%.

## Comparison Across All Databases

| Metric | Local | HorizonDB | Flex |
|--------|-------|-----------|------|
| Completed Orchestrations | 14 | 10 | 12 |
| DB Call Reduction | 39.8% | -4.6% | 17.4% |
| Orch Empty Fetch Reduction | 70.6% | 1.6% | 43.3% |
| Work Empty Fetch Reduction | 75% | 73% | 50% |

The flex database shows intermediate performance - better than horizondb but not as good as local, suggesting moderate network latency.
