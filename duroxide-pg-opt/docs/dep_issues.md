# Duroxide Upstream Blockers & Dependencies

**Purpose:** Track duroxide issues/limitations that require workarounds in duroxide-pg-opt.

**Last Updated:** 2025-01-07

**Quick Links:**
- 🔗 [All duroxide-pg issues](https://github.com/microsoft/duroxide/labels/duroxide-pg)

---

## How to Check for Fixes

1. **Check duroxide releases:**
   ```bash
   gh release list --repo microsoft/duroxide --limit 10
   ```

2. **Check specific issue status:**
   ```bash
   gh issue view <ISSUE_NUMBER> --repo microsoft/duroxide
   ```

3. **Check current duroxide version in use:**
   ```bash
   grep 'duroxide = ' Cargo.toml
   ```

4. **After duroxide update, search for STOPGAP markers:**
   ```bash
   grep -rn "STOPGAP\|BLOCKED on duroxide\|TODO.*duroxide fix" --include="*.rs" .
   ```

---

## Active Blockers

### 1. Provider Validation Missing Prune for Running Instances Test

| Field | Value |
|-------|-------|
| **Issue** | [GitHub #50](https://github.com/microsoft/duroxide/issues/50) |
| **Status** | 🔴 Open |
| **Fixed In** | TBD |
| **Workaround Location** | `src/provider.rs` - manual fix applied |

**Problem:**
The provider validation tests for pruning (`test_prune_options_combinations`, `test_prune_safety`, `test_prune_bulk`) only create instances in `Completed` state. They don't validate that providers correctly handle `Running` instances with old executions from `ContinueAsNew`.

**Root Cause:**
- Tests use `create_multi_execution_instance` helper that creates Completed instances
- No test creates a Running instance with multiple executions
- Providers can pass all tests while incorrectly filtering out Running instances

**Impact:**
- Bug in duroxide-pg-opt filtered `WHERE e.status IN ('Completed', 'Failed', 'ContinuedAsNew')`
- Long-running orchestrations using ContinueAsNew would never have old executions pruned
- All 101 provider validation tests passed despite the bug

**Proposed Fix:**
Add a provider validation test that:
1. Creates an instance that remains in Running status
2. Simulates ContinueAsNew (multiple executions, latest is Running)
3. Calls `prune_executions_bulk` 
4. Verifies old executions are pruned from the Running instance

**Current Workaround:**
- **Fixed in duroxide-pg-opt** - Changed filter from terminal states to `WHERE 1=1`
- See `src/provider.rs` `prune_executions_bulk` function

**When Fixed - Cleanup Steps:**
1. Update duroxide dependency in `Cargo.toml`
2. Verify the new validation test passes
3. Update this document

**Files to Update:**
- [ ] None (bug already fixed in duroxide-pg-opt)

---

### 2. Provider Validation Missing Lock Extension Verification

| Field | Value |
|-------|-------|
| **Issue** | [GitHub #36](https://github.com/microsoft/duroxide/issues/36) |
| **Status** | 🔴 Open |
| **Fixed In** | TBD |
| **Workaround Location** | None - manual code review required |

**Problem:**
The `renew_work_item_lock` provider contract specifies that the lock should **only** be extended when `ExecutionState::Running` is returned. For `Terminal` and `Missing` states, the lock must NOT be extended. However, the validation tests only verify the **return value**, not whether the lock was actually extended.

**Root Cause:**
- Tests like `test_renew_returns_terminal_when_orchestration_completed` check the return value
- No test verifies that the lock timeout was NOT extended
- Provider implementations can pass all tests while incorrectly extending locks

**Impact:**
- All 77 provider validation tests passed in duroxide-pg-opt even when the contract was violated
- Bug was only discovered through manual code review
- Incorrect behavior could cause activities to continue running after orchestration cancellation

**Proposed Fix:**
Add validation tests that:
1. Call `renew_work_item_lock` on a Terminal/Missing state
2. Wait for the **original** lock timeout to elapse (not the renewal duration)
3. Verify the work item becomes fetchable (proving lock was NOT extended)

**Current Workaround:**
- **None** - manual code review of `renew_work_item_lock` implementation required
- Ensure stored procedure checks execution status BEFORE extending lock

**When Fixed - Cleanup Steps:**
1. Update duroxide dependency in `Cargo.toml`
2. Verify the new validation tests pass
3. Update this document

**Files to Update:**
- [ ] None (no code workaround, just awareness)

---

### 3. Idempotency Test Uses Cross-Execution Activity Cancellation

| Field | Value |
|-------|-------|
| **Issue** | [GitHub #40](https://github.com/microsoft/duroxide/issues/40) |
| **Status** | 🔴 Open |
| **Fixed In** | TBD |
| **Workaround Location** | None - provider allows cross-execution cancellation |

**Problem:**
The `test_cancelling_nonexistent_activities_is_idempotent` validation test passes `ScheduledActivityIdentifier` with `execution_id: 99` when calling `ack_orchestration_item` with `execution_id: 1`. This implies orchestrations can cancel activities from **any** execution.

**Root Cause:**
- Test uses different execution_ids to verify idempotency
- An orchestration should only be able to cancel its own activities
- Current design prevents providers from validating execution_id match

**Impact:**
- Providers cannot assert that cancelled_activities belong to the current execution
- Cross-execution cancellation doesn't reflect real orchestration semantics
- Provider implementations must allow mismatched execution_ids to pass validation

**Proposed Fix:**
Change the test to use the **same** execution_id for both the `ack_orchestration_item` call and the `ScheduledActivityIdentifier`. The test remains an idempotency test (non-existent activity_id), but correctly validates same-execution cancellation.

**Current Workaround:**
- **None** - provider allows any execution_id in cancelled_activities
- Rust code intentionally does NOT assert execution_id match (see `provider.rs` comments)

**When Fixed - Cleanup Steps:**
1. Update duroxide dependency in `Cargo.toml`
2. Optionally add Rust assertion that cancelled_activities match current execution_id
3. Update this document

**Files to Update:**
- [ ] `src/provider.rs` - optionally add assertion after fix

---

## Resolved Blockers

### [RESOLVED] Configurable `wait_for_orchestration` Timeout

| Field | Value |
|-------|-------|
| **Issue** | [GitHub #31](https://github.com/microsoft/duroxide/issues/31) |
| **Status** | ✅ Resolved |
| **Fixed In** | v0.1.7 |
| **Cleanup PR** | N/A - workaround code already uses `wait_timeout_secs` |

**Resolution Date:** 2024-12-29

**Resolution:**
duroxide v0.1.7 added `StressTestConfig::wait_timeout_secs` field, allowing providers to specify custom timeouts for remote databases. The workaround code in `pg-stress/src/lib.rs` already uses this field (`wait_timeout_secs: 120`), so no cleanup is needed - just update comments to note the field is now officially supported.

**Original Problem:**
The stress test framework had a hardcoded 60-second timeout for `wait_for_orchestration`. This caused large payload tests to fail on remote databases with high latency.

---

### [RESOLVED] Validation Test Timing Race with Connection Latency

| Field | Value |
|-------|-------|
| **Issue** | [GitHub #32](https://github.com/microsoft/duroxide/issues/32) |
| **Status** | ✅ Resolved |
| **Fixed In** | v0.1.7 |
| **Cleanup PR** | N/A - workaround removed |

**Resolution Date:** 2024-12-29

**Resolution:**
duroxide v0.1.7 fixed the `test_multi_threaded_lock_expiration_recovery` race condition. The connection pre-warming workaround in `src/provider.rs` has been removed.

**Original Problem:**
The test spawned threads that started sleep timers at spawn time, causing timing issues with connection establishment latency.

**Cleanup Completed:**
- [x] Verify test passes without pre-warming
- [x] Remove pre-warming code in `src/provider.rs` (both constructors)
- [x] Remove TODO comments

---

### [RESOLVED] Validation Test Timing Sensitivity (Lock Renewal)

| Field | Value |
|-------|-------|
| **Issue** | [GitHub #34](https://github.com/microsoft/duroxide/issues/34) |
| **Status** | ✅ Resolved |
| **Fixed In** | v0.1.7 |
| **Cleanup PR** | N/A - no workaround code |

**Resolution Date:** 2024-12-29

**Resolution:**
duroxide v0.1.7 fixed the `test_worker_lock_renewal_extends_timeout` timing sensitivity issue. The test now uses larger timing margins that accommodate remote database latency.

**Original Problem:**
The test used 800ms sleeps with 1s lock timeouts, causing failures on remote databases with 40-60ms latency.

---

## Checklist After Duroxide Update

When updating the duroxide dependency, run through this checklist:

1. [ ] Check if any issues in "Active Blockers" are fixed in the new version
2. [ ] Run `grep -rn "STOPGAP\|BLOCKED on duroxide" --include="*.rs" .` to find workarounds
3. [ ] For each fixed issue:
   - [ ] Remove the workaround code
   - [ ] Run the affected tests to confirm fix
   - [ ] Move the blocker to "Resolved Blockers" section
   - [ ] Update `TODO.md`
4. [ ] Run full test suite: `cargo test`
5. [ ] Run stress tests: `./scripts/run-stress-tests.sh`
6. [ ] Update this document with new status

---

## Version Compatibility Matrix

| duroxide-pg-opt | duroxide | Notes |
|-----------------|----------|-------|
| 0.1.7 | 0.1.11 | Current - #50 (prune Running fix applied locally), #36/#40 pending |
| 0.1.6 | 0.1.7 | Previous - cooperative cancellation support, #31/#32/#34 resolved |
