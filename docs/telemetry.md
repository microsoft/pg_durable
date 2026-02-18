# Telemetry System

## Overview

The pg_durable extension includes a modular telemetry system for publishing metrics to various monitoring backends. Metrics are automatically published every 5 seconds by the background worker.

## Metrics Published

Three gauge metrics are published, representing the current totals:

- `pg_durable.instances.started` - Total number of durable function instances started
- `pg_durable.instances.completed` - Total number of instances completed successfully
- `pg_durable.instances.failed` - Total number of instances that failed

All metrics include a `version` dimension with the extension version (e.g., `version=0.1.1`).

## Backends

### Noop/Log (Default)

The default backend logs metrics to the PostgreSQL log. This is useful for development and debugging.

Example log output:
```
METRIC: pg_durable.instances.started = 42 [version=0.1.1]
METRIC: pg_durable.instances.completed = 38 [version=0.1.1]
METRIC: pg_durable.instances.failed = 2 [version=0.1.1]
```

No configuration is required - this backend is always enabled.

### StatsD Backend

To enable StatsD telemetry, compile with the `telemetry-statsd` feature:

```bash
cargo build --features pg17,telemetry-statsd
```

The StatsD emitter sends metrics via UDP to `127.0.0.1:8125` by default. Metrics are formatted with dimensions as tags:

```
pg_durable.instances.started.version:0.1.1:42|g
```

**Dependencies**: Uses the `cadence` crate for StatsD protocol support.

### MDM/Geneva Backend

To enable Azure MDM (Geneva) telemetry, compile with the `telemetry-mdm` feature:

```bash
cargo build --features pg17,telemetry-mdm
```

The MDM emitter sends metrics via UDP to `127.0.0.1:8186` by default. Metrics are formatted as JSON with the Geneva protocol:

```
{"Account":"pg_durable_account","Namespace":"pg_durable","Metric":"pg_durable.instances.started","Dims":{"version":"0.1.1"}}:42|g
```

**Configuration**: Default account is `pg_durable_account`, namespace is `pg_durable`.

### Using Multiple Backends

You can enable both StatsD and MDM simultaneously:

```bash
cargo build --features pg17,telemetry-statsd,telemetry-mdm
```

Metrics will be published to all enabled backends.

## Implementation Details

### Architecture

The telemetry system is built using a trait-based abstraction:

```rust
pub trait MetricEmitter: Send + Sync {
    fn emit_gauge(&self, name: &str, value: i64, dimensions: &HashMap<String, String>);
}
```

Each backend implements this trait, allowing for clean separation of concerns and easy extensibility.

### Publishing Loop

The background worker spawns a separate Tokio task that:

1. Waits 5 seconds (using `tokio::time::interval`)
2. Calls `duroxide::Client::get_system_metrics()` to fetch current metrics
3. Emits each metric to all configured backends
4. Repeats until shutdown

### Error Handling

All metric emission errors are logged but never cause the background worker to crash:

```rust
if let Err(e) = self.client.gauge(&metric_name, value) {
    log!("pg_durable: StatsD emit error for {}: {}", name, e);
}
```

This ensures that monitoring issues don't affect the core functionality of the extension.

### Shutdown Behavior

The metrics publishing task monitors the same shutdown signal as the main worker loop and terminates cleanly on shutdown. The worker waits up to 2 seconds for the metrics task to complete before proceeding with final shutdown.

## Future Extensions

To add a new backend:

1. Create a new file in `src/telemetry/` (e.g., `prometheus.rs`)
2. Implement the `MetricEmitter` trait
3. Add a feature flag in `Cargo.toml` (e.g., `telemetry-prometheus`)
4. Register the backend in `src/telemetry/mod.rs::create_emitters()`

## Performance Considerations

- UDP is used for StatsD and MDM to ensure non-blocking behavior
- Sockets are set to non-blocking mode
- Metric emission happens in a separate task to avoid blocking the main worker
- The 5-second interval balances between timely metrics and system overhead

## Troubleshooting

### Metrics not appearing in logs

Check that the background worker is running:
```sql
SELECT * FROM pg_stat_activity WHERE application_name LIKE 'pg_durable%';
```

### StatsD/MDM metrics not received

1. Verify the feature was enabled during compilation
2. Check the PostgreSQL log for initialization messages:
   - `pg_durable: StatsD telemetry enabled`
   - `pg_durable: MDM telemetry enabled`
3. Verify the monitoring backend is listening on the correct port
4. Check for emission errors in the PostgreSQL log
