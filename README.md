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
SELECT df.start(
    'SELECT id FROM documents WHERE processed = false LIMIT 100' |=> 'batch'
    ~> 'UPDATE documents SET processed = true WHERE id = ANY($batch)'
);
```

## How It Works

1. **Define functions in SQL** using composable operators like `~>` (sequence) and `|=>` (name result)
2. **Start functions** with `df.start()` which returns an instance ID
3. **Runtime executes durably** — each step is checkpointed, survives crashes via replay
4. **Query progress** anytime from standard PostgreSQL tables

## Prerequisites

- PostgreSQL 17
- Rust (nightly)
- [cargo-pgrx](https://github.com/pgcentralfoundation/pgrx) 0.16.1

## Development Installation

### GitHub Codespace

The main branch prebuild installs PostgreSQL 17, builds `pg_durable`, and prepares a local cluster under `~/.pgrx` with the extension ready. PostgreSQL is not left running, so start it when you begin working.

```bash
# Start PostgreSQL
./scripts/pg-start.sh

# Connect
~/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -d postgres
```

On a branch without a ready prebuild, run `pg-start.sh` — it will build and install the extension on first run (expect a few minutes):

```bash
./scripts/pg-start.sh
```

### Other environments

#### Local and Dev Container

A VS Code Dev Container (`.devcontainer/`) provides Rust, cargo-pgrx, and PostgreSQL 17 pre-installed. For a bare local machine, install the toolchain first by following the steps in `.devcontainer/onCreateCommand.sh`.

```bash
# Build, initialize PostgreSQL, and install the extension
# This takes a while - go do something else
./scripts/pg-start.sh

# Connect to the local pgrx PostgreSQL instance
~/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -d postgres
```

`pg-start.sh` bootstraps new local data directories with a `postgres` superuser and also creates a matching superuser role for the current OS user, so default local `psql` usage continues to work. Use `-U postgres` if you want to force the canonical bootstrap role explicitly.

#### Docker

```bash
# Build and test
./scripts/test-e2e-docker.sh --rebuild

# Optional: Deploy to ACR (for custom PG17 image with pg_durable baked-in)
./scripts/deploy-acr.sh
```

## Multi-User Setup

`CREATE EXTENSION pg_durable` does **not** grant any privileges to `PUBLIC`. After installing the extension, the admin must explicitly grant access to application roles. Row-level security (RLS) ensures each user can only see and manage their own durable function instances and nodes.

**Grant privileges to an application role:**

```sql
-- Grant to specific roles after CREATE EXTENSION
SELECT df.grant_usage('app_role');
```

Alternatively, create an indirection role and grant membership to application roles:

```sql
-- Create a shared role for pg_durable access
CREATE ROLE pg_durable_user NOLOGIN;
SELECT df.grant_usage('pg_durable_user');

-- Grant membership to application roles
GRANT pg_durable_user TO app_backend, etl_service;
```

> See the [User Guide — Privilege Grants](USER_GUIDE.md#privilege-grants) section for the full list of individual grants, revoking access, and hardening upgraded installs.

> **Note:** `GRANT EXECUTE ON ALL FUNCTIONS` only applies to functions that exist when the grant runs. After upgrading pg_durable with `ALTER EXTENSION pg_durable UPDATE`, re-run `df.grant_usage('role')` (or re-issue the manual grants) so new functions are accessible.

**Key points:**
- The background worker role (`pg_durable.worker_role` GUC, default: `azuresu`) **must be a superuser** — it bypasses RLS to manage all users' instances
- Users get `SELECT` + `INSERT` on `df.instances` / `df.nodes`, column-level `UPDATE (status, updated_at)` on instances for `df.cancel()`
- Identity column (`submitted_by`) cannot be modified by users
- **`df.vars` uses per-user scoping** — each user has their own variable namespace via an `owner` column and RLS. Superusers bypass RLS but DSL functions still scope to the calling user via explicit filters. Avoid storing secrets in plain text

## Continuous Integration

All pull requests must pass the following checks before merging:

1. **Format Check** — `cargo fmt --check`
2. **Clippy & Tests** — `cargo clippy`, unit tests (`cargo pgrx test pg17`), pg_regress tests, and E2E tests

The CI workflow is defined in [.github/workflows/ci.yml](.github/workflows/ci.yml). It uses pgrx to download and manage PostgreSQL.

## Testing

pg_durable has two test suites:

### pg_regress Tests (Standard PostgreSQL Regression Tests)

Fast, deterministic tests for core DSL functionality using PostgreSQL's standard testing framework.
Test SQL lives in `sql/`, expected output in `expected/`, and PGXS is configured in the root `Makefile`.

```bash
make test-regress          # full reset + run
make installcheck          # run only (PostgreSQL must already be running)
```

### E2E Tests (Comprehensive Scenario Tests)

Complex local integration tests with pgrx PostgreSQL:

```bash
./scripts/test-e2e-local.sh                                                  # All local SQL E2E tests, including special restart/config phases
./scripts/test-e2e-local.sh 04_parallel                                      # Specific test
./scripts/test-e2e-local.sh --default-build-phases                            # Only the default-build phase group
```

See [tests/e2e/](tests/e2e/) for details.

## Documentation

- [User Guide](USER_GUIDE.md) — Complete usage guide with examples
- [MVP Guide](docs/pg_durable_mvp.md) — Implementation details and internals
- [Examples](examples/README.md) — Example conventions and smoke-check guidance

## Architecture

pg_durable consists of:

1. **SQL DSL Layer** — Operators that build function graphs
2. **Duroxide Runtime** — Background worker that executes functions durably
3. **PostgreSQL Tables** — Store function definitions, state, and history

The runtime is powered by [duroxide](https://github.com/microsoft/duroxide), a durable task framework for Rust.

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
│  df schema: nodes | instances | (duroxide internals)          │
└────────────────────────────────────────────────────────────────┘
```

## Status

🚧 **Early Development** — Not yet ready for production use.

## License

PostgreSQL License
