# Duroxide PostgreSQL Provider

A PostgreSQL-based provider implementation for [Duroxide](https://github.com/microsoft/duroxide), a durable task orchestration framework for Rust.

> **Note:** See [CHANGELOG.md](CHANGELOG.md) for version history and breaking changes.

## Installation

Add to your `Cargo.toml`:

```toml
[dependencies]
duroxide-pg = "0.1"
```

## Usage

```rust
use duroxide_pg::PostgresProvider;
use duroxide::Worker;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Create a provider with the database URL
    let provider = PostgresProvider::new("postgres://user:password@localhost:5432/mydb").await?;

    // Use with a Duroxide worker
    let worker = Worker::new(provider);
    // ... register orchestrations and activities, then run
    
    Ok(())
}
```

### Custom Schema

To isolate data in a specific PostgreSQL schema:

```rust
let provider = PostgresProvider::new_with_schema(
    "postgres://user:password@localhost:5432/mydb",
    Some("my_schema"),
).await?;
```

## Configuration

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `DUROXIDE_PG_POOL_MAX` | Maximum connection pool size | `10` |

## Features

- **Automatic schema migration** on startup - see [Schema Migrations](docs/schema_migrations.md)
- Connection pooling via sqlx
- Custom schema support for multi-tenant isolation
- Full implementation of the Duroxide `Provider` and `ProviderAdmin` traits
- Poison message detection with attempt count tracking
- Lock renewal for long-running orchestrations and activities

## Latest Release (0.1.18)

- Updated to duroxide 0.1.20 — custom status now uses history events instead of metadata
- `short_poll_threshold()` configurable via ProviderFactory (resolves duroxide #51)
- New validation test: `test_orphan_activity_after_instance_force_deletion`
- See [CHANGELOG.md](CHANGELOG.md) for full version history

## License

MIT License - see [LICENSE](LICENSE) for details.
