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

### GitHub Access (Required)

This project includes `microsoft/duroxide-pg-opt` as a git submodule. You need access to this private repository.

1. **Create a fine-grained GitHub PAT** scoped only to `microsoft/duroxide-pg-opt` (minimum permission: `Contents: Read`): https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
2. **If your organization enforces SAML SSO, ensure org access is approved for the token.** For fine-grained PATs, this is handled in the org/resource-owner approval flow (not the classic PAT "Configure SSO" button).
3. **Store the PAT in a credential helper** (recommended over PAT-in-URL rewrite rules). If your environment sets `GITHUB_TOKEN` or `GH_TOKEN` (for example, Codespaces), temporarily unset them for this step so `gh` stores your PAT:

```bash
read -rsp "GitHub PAT: " GH_PAT; echo
printf '%s\n' "$GH_PAT" | env -u GITHUB_TOKEN -u GH_TOKEN gh auth login --hostname github.com --git-protocol https --with-token
unset GH_PAT
env -u GITHUB_TOKEN -u GH_TOKEN gh auth setup-git
```

4. **Scope credential helper usage to the submodule URL path** (so this PAT is used only for `duroxide-pg-opt`):

```bash
git config --global credential."https://github.com/microsoft/duroxide-pg-opt.git".helper '!env -u GITHUB_TOKEN -u GH_TOKEN gh auth git-credential'
git config --global credential."https://github.com/microsoft/duroxide-pg-opt.git".useHttpPath true
```

5. **Initialize the submodule** after cloning. In environments like Codespaces, run with explicit helper settings so injected tokens/askpass do not override your PAT:

```bash
git submodule sync --recursive
env -u GITHUB_TOKEN -u GH_TOKEN -u GIT_ASKPASS \
    git -c credential.helper='!env -u GITHUB_TOKEN -u GH_TOKEN gh auth git-credential' \
            -c credential.useHttpPath=true \
            submodule update --init --recursive
```

6. **Persist submodule auth settings for normal git commands** (so `git fetch` works later in new shells):

```bash
cd duroxide-pg-opt
git config --local credential.helper ''
git config --local --add credential.helper '!env -u GITHUB_TOKEN -u GH_TOKEN gh auth git-credential'
git config --local credential.useHttpPath true
git config --local core.askPass ''
```

This avoids storing PATs in git URL rewrite settings such as:

```bash
git config --global url."https://<YOUR_PAT>@github.com/microsoft/duroxide-pg-opt".insteadOf "https://github.com/microsoft/duroxide-pg-opt"
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
# Build and test
./scripts/test-e2e-docker.sh --rebuild

# Optional: Deploy to ACR (for custom PG17 image with pg_durable baked-in)
./scripts/deploy-acr.sh
```

### Multi-User Setup

`CREATE EXTENSION pg_durable` automatically grants permissions to `PUBLIC`, so any database role can use the `df.*` functions immediately. Row-level security (RLS) ensures each user can only see and manage their own durable function instances and nodes.

**No manual grants needed.** If you want to restrict access to specific roles instead of all users:

```sql
-- Revoke the default PUBLIC grants
REVOKE ALL ON SCHEMA df FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA df FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA df FROM PUBLIC;

-- Grant to specific roles only
GRANT USAGE ON SCHEMA df TO app_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO app_role;
GRANT SELECT, INSERT ON df.instances TO app_role;
GRANT UPDATE (status, updated_at) ON df.instances TO app_role;
GRANT SELECT, INSERT ON df.nodes TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO app_role;
```

**Key points:**
- The background worker role (`pg_durable.worker_role` GUC, default: `azuresu`) **must be a superuser** — it bypasses RLS to manage all users' instances
- Users get `SELECT` + `INSERT` on `df.instances` / `df.nodes`, column-level `UPDATE (status, updated_at)` on instances for `df.cancel()`
- Identity columns (`submitted_by`, `login_role`) cannot be modified by users
- **`df.vars` is currently a shared global table with no per-user isolation** — any role can read or overwrite any other user's variables. Do not store secrets in `df.vars`. Per-user scoping is planned. In multi-tenant environments, consider revoking `df.vars` grants from `PUBLIC`

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

Complex integration tests with Docker:

```bash
./scripts/test-e2e-local.sh              # All tests
./scripts/test-e2e-local.sh 04_parallel  # Specific test
```

See [tests/e2e/](tests/e2e/) for details.

## Verifying Duroxide Migrations

pg_durable includes checked-in copies of duroxide-pg-opt migration SQL files to ensure the extension owns the duroxide schema. The `duroxide-pg-opt` submodule provides the upstream source. To verify the copies match:

```bash
# Ensure the submodule is initialized
git submodule update --init

# Verify migrations match upstream
./scripts/verify-duroxide-migrations.sh
```

**When to verify:**
- After updating the `duroxide-pg-opt` submodule to a new commit
- When contributing changes to pg_durable
- CI automatically verifies on every pull request

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
