# Phase 4 Review: E2E Tests

**Reviewer**: impl-review (local)
**Diff range**: `adec7f5..c354d52`
**Date**: 2025-03-27

## Verdict: ✅ APPROVE

Phase 4 is well-executed. All four test files, the dedicated test harness, the exclusion logic, and CI integration are correct and aligned with the implementation plan. Two observations are noted below—neither blocks approval.

---

## Checklist

| Criterion | Status | Notes |
|-----------|--------|-------|
| Test correctness | ✅ | All four tests verify what they claim. Assertions check both workflow status AND side-effect data. |
| Test robustness | ✅ | Generous timeouts (30–60s). `wait_for_completion` used correctly. Blocker workflow in test 45 waited for too. |
| Pattern adherence | ✅ | Follows existing conventions: temp `_test_state`, `DROP TABLE IF EXISTS`, `SELECT 'TEST PASSED'`, `RAISE EXCEPTION` on failure. |
| Script quality | ✅ | `apply_gucs`/`restore_defaults` pair is clean. `sed -i.bak` idempotent. Server restart + readiness wait. |
| CI integration | ✅ | Placement correct: after `e2e_tests`, before `upgrade_tests`. Uses correct step ID. |
| Exclusion logic | ✅ | Tests 44–46 excluded from main suite via glob match. Test 43 included (no custom GUCs needed). |
| Plan alignment | ✅ | All items from Phase 4 plan implemented: 4 test files, dedicated harness, CI step, exclusion. |

---

## Test-by-Test Analysis

### 43_connection_limit_defaults.sql ✅
- Starts 5 concurrent workflows, each inserting a row, under default GUCs (max_user_connections=10).
- Asserts all 5 complete AND verifies 5 rows in log table (dual-assertion pattern).
- Uses `wait_for_completion(id, 30)` — appropriate timeout.
- Cleanup: drops both temp and permanent tables.
- Runs in standard suite — correct (no custom GUCs needed).

### 44_connection_limit_backpressure.sql ✅
- 4 workflows with `pg_sleep(3) ~> INSERT` under max_user_connections=2.
- With 2 slots, tests genuine backpressure queuing (at most 2 concurrent, 2 queued).
- 60s timeout is generous enough for 2 batches of 3s sleep + scheduling variance.
- Verifies all 4 complete AND 4 rows inserted.
- Good use of `~>` operator to chain sleep with insert (tests real concurrent execution, not just queuing start calls).

### 45_connection_limit_timeout.sql ✅
- Blocker holds single slot for 15s, victim launched 3s later with 2s acquire timeout.
- Correctly asserts: victim status = 'failed', output contains 'connection limit reached', output contains 'max_user_connections='.
- String assertions match actual error format in `src/activities/execute_sql.rs:58-64` ("pg_durable: connection limit reached (max_user_connections={limit})...").
- Waits for blocker to complete too — clean test that doesn't leave orphan workflows.
- Uses `df.instance_info(victim_id)` to read output — matches existing pattern in test 09.

### 46_connection_limit_startup_validation.sql ✅
- Tests negative path: max_duroxide_connections=1 (below minimum 2).
- Multi-layered verification: checks `_worker_ready` table existence, then if table exists, verifies worker isn't processing by starting a workflow and confirming it stays non-completed.
- Runs as `PG_USER` (postgres) not `E2E_USER` — correct, since the extension needs superuser access for the validation scenario and the worker never starts to create the E2E user's schema context.
- 15s combined wait (5s initial + 10s for workflow) is adequate to prove worker isn't running.

---

## Test Harness: test-connlimit-e2e.sh ✅

**Strengths:**
- Clean `apply_gucs`/`restore_defaults` separation.
- `sed -i.bak` with idempotent deletion pattern (delete existing lines, then append).
- Readiness polling loop with 30-iteration cap for tests 1 and 2.
- Intentionally skips readiness wait for test 3 (worker should NOT become ready).
- Restores defaults + recreates extension at the end for clean state.
- `set -e` ensures early exit on unexpected failures.
- Builds and installs extension before running.

**Observation 1 (Non-blocking):** No `trap` for cleanup on early `set -e` exit.
If a test crashes or the script is interrupted (Ctrl+C), the GUC overrides remain in `postgresql.conf` and the server may be left in a non-default state. The main `test-e2e-local.sh` has `trap cleanup EXIT` for this. Adding a trap to call `restore_defaults` on ERR/EXIT would make the script more robust against partial failures. This is a minor robustness improvement, not a correctness issue — `test-e2e-local.sh --clean` or manual restart would recover, and CI always starts clean.

---

## Exclusion Logic ✅

The glob patterns in `test-e2e-local.sh` correctly exclude exactly tests 44–46:
```bash
|| [[ "$test_name" == 44_connection_limit_* ]]
|| [[ "$test_name" == 45_connection_limit_* ]]
|| [[ "$test_name" == 46_connection_limit_* ]]
```
Verified: `basename 44_connection_limit_backpressure.sql .sql` → `44_connection_limit_backpressure`, which matches `44_connection_limit_*`.

Test 43 is NOT excluded — correct, since it needs no custom GUCs.

The comment above the exclusion block is clear and references the separate script.

---

## CI Integration ✅

```yaml
- name: Run connection limit E2E tests
  id: connlimit_tests
  run: ./scripts/test-connlimit-e2e.sh
```

Placement after `e2e_tests` and before `upgrade_tests` is correct:
1. Standard E2E tests run first (including test 43).
2. Connection limit tests run with custom GUCs.
3. Upgrade tests run last (they need a clean state, and `test-connlimit-e2e.sh` restores defaults).

**Observation 2 (Non-blocking):** The CI step doesn't pass `--pg-version` like the main E2E step does. The script hardcodes `PG_VERSION="17"`. This is consistent with how the project currently works (only PG17 in CI matrix), but if multi-version testing is added later, this would need updating.

---

## Plan Alignment

| Plan Item | Implemented | Notes |
|-----------|-------------|-------|
| Dedicated test harness script | ✅ | `scripts/test-connlimit-e2e.sh` |
| Backpressure test (max_user_connections=2) | ✅ | `44_connection_limit_backpressure.sql` |
| Timeout test (max_user_connections=1, timeout=2) | ✅ | `45_connection_limit_timeout.sql` |
| Defaults test (standard suite) | ✅ | `43_connection_limit_defaults.sql` |
| Startup validation test (max_duroxide_connections=1) | ✅ | `46_connection_limit_startup_validation.sql` |
| CI step for connlimit tests | ✅ | `.github/workflows/ci.yml` |
| Exclude 44-46 from main suite | ✅ | `scripts/test-e2e-local.sh` |

---

## Summary of Observations

1. **No cleanup trap in test-connlimit-e2e.sh** — Adding `trap restore_defaults EXIT` would guard against `set -e` exits leaving non-default GUCs. Low risk (CI always starts clean), but a good defensive practice.

2. **Hardcoded PG_VERSION=17** — Acceptable for now but may need parameterization if multi-PG-version CI is added.

Neither observation warrants blocking the phase. Both are minor robustness improvements that can be addressed in a follow-up if desired.
