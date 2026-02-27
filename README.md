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

### GitHub SSH Access (Required)

This project depends on a private repository (`microsoft/duroxide-pg-opt`) via SSH. You need SSH access to the Azure GitHub organization.

1. **Set up SSH key** with GitHub: https://docs.github.com/en/authentication/connecting-to-github-with-ssh
2. **Authorize SSO** for the Azure organization on your SSH key
3. **Configure Cargo** to use git CLI for fetching (required for SSH agent authentication):

```bash
# Add to ~/.cargo/config.toml
mkdir -p ~/.cargo
echo '[net]
git-fetch-with-cli = true' >> ~/.cargo/config.toml
```

4. **Verify SSH access**:

```bash
git ls-remote ssh://git@github.com/microsoft/duroxide-pg-opt.git
```

5. **For Docker builds**, create a `.env` file in the project root with a GitHub PAT:

```bash
# .env (gitignored)
GITHUB_TOKEN=ghp_your_token_here
```

## Installation

### Local Development

```bash
# Build and install the extension
cargo pgrx install --release --pg-config $(cargo pgrx info pg-config pg17)

# In PostgreSQL
CREATE EXTENSION pg_durable;
```

### Docker

```bash
# Build and test (requires .env with GITHUB_TOKEN)
./scripts/test-e2e-docker.sh --rebuild

# Optional: Deploy to ACR (for custom PG17 image with pg_durable baked-in)
./scripts/deploy-acr.sh
```

## Continuous Integration

All pull requests must pass the following checks before merging:

1. **Format Check** — `cargo fmt --check`
2. **Clippy & Tests** — `cargo clippy`, unit tests (`cargo pgrx test pg17`), pg_regress tests, and E2E tests

The CI workflow is defined in [.github/workflows/ci.yml](.github/workflows/ci.yml). It uses pgrx to download and manage PostgreSQL.

## Testing

pg_durable has two test suites:

### pg_regress Tests (Standard PostgreSQL Regression Tests)

Fast, deterministic tests for core DSL functionality using PostgreSQL's standard testing framework:

```bash
cd test/regress
make installcheck
```

See [test/regress/README.md](test/regress/README.md) for details.

### E2E Tests (Comprehensive Scenario Tests)

Complex integration tests with Docker:

```bash
./scripts/test-e2e-local.sh              # All tests
./scripts/test-e2e-local.sh 04_parallel  # Specific test
```

See [tests/e2e/](tests/e2e/) for details.

## Verifying Duroxide Migrations

pg_durable includes checked-in copies of duroxide-pg-opt migration SQL files to ensure the extension owns the duroxide schema. To verify these copies match upstream:

```bash
# Clone duroxide-pg-opt at the repository root
git clone --branch pinodeca/initialization \
  https://github.com/microsoft/duroxide-pg-opt.git

# Verify migrations match upstream
./scripts/verify-duroxide-migrations.sh
```

**When to verify:**
- After updating the `duroxide-pg-opt` dependency in Cargo.toml
- When contributing changes to pg_durable
- CI automatically verifies on every pull request

**Note:** The verification script requires the `duroxide-pg-opt` repository to be cloned at the root of the pg_durable repository.

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
│  df schema: nodes | instances | (duroxide internals)          │
└────────────────────────────────────────────────────────────────┘
```

## Status

🚧 **Early Development** — Not yet ready for production use.

## License

MIT
