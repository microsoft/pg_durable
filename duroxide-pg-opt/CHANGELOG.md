# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.18] - 2026-02-22

- Updated duroxide dependency from 0.1.19 to 0.1.20
- **Custom status as history events:** `ack_orchestration_item` now scans `history_delta` for
  `CustomStatusUpdated` events instead of reading `ExecutionMetadata.custom_status`
  - Removed `CustomStatusUpdate` enum usage (removed upstream in duroxide 0.1.20)
  - Custom status is now fully durable and replayable via history events
- **`short_poll_threshold()` override:** ProviderFactory now returns 500ms for PostgreSQL,
  resolving duroxide #51
- Added `test_orphan_activity_after_instance_force_deletion` validation test
- Total validation tests: 167 (up from 166)

## [0.1.17] - 2026-02-20

- Updated duroxide dependency from 0.1.18 to 0.1.19
- **Custom Status:** Orchestration instances can now carry a custom status string
  - New `get_custom_status()` provider method for polling custom status changes
  - `ack_orchestration_item` handles `custom_status_action` (set/clear) in metadata
  - Custom status lives on `instances` table so it survives `ContinueAsNew`
  - `custom_status_version` column enables efficient long-polling
- **QueueMessage WorkItem:** Added `QueueMessage` variant handling in `fetch_work_item` and `enqueue_orchestrator_work`
- **Worker lock expiry on ack:** `ack_worker` now validates lock expiry (`locked_until > p_now_ms`)
- Migration 0005: `add_custom_status` (custom_status/custom_status_version columns, get_custom_status function, updated ack_orchestration_item and ack_worker)
- Added 7 custom_status validation tests
- Added 3 new validation tests: `test_prune_bulk_includes_running_instances`, `test_orchestration_lock_renewal_after_expiration`, `test_worker_ack_fails_after_lock_expiry`
- Total validation tests: 166

## [0.1.16] - 2026-02-17

- Updated duroxide dependency from 0.1.17 to 0.1.18
- **Activity Session Affinity:** Full session routing for worker queue items
  - `fetch_work_item` now accepts `SessionFetchConfig` for session-aware routing
  - New `renew_session_lock` stored procedure for session heartbeats
  - New `cleanup_orphaned_sessions` stored procedure for idle session cleanup
  - `ack_worker` and `renew_work_item_lock` piggyback `last_activity_at` updates on session rows
  - `ack_orchestration_item` extracts `session_id` from `ActivityExecute` worker items
- **Notifier fix:** Changed worker `notify_one()` to `notify_waiters()` to prevent session-routing
  deadlock when per-slot worker identities are used (no `worker_node_id`)
- Migration 0004: `add_session_support` (new `sessions` table, `worker_queue.session_id` column, session routing logic)
- Added 33 session validation tests (total validation tests: 152)
- Added 7 session e2e tests

## [0.1.15] - 2026-02-09

- Updated duroxide dependency from 0.1.16 to 0.1.17
- **Provider Capability Filtering (Phase 1):** SQL-level version filtering before lock acquisition
  - `fetch_orchestration_item` now accepts `DispatcherCapabilityFilter` parameter
  - New `duroxide_version_major/minor/patch` columns on `executions` table
  - Pinned version stored via `ack_orchestration_item` metadata
  - NULL versions treated as always compatible (backward compat)
- **History deserialization contract:** History errors now surface via `history_error` field
  instead of returning `ProviderError`, enabling poison message detection
- Migration 0003: `add_capability_filtering` (additive, safe for rolling upgrades)
- Total validation tests: 119 (up from 99)

## [0.1.14] - 2026-02-03

### Changed

- **Updated duroxide dependency from 0.1.14 to 0.1.16**
  - duroxide 0.1.16 adds `ActivityCancelRequested` and `SubOrchestrationCancelRequested` history events
  - No provider API changes required (additive change only)

### Internal

- Total validation tests: 103 (unchanged)
- All 213 tests pass

## [0.1.13] - 2026-01-30

### Changed

- **Updated duroxide dependency from 0.1.14 to 0.1.15**
  - duroxide 0.1.15 changes:
    - Simplified metrics facade with consistent atomic counters
    - Code coverage improvements to 91.9%
    - New code coverage guide and Copilot skill

### Added

