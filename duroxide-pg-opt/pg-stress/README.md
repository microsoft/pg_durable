# PostgreSQL Provider Stress Tests

This package contains stress tests for the `duroxide-pg` PostgreSQL provider implementation.

## Quick Start

### Run Stress Tests via Script (Recommended)

```bash
# From workspace root

# Run all stress tests (integration tests + pg-stress binary)
./scripts/run-stress-tests.sh

# Run only pg-stress binary tests (parallel + large-payload)
./scripts/run-stress-tests.sh pg-stress

# Run only pg-stress parallel test
./scripts/run-stress-tests.sh pg-stress-parallel

# Run only pg-stress large-payload test
./scripts/run-stress-tests.sh pg-stress-payload
```

### Run pg-stress Binary Directly

```bash
# Run parallel orchestrations test (default)
cargo run --release --package duroxide-pg-stress --bin pg-stress

# Run large payload test
cargo run --release --package duroxide-pg-stress --bin pg-stress -- --test-type large-payload

# Run all stress tests
cargo run --release --package duroxide-pg-stress --bin pg-stress -- --test-type all

# Custom duration (seconds)
cargo run --release --package duroxide-pg-stress --bin pg-stress -- --duration 30 --test-type all
```

### Run via Test Harness

```bash
# Run all stress tests (ignored by default)
cargo test --test stress_tests -- --ignored

# Run specific test
cargo test --test stress_tests -- --ignored stress_test_parallel_orchestrations_light
```

## Stress Test Types

### Parallel Orchestrations Test

Tests fan-out/fan-in pattern with concurrent orchestrations:
- 20 max concurrent orchestrations
- 5 activities per orchestration (fan-out)
- 10ms simulated activity delay
- Validates throughput and latency under load

### Large Payload Test

Tests memory consumption and history management with large event payloads:
- 5 max concurrent orchestrations
- Large event payloads (10KB, 50KB, 100KB)
- Moderate-length histories (~80-100 events per instance)
- 20 activities + 5 sub-orchestrations per instance
- Validates memory allocation patterns and history handling

## Configuration

### Environment Variables

- `DATABASE_URL`: PostgreSQL connection string (required)
- `PG_STRESS_DURATION`: Test duration in seconds (default: 10)
- `DUROXIDE_PG_POOL_MAX`: Connection pool size per provider (default: 10)
- `RUST_LOG`: Log level (default: info)

### Test Configurations

| Test | Duration | Concurrent | Tasks | Dispatchers |
|------|----------|------------|-------|-------------|
| Light | 5s | 10 | 3 | 2:2 |
| Standard | 10s | 20 | 5 | 2:2 |
| High Concurrency | 30s | 50 | 10 | 4:4 |
| Long Duration | 300s | 20 | 5 | 2:2 |

## Resource Monitoring

The stress test script includes resource monitoring that tracks:
- **Peak RSS (MB)**: Maximum resident set size during test
- **Average CPU (%)**: Mean CPU utilization during test

Monitoring is enabled by default when running via `./scripts/run-stress-tests.sh`.

## Expected Performance

### Local PostgreSQL (Docker)

| Config | Throughput | Latency | Success Rate |
|--------|------------|---------|--------------|
| 1:1 | 12-15 orch/sec | 60-80ms | 100% |
| 2:2 | 18-25 orch/sec | 50-70ms | 100% |
| 4:4 | 20-35 orch/sec | 60-90ms | 100% |

### Remote Azure PostgreSQL

| Config | Throughput | Latency | Success Rate |
|--------|------------|---------|--------------|
| 1:1 | 3-6 orch/sec | 150-250ms | 100% |
| 2:2 | 5-10 orch/sec | 120-200ms | 100% |
| 4:4 | 6-12 orch/sec | 100-180ms | 100% |

## Result Tracking

Results are automatically saved to files named by database hostname:
- `stress-test-results-localhost.md` - Local Docker PostgreSQL
- `stress-test-results-duroxide-pg.md` - Azure PostgreSQL
- `stress-test-results-<hostname>.md` - Other databases

This allows tracking performance separately for different database environments.

## Troubleshooting

### Connection Pool Exhaustion

If you see `PoolTimedOut` errors:
- Reduce concurrent orchestrations: `max_concurrent`
- Increase pool size: `DUROXIDE_PG_POOL_MAX=20`
- Check Azure PostgreSQL connection limit

### Low Throughput

If throughput is below expected range:
- Check network latency to database
- Verify stored procedures are being used (check logs)
- Increase dispatcher concurrency: `orch_concurrency`, `worker_concurrency`

### Test Timeouts

If orchestrations don't complete:
- Increase test duration
- Check runtime dispatchers are running
- Verify database connectivity

## Architecture

The stress test framework validates:
- **Correctness**: 100% success rate, zero infrastructure failures
- **Performance**: Throughput and latency under load
- **Scalability**: Behavior with increased concurrency
- **Stability**: Sustained performance over long runs

Each test:
1. Creates a unique PostgreSQL schema
2. Launches concurrent orchestrations (fan-out pattern)
3. Each orchestration fans out to N activities
4. Measures completion rate, throughput, and latency
5. Cleans up schema after completion

