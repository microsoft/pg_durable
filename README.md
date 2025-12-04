# pg_durable

**SQL-native durable workflows for PostgreSQL**

pg_durable brings durable execution to PostgreSQL. Author long-running, fault-tolerant workflows entirely in SQL—no external orchestrators, no YAML, no separate deployment.

## Features

- **Durable** — Workflow state persists to PostgreSQL. Survives crashes, restarts, and failovers.
- **SQL-native** — Author workflows in SQL using composable functions and operators.
- **Database-aware** — First-class primitives for waiting on idle, replica lag, table conditions.
- **Zero infrastructure** — Runs as a PostgreSQL extension. No Redis, no Temporal, no external services.

## Quick Example

```sql
-- A workflow that processes data only when the database is idle
SELECT durable.start(
    durable.sql('SELECT id FROM documents WHERE processed = false LIMIT 100') => 'batch'
    ~> durable.sql('UPDATE documents SET processed = true WHERE id = ANY($1)', $batch.rows[*].id)
);
```

## How It Works

1. **Define workflows in SQL** using composable functions like `durable.sql()`, `durable.then()`, `durable.as()`
2. **Start workflows** with `durable.start()` which returns an instance ID
3. **Runtime executes durably** — each step is checkpointed, survives crashes via replay
4. **Query progress** anytime from standard PostgreSQL tables

## Installation

```bash
# Build and install the extension
cargo pgrx install --release

# In PostgreSQL
CREATE EXTENSION pg_durable;
```

## Documentation

- [Full Specification](docs/pg_durable_spec.md) — Complete API reference and design
- [MVP Plan](docs/pg_durable_mvp.md) — Implementation roadmap and examples

## Architecture

pg_durable consists of:

1. **SQL DSL Layer** — Functions and operators that build workflow graphs
2. **duroxide Runtime** — Background worker that executes workflows durably
3. **PostgreSQL Tables** — Store workflow definitions, state, and history

The runtime is powered by [duroxide](https://github.com/affandar/duroxide), a durable task framework for Rust.

```
┌─────────────────────────────────────────────────────────────────┐
│                        PostgreSQL                                │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                 pg_durable Extension (pgrx)                 │ │
│  │                                                              │ │
│  │   SQL DSL:  durable.sql() | durable.then() | durable.as()  │ │
│  │   Operators: ~> (then) | => (as) | & (join) | | (race)     │ │
│  │                                                              │ │
│  │   duroxide Runtime (background worker)                      │ │
│  │   • Polls for work, executes workflows, checkpoints state  │ │
│  │                                                              │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  durable schema: duro_nodes | duro_instances | duro_history    │
└─────────────────────────────────────────────────────────────────┘
```

## Status

🚧 **Early Development** — Not yet ready for production use.

See the [MVP plan](docs/pg_durable_mvp.md) for current implementation status.

## License

Apache 2.0