- New validation test: `deletion::test_stale_activity_after_delete_recreate`
  - Tests that stale activity completion after delete+recreate doesn't corrupt the new instance

### Internal

- Total validation tests: 103 (up from 102)
- All 213 tests pass

## [0.1.12] - 2026-01-24

### Changed

- **Updated duroxide dependency from 0.1.13 to 0.1.14**
  - duroxide 0.1.14 changes:
    - Fire-and-forget orchestrations (`ctx.schedule_orchestration()`) now correctly create `OrchestrationChained` events in history
    - Fixes determinism detection failures when detached orchestrations are followed by activities on replay

### Internal

- No changes to provider implementation required - all tests pass

## [0.1.11] - 2026-01-24

### Changed

- **Updated duroxide dependency from 0.1.11 to 0.1.13**
  - duroxide 0.1.12 changes:
    - Unobserved future cancellation with proper `DurableFuture` drop semantics
    - Simplified `ActivityRegistry` API (takes value instead of Arc)
    - Improved dispatcher backoff logic
  - duroxide 0.1.13 changes:
    - **Breaking:** `utcnow()` renamed to `utc_now()` for Rust naming convention
    - System calls (`new_guid()`, `utc_now()`) reimplemented as regular activities
    - Reserved activity prefix `__duroxide_syscall:` for builtin activities
    - Fixes determinism bugs where syscalls returned fresh values on replay

### Fixed

- Updated `tests/e2e_samples.rs` to use `ctx.utc_now()` (renamed from `ctx.utcnow()`)

### Improved

- Enhanced `prompts/duroxide-update-sync.md` with:
  - Safety guidelines for not pushing without permission
  - GitHub release check step
  - Run ALL tests (not just validation tests)
  - STOPGAP marker search step
  - Provider trait changes checklist
  - Quick reference commands section

## [0.1.10] - 2026-01-23

### Changed

- **Updated duroxide dependency from 0.1.11 to 0.1.12**
  - Significant API changes from duroxide 0.1.12:
    - `ActivityRegistry` now passed directly (no longer wrapped in `Arc`)
    - `DurableFuture` is directly awaitable (removed `into_activity()`, `into_timer()`, `into_sub_orchestration()`, `into_event()`)
    - `DurableOutput` enum replaced with `Either2`/`Either3` for select operations
    - `ctx.select(vec![...])` replaced with `ctx.select2()`/`ctx.select3()`
    - `ctx.join()` now returns `Vec<T>` directly (not `Vec<DurableOutput>`)
  - New validation test: `test_same_activity_in_worker_items_and_cancelled_is_noop`

### Fixed

- Updated all E2E test files to use new duroxide 0.1.12 API patterns
- Fixed clippy warnings in test files

## [0.1.9] - 2026-01-06

### Added

- **Instance lifecycle management** (ProviderAdmin trait implementation):
  - `list_children(instance_id)` - list child instances of a parent orchestration
  - `get_parent_id(instance_id)` - get parent instance for sub-orchestrations
  - `delete_instances_atomic(ids, force)` - atomically delete multiple instances with cascade
  - `delete_instance_bulk(filter)` - bulk delete terminal instances with filtering
  - `prune_executions(instance_id, options)` - prune old executions keeping recent history
  - `prune_executions_bulk(filter, options)` - bulk prune across multiple instances

- **New migration 0002**: `0002_add_deletion_and_pruning_support.sql`
  - Adds `parent_instance_id` column to instances table
  - Adds `idx_instances_parent` index for efficient child lookups
  - New stored procedures: `list_children`, `get_parent_id`, `delete_instances_atomic`, `prune_executions`
  - Modified: `get_instance_info` now returns `parent_instance_id`
  - Modified: `ack_orchestration_item` now stores `parent_instance_id` from metadata

- 19 new provider validation tests:
  - Deletion tests (12): `test_delete_terminal_instances`, `test_delete_running_rejected_force_succeeds`,
    `test_delete_nonexistent_instance`, `test_delete_cleans_queues_and_locks`, `test_cascade_delete_hierarchy`,
    `test_force_delete_prevents_ack_recreation`, `test_list_children`, `test_delete_get_parent_id`,
    `test_delete_get_instance_tree`, `test_delete_instances_atomic`, `test_delete_instances_atomic_force`,
    `test_delete_instances_atomic_orphan_detection`
  - Prune tests (3): `test_prune_options_combinations`, `test_prune_safety`, `test_prune_bulk`
  - Bulk deletion tests (4): `test_delete_instance_bulk_filter_combinations`, 
    `test_delete_instance_bulk_safety_and_limits`, `test_delete_instance_bulk_completed_before_filter`,
    `test_delete_instance_bulk_cascades_to_children`

