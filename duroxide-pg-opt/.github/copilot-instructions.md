# Copilot Instructions for duroxide-pg-opt

## Project Overview

PostgreSQL provider for [Duroxide](https://github.com/microsoft/duroxide) durable workflow framework. Implements `Provider` and `ProviderAdmin` traits using PostgreSQL with atomic stored procedures and LISTEN/NOTIFY long-polling.

## Architecture

### Core Components

- **[src/provider.rs](../src/provider.rs)**: `PostgresProvider` - implements duroxide `Provider` trait, all DB operations use stored procedures for atomicity
- **[src/notifier.rs](../src/notifier.rs)**: Long-polling via PostgreSQL LISTEN/NOTIFY with timer heaps for scheduled work wake-up
- **[src/migrations.rs](../src/migrations.rs)**: Auto-migration on provider creation, embedded SQL from `migrations/`
- **[src/fault_injection.rs](../src/fault_injection.rs)**: Testing resilience (clock skew, notifier disable, query delays)
- **[src/db_metrics.rs](../src/db_metrics.rs)**: Zero-cost metrics instrumentation (enabled via `db-metrics` feature)

### Database Schema

All tables live in a configurable PostgreSQL schema (default: `public`). Key tables: `instances`, `executions`, `history`, `orchestrator_queue`, `worker_queue`, `instance_locks`. See [migrations/0001_initial_schema.sql](../migrations/0001_initial_schema.sql) for complete schema with triggers and stored procedures.

### Test Schema Isolation

Tests create unique schemas (`test_{uuid_suffix}`, `e2e_test_{uuid_suffix}`) for isolation. Always call `provider.cleanup_schema()` after tests. See [tests/common/mod.rs](../tests/common/mod.rs) for helpers.

## Development Workflow

### Environment Setup

```bash
# Required: DATABASE_URL in .env or environment
DATABASE_URL=postgres://user:pass@localhost:5432/duroxide_test
```

### Localhost vs Remote Database Testing

Tests frequently switch between local PostgreSQL (Docker) and cloud-hosted PostgreSQL with ~200-300ms latency. Latency-sensitive tests use `is_localhost()` to adjust timing thresholds:

```rust
fn is_localhost() -> bool {
    let url = get_database_url();
    url.contains("localhost") || url.contains("127.0.0.1")
}

// Example: Adjust lock timeout and sleep durations
let (lock_timeout, sleep_duration) = if is_localhost() {
    (Duration::from_secs(1), Duration::from_millis(400))   // Tight timing
} else {
    (Duration::from_secs(5), Duration::from_millis(2000))  // Relaxed for latency
};
```

See [tests/postgres_provider_test.rs](../tests/postgres_provider_test.rs) `test_worker_lock_renewal_extends_timeout` for a real example.

### Running Tests

Prefer `cargo nextest` over `cargo test` when available for better test output, parallelism, and failure reporting.

```bash
# Basic tests (requires PostgreSQL)
cargo nextest run                    # preferred
cargo test                           # fallback

# Run specific test file
cargo nextest run --test postgres_provider_test
cargo test --test postgres_provider_test

# Stress tests (marked #[ignore], require explicit run)
./scripts/run-stress-tests.sh

# Performance tests
./scripts/run-perf-tests.sh

# Fault injection tests (require feature flag)
cargo nextest run --test fault_injection_tests --features test-fault-injection --run-ignored ignored-only
cargo test --test fault_injection_tests --features test-fault-injection -- --ignored

# With metrics for long-poll comparison (single-threaded required)
cargo nextest run --features db-metrics -j 1
cargo test --features db-metrics -- --test-threads=1
```

### Connection Exhaustion Under High Parallelism

Each test runtime creates a connection pool (default 10 max connections) **plus** a dedicated `PgListener` connection for LISTEN/NOTIFY. At high parallelism (e.g., 14 cores), peak PostgreSQL connections can reach **~117**. If PostgreSQL `max_connections` is set to the default 100, e2e tests will fail with timeouts due to connection exhaustion.

This is worse than duroxide-pg (~104 peak) because of the extra PgListener connection per runtime.

**Fix:** Increase PostgreSQL `max_connections` to at least 300:
```bash
docker exec <container> psql -U postgres -c "ALTER SYSTEM SET max_connections = 500;"
docker restart <container>
```

### Key Cargo Features

- `test-fault-injection` (default): Enables `FaultInjector` for testing clock skew, notifier failures
- `db-metrics`: Enables database operation instrumentation (not default)

## Conventions

### Error Handling

Use `ProviderError` with proper classification in [provider.rs](../src/provider.rs#L300):
- `ProviderError::retryable()` - deadlocks (40P01), pool timeouts, I/O errors
- `ProviderError::permanent()` - constraint violations (23505, 23503), serialization failures

### Stored Procedures

All provider operations use schema-qualified stored procedures (e.g., `schema.fetch_orchestration_item`). This ensures atomicity and allows the database to handle locking. Add new procedures in [migrations/](../migrations/) and update the migration runner.

### Adding Migrations

**IMPORTANT**: `0001_initial_schema.sql` is the **baseline schema** and should generally not be modified. All schema changes should be delta migrations (0002+).

1. Create `NNNN_description.sql` in `migrations/` with incremental changes only
2. Use `ALTER TABLE` for column additions, `CREATE OR REPLACE FUNCTION` for stored procedure updates
3. Use unqualified table names (search_path is set by runner)
4. Make idempotent with `IF NOT EXISTS` / `IF EXISTS` / `DROP ... IF EXISTS`
5. **Avoid modifying `0001_initial_schema.sql`** - it represents the baseline for existing deployments. However, if modifications are needed for infrastructure reasons (e.g., PostgreSQL limitations like return type changes requiring DROP before CREATE), check with the user first.
6. **REQUIRED: Create a companion `NNNN_diff.md` file** (see below)

### Migration Diff Files (Required)

Every migration that modifies schema or stored procedures **must** have a companion `NNNN_diff.md` file. This is required because git diffs for SQL migrations only show the new code, not the delta from the previous version.

**Diff format requirements:** Each changed function must be shown **in full** with `+`/`-` diff markers on changed lines. This ensures the reader always knows which function a change belongs to (the `CREATE OR REPLACE FUNCTION` line is always visible at the top of each block). Do NOT use standard unified diff with small context windows — those lose function boundaries in large stored procedures.

The diff file should contain:
1. **Table Changes** — New tables (full column list), modified tables (mark new columns with `+`)
2. **New Indexes** — Any indexes added by the migration
3. **Function Changes** — For each changed function: full function body in a `diff` code block with `+`/`-` markers. New functions shown in full in a `sql` code block. Signature changes called out separately.

Example: See [migrations/0004_diff.md](../migrations/0004_diff.md)

### Time Handling

All timestamps use Unix epoch milliseconds (`i64`). The `now_millis()` method in provider supports clock skew injection for testing. Never use `chrono` types directly in provider logic.

### Long-Polling Pattern

The notifier thread (`Notifier::run()`) handles LISTEN/NOTIFY and timer scheduling. Dispatchers call `fetch_*` which internally waits on `tokio::sync::Notify`. See [docs/LONG_POLLING_DESIGN.md](../docs/LONG_POLLING_DESIGN.md) for architecture details.

## Integration with Duroxide

This crate implements traits from `duroxide::providers`:
- `Provider` - core work item fetching, history management, locking
- `ProviderAdmin` - schema management, observability

### Provider Validation Tests

Duroxide provides a comprehensive validation test suite via `duroxide::provider_validation` that all providers must pass. See [tests/postgres_provider_test.rs](../tests/postgres_provider_test.rs) for the pattern:

```rust
use duroxide::provider_validation::{atomicity, error_handling, instance_locking, ...};
use duroxide::provider_validations::ProviderFactory;

// Implement ProviderFactory trait for your provider
impl ProviderFactory for PostgresProviderFactory {
    async fn create_provider(&self) -> Arc<dyn Provider> { ... }
    fn lock_timeout(&self) -> Duration { ... }
}

// Use macro to generate test wrappers
provider_validation_test!(atomicity::test_atomicity_failure_rollback);
```

Test categories: `atomicity`, `error_handling`, `instance_creation`, `instance_locking`, `lock_expiration`, `management`, `multi_execution`, `queue_semantics`. Currently 61 validation tests passing.

## Workspace Structure

- **[pg-stress/](../pg-stress/)**: Stress test binary and `PostgresStressFactory` for duroxide stress test infrastructure
- **[tests/](../tests/)**: Integration tests (basic, stress, perf, fault injection, longpoll)
- **[scripts/](../scripts/)**: Test runners and performance measurement helpers
- **[docs/](../docs/)**: Design documents for long-polling, performance analysis, proposals
