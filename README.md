<div align="center">

<img src="docs/website/lockup_arrow_dark.svg" alt="pg_durable logo" width="560" />

[Website](https://microsoft.github.io/pg_durable/) · [Docs](docs/) · [Quick Example](#quick-example) · [GitHub](https://github.com/microsoft/pg_durable)

[![License](https://img.shields.io/badge/license-PostgreSQL%20License-3d86c6.svg)](LICENSE.txt)
[![PostgreSQL 17 & 18](https://img.shields.io/badge/PostgreSQL-17%20%26%2018-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)

## Durable Execution inside PostgreSQL

</div>

Long-running, fault-tolerant SQL functions for teams that already keep their state in Postgres and want to stop stitching together cron jobs, workers, queues, and status tables to make background work reliable. Define the workflow in SQL, let pg_durable checkpoint each step, and resume after crashes, restarts, or failed steps.

Durable execution is now a standard industry pattern, and pg_durable brings it inside Postgres with no extra service infrastructure required. Part of our mission to bring compute close to data.

> <img src="https://cdn-dynmedia-1.microsoft.com/is/content/microsoftcorp/1374850-Icon-Hero-HorizonDB-24x24?resMode=sharp2&op_usm=1.5,0.65,15,0&wid=48&hei=48&qlt=100&fit=constrain" alt="Azure HorizonDB logo" width="24" /> <strong>Try pg_durable now in <a href="https://aka.ms/AzureHorizonDB">Azure HorizonDB</a>,</strong> Microsoft's new PostgreSQL cloud service engineered for performance and built with <a href="https://aka.ms/horizondb_pg_durable">pg_durable inside</a>

## Is this for me?

### Who it's for

- Backend and data engineers who want workflows to live next to the data they touch.
- DBAs and SREs automating runbooks that must survive restarts and be auditable in SQL.
- Teams building data or AI pipelines that need durable execution per row, document, or batch.

### The core idea

A pg_durable function is a graph of SQL steps that PostgreSQL executes and checkpoints as it goes. If the database crashes, restarts, or a step fails, execution resumes from the last durable checkpoint instead of making you reconstruct state by hand.

<div align="center">

<img src="docs/website/workflow-graph.svg" alt="A durable function fans out into three parallel queries — count users, count orders, sum revenue — that join into a dashboard step" width="450" />

</div>

### Workloads this is useful for

- Vector embedding pipelines: chunk, call an embedding API, and upsert into `pgvector`.
- Ingest pipelines: stage, deduplicate, transform, and publish large batches.
- Scheduled maintenance: detect bloat, notify, wait for approval, then run the next action.
- Fan-out aggregation: run independent queries in parallel, then join the results.
- External API workflows: enrichment, classification, and webhook-style calls from SQL.

### What you're probably doing today instead

- `pg_cron` plus a jobs table, status columns, retry counters, and a polling worker.
- An external orchestrator such as Airflow, Temporal, Step Functions, or Argo calling back into Postgres.
- A queue plus workers plus a separate state table to coordinate retries and partial completion.
- A `plpgsql` procedure that works until a crash or long-running transaction forces you to start over.

### Pain points it addresses

- A restart in the middle of a long job means rerunning work that already succeeded.
- One failed row or one failed API call turns into manual cleanup and uncertain replay.
- Long transactions hold locks, grow WAL, and make batch jobs fragile at larger scale.
- Parallel work in the app tier creates more places for partial-failure bugs and drift.
- The workflow logic ends up spread across SQL, workers, queues, dashboards, and status tables.

### What changes in your architecture

- The workflow definition moves into SQL and starts with `df.start(...)`.
- Retry state, progress tracking, and checkpointing move into Postgres instead of bespoke app code.
- Some app-tier workers, queue consumers, or scheduler glue can disappear entirely.
- Operational visibility comes from Postgres tables such as `df.instances`, using the same auth and backup model as your data.

### When not to use it

- The job is already a single `INSERT ... SELECT` or one ordinary SQL statement.
- You need sub-millisecond synchronous request handling rather than durable background execution.
- You cannot install extensions or run a background worker in your Postgres environment.
- The workflow mostly lives outside Postgres and spans many heterogeneous systems.
- You need arbitrary application logic that does not map cleanly to SQL steps, branching, loops, or HTTP calls.

### How it works

1. Define a workflow in SQL using composable operators such as `~>` and `|=>`.
2. Start it with `df.start()` and get back an instance ID.
3. Let the runtime execute each step durably with checkpointing between steps.
4. Query status and results from PostgreSQL while the workflow runs or after it completes.

### Limitations

The model is intentionally SQL-shaped. If a step needs arbitrary code, a non-HTTP SDK, or rich in-memory control flow, you may need to wrap that logic in a SQL function, expose it behind an HTTP endpoint for `df.http()`, or use a general-purpose orchestrator for that part of the system.

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

## Packages

Tagged releases publish Debian packages for PostgreSQL 17 and 18 on amd64 from the GitHub release assets. Packages are named `pg-durable-postgresql-<PG major>_<pg_durable version>-1_<arch>.deb` and install the extension library, control file, and SQL upgrade files into the matching PostgreSQL installation directories.

Tagged releases also publish a ready-to-run multi-arch (`linux/amd64`, `linux/arm64`) Docker image to GitHub Container Registry: `ghcr.io/microsoft/pg_durable`. Each release publishes immutable `X.Y.Z-pg17`, `vX.Y.Z-pg17`, and `sha-<commit>-pg17` tags; the highest stable release additionally updates the floating `pg17` and `latest` tags. The PG major version is part of each tag so future PostgreSQL versions (for example `pg18`) can be published alongside.

> **Warning:** The published Docker image is built with the `http-allow-all` Cargo feature (all SSRF / outbound-HTTP protections disabled) and other test-friendly defaults. It is intended for **evaluating and learning pg_durable only — do not use it in production.** For production, install the Debian package, which is built with a restrictive HTTP allow-list feature (`http-allow-azure-domains`).

After installing a package, add `pg_durable` to `shared_preload_libraries`, restart PostgreSQL, and create the extension in the configured pg_durable database:

```sql
CREATE EXTENSION pg_durable;
```

The default pg_durable database is `postgres`; see [User Guide](USER_GUIDE.md) for background worker configuration and privilege setup.

Release assets also include source archives for building from source.

## Development Installation

### Prerequisites

- PostgreSQL 17 or 18
- Rust (nightly)
- [cargo-pgrx](https://github.com/pgcentralfoundation/pgrx) 0.16.1

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
# Pull prebuilt image (extension preloaded and created on first init)
# NOTE: testing/learning image only — not for production (see Packages section).
docker run -d --name pg_durable \
  -p 5432:5432 \
  -e POSTGRES_PASSWORD=secret \
  ghcr.io/microsoft/pg_durable:latest

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
- The background worker role (`pg_durable.worker_role` GUC, default: `postgres`) **must be a superuser** — it bypasses RLS to manage all users' instances
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

pg_durable is a PostgreSQL extension (built with [pgrx](https://github.com/pgcentralfoundation/pgrx)) — everything runs inside the PostgreSQL server, no external services. The extension exposes a SQL DSL for building function graphs and registers a background worker that executes them durably on top of two lower-level Rust libraries:

- [duroxide](https://github.com/microsoft/duroxide) — a durable task framework providing the orchestration runtime (deterministic replay, checkpoints, sub-orchestrations, timers).
- [duroxide-pg](https://github.com/microsoft/duroxide-pg) — a PostgreSQL-backed state provider for duroxide. It persists runtime state (instances, history, work queues) in a dedicated `duroxide.*` schema owned by the extension.

```
┌────────────────────────────────────────────────────────────────────┐
│                             PostgreSQL                             │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                 pg_durable extension (pgrx)                  │  │
│  │                                                              │  │
│  │  SQL DSL     'sql' |=> 'name' ~> 'sql2'                      │  │
│  │              df.if() | df.join() | df.loop()                 │  │
│  │                                                              │  │
│  │  Background worker (hosts the duroxide runtime in-process)   │  │
│  │  ┌────────────────────────────────────────────────────────┐  │  │
│  │  │  duroxide        (orchestration runtime)               │  │  │
│  │  │  ┌──────────────────────────────────────────────────┐  │  │  │
│  │  │  │  duroxide-pg   (PostgreSQL state provider)       │  │  │  │
│  │  │  └──────────────────────────────────────────────────┘  │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  Schemas                                                           │
│    df.*         DSL graphs (nodes, instances, vars)                │
│    duroxide.*   runtime state (owned by duroxide-pg)               │
└────────────────────────────────────────────────────────────────────┘
```

If you'd rather author durable functions in Rust, Python, or Node while still persisting state in PostgreSQL, you can use duroxide and duroxide-pg directly from your host language — pg_durable is what you'd build on top of that pair when you'd prefer authoring in SQL.

## Status

**Preview** - This project is currently in preview.

## Support

Use GitHub Issues for bug reports and feature requests. Do not report security vulnerabilities through public GitHub issues; follow the instructions in [SECURITY.md](SECURITY.md) instead.

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information, see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with questions or comments.

## Security

Microsoft takes the security of our software products and services seriously. Please do not report security vulnerabilities through public GitHub issues. See [SECURITY.md](SECURITY.md) for security reporting instructions.

## Privacy and Telemetry

pg_durable does not send telemetry to Microsoft.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those third-party policies.

## License

PostgreSQL License