- Regression tests for `prune_executions_bulk` bug:
  - `test_prune_running_instance_prunes_terminal_executions`
  - `test_prune_executions_bulk_includes_running_instances`

### Fixed

- **Bug fix**: `prune_executions_bulk` now includes Running instances in the query.
  Previously, Running instances were excluded, preventing pruning of old terminal executions
  for long-running orchestrations using ContinueAsNew. The stored procedure already protects
  the current Running execution, so this was unnecessarily restrictive.

### Changed

- Updated to duroxide 0.1.11 from crates.io
- Provider now passes `parent_instance_id` in metadata to `ack_orchestration_item`
- Schema migrations documentation added: [docs/schema_migrations.md](docs/schema_migrations.md)

### Notes

- Total validation tests: 101 (82 + 19 lifecycle management)
- Total regression tests: 4 (new)
- Migration 0002 is additive and backward-compatible with existing databases
- Requires duroxide 0.1.11+ for ProviderAdmin lifecycle management features

## [0.1.8] - 2025-01-03

### Added

- **Lock-stealing cancellation support** (duroxide 0.1.8 API):
  - `ack_orchestration_item` now accepts `cancelled_activities: Vec<ScheduledActivityIdentifier>`
  - Cancelled activities are deleted from worker queue atomically during orchestration ack
  - Enables immediate activity cancellation without waiting for lock expiry

- 5 new provider validation tests for lock-stealing cancellation:
  - `test_cancelled_activities_deleted_from_worker_queue`
  - `test_ack_work_item_fails_when_entry_deleted`
  - `test_renew_fails_when_entry_deleted`
  - `test_cancelling_nonexistent_activities_is_idempotent`
  - `test_batch_cancellation_deletes_multiple_activities`

### Changed

- Updated to duroxide 0.1.8 from crates.io
- `ack_orchestration_item` stored procedure now handles `p_cancelled_activities` JSONB parameter
- Simplified migration approach: single `0001_initial_schema.sql` as source of truth

### Removed

- Migration delta scripts (`0002_*.sql`, `*_diff.md`) - not needed for single-schema approach
- `generate_migration_diff.sh` script

### Notes

- Total validation tests: 82 (77 + 5 lock-stealing)
- Requires duroxide 0.1.8+ for lock-stealing cancellation support

## [0.1.7] - 2024-12-29

### Added

- **Cooperative cancellation support** (duroxide 0.1.7 API):
  - `fetch_work_item` now returns `ExecutionState` (4th tuple element) indicating orchestration status
  - `renew_work_item_lock` now returns `ExecutionState` instead of `()`:
    - Returns `Running` when lock is successfully extended
    - Returns `Terminal { status }` when orchestration completed/failed (lock NOT extended)
    - Returns `Missing` when execution record doesn't exist (lock NOT extended)
  - `ack_work_item` now accepts `Option<WorkItem>`:
    - `Some(completion)` - enqueue completion to orchestrator queue
    - `None` - just delete worker item (for terminal/missing orchestrations)

- 9 new provider validation tests for cancellation support:
  - `test_fetch_returns_running_state_for_active_orchestration`
  - `test_fetch_returns_terminal_state_when_orchestration_completed`
  - `test_fetch_returns_terminal_state_when_orchestration_failed`
  - `test_fetch_returns_terminal_state_when_orchestration_continued_as_new`
  - `test_fetch_returns_missing_state_when_instance_deleted`
  - `test_renew_returns_running_when_orchestration_active`
  - `test_renew_returns_terminal_when_orchestration_completed`
  - `test_renew_returns_missing_when_instance_deleted`
  - `test_ack_work_item_none_deletes_without_enqueue`

- 5 new long-polling validation tests

### Changed

- Updated to duroxide 0.1.7 from crates.io
- `renew_work_item_lock` stored procedure now checks execution status BEFORE extending lock
  - Per provider contract: lock only extended when orchestration is Running
  - Terminal/Missing states return status without extending lock
