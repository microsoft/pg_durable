# pg_durable

**Durable SQL Functions for PostgreSQL**

pg_durable brings durable execution to PostgreSQL. Define long-running, fault-tolerant functions entirely in SQL—no external orchestrators, no YAML, no separate deployment.

## Features

- **Durable** — Function state persists to PostgreSQL. Survives crashes, restarts, and failovers.
- **SQL-native** — Define functions in SQL using composable operators.
- **Database-aware** — First-class primitives for scheduling, conditions, and parallel execution.
- **Zero infrastructure** — Runs as a PostgreSQL extension. No Redis, no Temporal, no external services.

## Quick Example

```sql
-- A durable function that processes data in steps
SELECT durable.start(
    'SELECT id FROM documents WHERE processed = false LIMIT 100' |=> 'batch'
    ~> 'UPDATE documents SET processed = true WHERE id = ANY($batch)'
);
```

## How It Works

1. **Define functions in SQL** using composable operators like `~>` (sequence) and `|=>` (name result)
2. **Start functions** with `durable.start()` which returns an instance ID
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

- [User Guide](USER_GUIDE.md) — Complete usage guide with examples
- [MVP Guide](docs/pg_durable_mvp.md) — Implementation details and internals

## Architecture

pg_durable consists of:

1. **SQL DSL Layer** — Operators that build function graphs
2. **Duroxide Runtime** — Background worker that executes functions durably
3. **PostgreSQL Tables** — Store function definitions, state, and history

The runtime is powered by [duroxide](https://github.com/anthropics/duroxide), a durable task framework for Rust.

```
┌────────────────────────────────────────────────────────────────┐
│                         PostgreSQL                             │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                pg_durable Extension (pgrx)               │  │
│  │                                                          │  │
│  │   DSL:  'sql' |=> 'name' ~> 'sql2'                      │  │
│  │   Functions: durable.if() | durable.join() | durable.loop() │
│  │                                                          │  │
│  │   Duroxide Runtime (background worker)                   │  │
│  │   • Polls for work, executes functions, checkpoints     │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  durable schema: nodes | instances | (duroxide internals)     │
└────────────────────────────────────────────────────────────────┘
```

## Status

🚧 **Early Development** — Not yet ready for production use.

## License

MIT
