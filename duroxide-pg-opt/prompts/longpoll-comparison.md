# AI Prompt: Long-Poll Comparison Test

## Objective

Run the long-poll comparison stress tests to measure the effectiveness of long-polling vs traditional polling. Compare DB call counts and fetch efficiency metrics between the two modes.

## Prerequisites

1. **Database Connection**: Ensure `DATABASE_URL` is set in `.env` file
2. **db-metrics feature**: Tests must be run with `--features db-metrics` to capture metrics

## Tests to Run

Run these two tests **sequentially** (not in parallel) to get accurate isolated metrics:

### Test 1: Long-Poll DISABLED (baseline)

```bash
cargo test --features db-metrics --test stress_tests stress_test_longpoll_comparison_disabled -- --ignored --nocapture 2>&1
```

### Test 2: Long-Poll ENABLED

```bash
cargo test --features db-metrics --test stress_tests stress_test_longpoll_comparison_enabled -- --ignored --nocapture 2>&1
```

## What to Compare

After each test completes, look for the `DB METRICS SUMMARY` output block. Key metrics to compare:

### 1. Fetch Effectiveness (Primary Metric)

```
--- Long-Poll Effectiveness ---
  Orchestration: X items / Y attempts = Z effectiveness
  Work Items:    X items / Y attempts = Z effectiveness  
  Combined:      X items / Y attempts = Z effectiveness
```

- **Effectiveness < 1.0**: Many empty fetches (polling inefficiency)
- **Effectiveness = 1.0**: Perfect 1:1 (every fetch gets exactly one item)
- **Effectiveness > 1.0**: Batching working well (one fetch gets multiple items)

**Expected**: Long-poll ENABLED should have **higher effectiveness** because it waits for notifications instead of polling repeatedly when no work is available.

### 2. Loaded vs Empty Fetches (NEW - Critical for Performance Analysis)

```
--- Loaded vs Empty Fetches ---
  Orchestration: X loaded / Y empty (Z% loaded)
  Work Items:    X loaded / Y empty (Z% loaded)
```

This separates fetches that returned items ("loaded") from those that returned nothing ("empty"). This is important because:
- **Empty fetches** are fast (no row locking, serialization, or data transfer)
- **Loaded fetches** are slower (locking, deserializing, transferring data)
- Averaging them together **skews timing analysis**

**Expected**: Long-poll ENABLED should have **fewer empty fetches** because it waits for NOTIFY instead of polling.

### 3. Total DB Calls

```
Total DB calls: N
DB calls per orch: X.X
```

**Expected**: Long-poll ENABLED should have **fewer total DB calls** because it doesn't poll the database during idle periods.

### 3. Stored Procedure Call Breakdown

```
Calls by stored procedure:
  get_orchestrations_to_dispatch    N
  fetch_and_lock_next_work_items    N
  ...
```

**Expected**: The `get_orchestrations_to_dispatch` and `fetch_and_lock_next_work_items` calls should be significantly lower with long-poll enabled.

## Test Configuration Details

Both tests use identical settings to ensure fair comparison:
- `max_concurrent: 3` - Low concurrency creates idle gaps where long-poll benefits show
- `duration_secs: 30` - 30 second duration
- `tasks_per_instance: 5` - 5 activities per orchestration
- `activity_delay_ms: 1000` - 1 second delay per activity (creates wait periods)
- `orch_concurrency: 2, worker_concurrency: 2`

## Example Analysis

After running both tests, produce a comparison table:

| Metric | Long-Poll DISABLED | Long-Poll ENABLED | Improvement |
|--------|-------------------|-------------------|-------------|
| Total DB Calls | | | X% reduction |
| Orch Fetch Effectiveness | | | |
| Work Item Fetch Effectiveness | | | |
| Combined Fetch Effectiveness | | | |
| Orch Empty Fetches | | | X% reduction |
| Work Item Empty Fetches | | | X% reduction |
| get_orchestrations_to_dispatch | | | |
| fetch_and_lock_next_work_items | | | |

## Troubleshooting

If metrics don't show significant differences:
1. Ensure `activity_delay_ms` is high enough (1000ms+) to create idle periods
2. Verify `max_concurrent` is low (3-5) so work is not always immediately available
3. Check that the `db-metrics` feature is enabled in the cargo test command

## Saving Results

After completing the analysis, ask the user:

> **Would you like to save these results as a snapshot?**
>
> I can create a timestamped results file in `perf_results/` folder with:
> - Test configuration parameters
> - Current git commit hash
> - Full metrics comparison table
> - Raw test output
>
> File will be named: `lp-comp-YYYY-MM-DD-{local|remote}.md`
>
> Please specify if you're using a **local** or **remote** PostgreSQL database.

If the user wants to save results, create the file at:
```
perf_results/lp-comp-YYYY-MM-DD-{local|remote}.md
```

Include in the file:
1. Date and git commit hash (run `git rev-parse HEAD`)
2. Test configuration table (max_concurrent, duration_secs, tasks_per_instance, activity_delay_ms, etc.)
3. Results comparison table
4. Full raw output from both tests
5. Key findings summary

### Important Notes

- **Do NOT commit** the perf_results file unless the user explicitly asks to commit it
- **Privacy**: Do NOT include database hostname, connection string, or any identifying information about the database server. Only note whether it was "local" or "remote" in the filename suffix