- `ack_worker` stored procedure now accepts NULL completion (no enqueue, just delete)

### Removed

- Connection pre-warming workaround (duroxide #32 fixed in v0.1.7)
- STOPGAP comments for resolved upstream issues (#31, #32, #34)

### Notes

- Total validation tests: 86 (77 + 9 cancellation)
- Requires duroxide 0.1.7+ for cooperative cancellation support

## [0.1.6] - 2025-12-22

### Changed

- Code cleanup: removed unused `#[allow(dead_code)]` and feature gates from tests

### Fixed

- Fixed clippy warnings (empty line after doc comment, type complexity, manual Range::contains)
- Applied cargo fmt formatting fixes

## [0.1.5] - 2024-12-14

### Fixed

- Added migration 0004 to update stored procedures for existing databases
  - 0.1.4 only updated migration 0002 which doesn't run on existing databases
  - This migration recreates procedures with attempt_count support

## [0.1.4] - 2024-12-14

### Added

- 3 new provider validation tests from duroxide 0.1.3:
  - `test_abandon_work_item_releases_lock` - Verify abandon_work_item releases lock immediately
  - `test_abandon_work_item_with_delay` - Verify abandon_work_item with delay defers refetch
  - `max_attempt_count_across_message_batch` - Verify MAX attempt_count returned for batched messages

### Fixed

- `abandon_work_item` with delay now correctly keeps lock_token to prevent immediate refetch
  (matches SQLite provider behavior from duroxide 0.1.3)
- `abandon_orchestration_item` without delay no longer updates visible_at
  (was causing timing issues where messages became temporarily invisible)

### Notes

- Total validation tests: 61 passing
- Updated to duroxide 0.1.3 from crates.io

## [0.1.3] - 2024-12-14

### Changed

- **BREAKING:** Updated to duroxide 0.1.2 API with poison message handling
- `fetch_orchestration_item` now returns `(OrchestrationItem, String, u32)` tuple (lock_token and attempt_count moved to tuple)
- `fetch_work_item` now returns `(WorkItem, String, u32)` tuple (added attempt_count)
- `abandon_orchestration_item` now requires `ignore_attempt: bool` parameter
- `OrchestrationItem` no longer contains `lock_token` field (moved to return tuple)

### Added

- New migration `0003_add_attempt_count.sql` - adds `attempt_count` column to queue tables
- `abandon_work_item()` method - explicit work item lock release with delay and ignore_attempt support
- `renew_orchestration_item_lock()` method - extends orchestration lock timeout for long-running turns
- 8 new poison message validation tests:
  - `orchestration_attempt_count_starts_at_one`
  - `orchestration_attempt_count_increments_on_refetch`
  - `worker_attempt_count_starts_at_one`
  - `worker_attempt_count_increments_on_lock_expiry`
  - `attempt_count_is_per_message`
  - `abandon_work_item_ignore_attempt_decrements`
  - `abandon_orchestration_item_ignore_attempt_decrements`
  - `ignore_attempt_never_goes_negative`

### Notes

- Total validation tests: 58 (up from 50)
- Poison message detection is automatic in duroxide runtime when `attempt_count` exceeds `max_attempts` (default: 10)

## [0.1.2] - 2024-12-10

### Changed

- Updated to duroxide 0.1.1 API
- `fetch_orchestration_item` now accepts `poll_timeout: Duration` parameter (for long-polling support)
- `fetch_work_item` now accepts `poll_timeout: Duration` parameter (for long-polling support)
- Updated test configurations to use `dispatcher_min_poll_interval` (renamed from `dispatcher_idle_sleep`)
- Updated tests to use new `continue_as_new()` awaitable API (`return ctx.continue_as_new(input).await`)

### Notes

- The `test_worker_lock_renewal_extends_timeout` validation test may fail with high-latency database connections (>200ms round-trip). This is a timing-sensitive test from the duroxide validation suite, not a provider bug.

## [0.1.1] - 2024-12-09

### Added

- Initial release on crates.io
- Full implementation of `Provider` trait for PostgreSQL
- Full implementation of `ProviderAdmin` trait for management/observability
- Atomic stored procedures for all provider operations
- Instance-level locking with advisory locks
- Worker queue with lock renewal support
- Multi-execution support for continue-as-new
- Comprehensive test suite with 50+ validation tests

