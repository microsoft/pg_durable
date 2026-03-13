# Long-Poll Comparison Test Results

**Date**: December 20, 2024  
**Commit**: `fa37063b044974a36cc5726013b952b49c34804b`  
**Branch**: `longpoll_final`  
**Database**: Local PostgreSQL (Docker)

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

Long-polling reduces DB calls by **40%** and empty fetches by **70%** compared to traditional polling.

## Results Comparison

| Metric | Long-Poll DISABLED | Long-Poll ENABLED | Improvement |
|--------|-------------------|-------------------|-------------|
| **Total DB Calls** | 3,086 | 1,857 | **39.8% reduction** |
| **DB Calls per Orch** | 220.4 | 132.6 | **39.8% reduction** |
| **Orch Fetch Effectiveness** | 0.123 | 0.320 | **2.6x better** |
| **Work Item Fetch Effectiveness** | 0.897 | 0.972 | 8.4% better |
| **Combined Fetch Effectiveness** | 0.235 | 0.510 | **2.2x better** |
| **Orch Empty Fetches** | 405 | 119 | **70.6% reduction** |
| **Work Item Empty Fetches** | 8 | 2 | 75% reduction |
| `fetch_orchestration_item` calls | 1,768 | 552 | **68.8% reduction** |

## Detailed Output

### Long-Poll DISABLED (Baseline)

```
============================================================
DB METRICS SUMMARY: stress_test_longpoll_comparison_DISABLED (100ms activity delay)
============================================================
Completed orchestrations: 14
Total activities:         70
Total DB calls:           3086
DB calls per orch:        220.4

--- Long-Poll Effectiveness ---
  Orchestration:     57 items /    462 attempts = 0.123 effectiveness
  Work Items:        70 items /     78 attempts = 0.897 effectiveness
  Combined:         127 items /    540 attempts = 0.235 effectiveness

--- Loaded vs Empty Fetches ---
  Orchestration:     57 loaded /    405 empty (12.3% loaded)
  Work Items:        70 loaded /      8 empty (89.7% loaded)

Calls by operation:
  sp_call                    3086

Calls by stored procedure:
  fetch_orchestration_item                       1768
  fetch_history                                  1097
  fetch_work_item                                  78
  ack_worker                                       70
  ack_orchestration_item                           57
  enqueue_orchestrator_work                        14
  get_system_metrics                                1
  get_queue_depths                                  1
============================================================
```

### Long-Poll ENABLED

```
============================================================
DB METRICS SUMMARY: stress_test_longpoll_comparison_ENABLED (100ms activity delay)
============================================================
Completed orchestrations: 14
Total activities:         70
Total DB calls:           1857
DB calls per orch:        132.6

--- Long-Poll Effectiveness ---
  Orchestration:     56 items /    175 attempts = 0.320 effectiveness
  Work Items:        70 items /     72 attempts = 0.972 effectiveness
  Combined:         126 items /    247 attempts = 0.510 effectiveness

--- Loaded vs Empty Fetches ---
  Orchestration:     56 loaded /    119 empty (32.0% loaded)
  Work Items:        70 loaded /      2 empty (97.2% loaded)

Calls by operation:
  sp_call                    1857

Calls by stored procedure:
  fetch_history                                  1091
  fetch_orchestration_item                        552
  fetch_work_item                                  72
  ack_worker                                       70
  ack_orchestration_item                           56
  enqueue_orchestrator_work                        14
  get_queue_depths                                  1
  get_system_metrics                                1
============================================================
```

## Key Findings

1. **Long-polling significantly reduces DB calls** - 40% fewer total database calls with long-poll enabled.

2. **Orchestration fetch effectiveness improved dramatically** - From 12.3% loaded to 32.0% loaded. With polling disabled, 87.7% of orchestration fetches returned nothing (wasted round-trips).

3. **Empty fetches reduced by 70%** - 405 → 119 empty orchestration fetches. This is the primary win from long-polling.

4. **Work items already efficient** - Work item fetches were already ~90% loaded, so less improvement there. Activities complete quickly and work is usually available.

5. **`fetch_orchestration_item` calls cut by 69%** - From 1,768 to 552 calls. This is where the main polling overhead was happening.

## Conclusion

The long-poll implementation is working as designed - it waits for PostgreSQL NOTIFY signals instead of repeatedly polling an empty queue, resulting in significant reduction in database load.
