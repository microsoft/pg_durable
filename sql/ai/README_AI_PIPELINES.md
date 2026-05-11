# AI Pipelines Quickstart

This guide is for teammates who are new to this repo and want to run an AI pipeline demo end-to-end.

AI pipelines turn AI work into repeatable workflows: data comes in, gets prepared, moves through model-powered steps like chunking, embedding, extraction, generation, evaluation, or human review, and then lands somewhere useful. By chaining those steps into a managed process instead of one-off model calls, teams can make AI systems easier to monitor, retry, audit, and evolve as workloads grow.

You will do four things:
1. Start local PostgreSQL with pg_durable.
2. Install AI pipeline SQL functions in your database.
3. Run a demo AI pipeline.
4. Open the dashboard to see pipeline runs and step timelines.

Estimated time: 15-25 minutes.

---

## What Is In This Repo?

- `pg_durable` adds durable workflow execution inside PostgreSQL.
- `sql/ai/ai_pipeline_functions.sql` adds high-level AI pipeline SQL functions like:
  - `ai.create_pipeline(...)`
  - `ai.run(...)`
  - `ai.status(...)`
- `dashboard-v2/` is a simple UI for viewing pipeline runs and node timing.

---

## Prerequisites

### Access

1. You can clone this repo.
2. You can initialize submodules (repo includes a private submodule).

If submodule init fails, ask the repo owner for access to `microsoft/duroxide-pg-opt`.

### Local tools

Install these before you begin:
- PostgreSQL 17 (managed by pgrx in this repo)
- Rust nightly
- `cargo-pgrx` 0.16.1
- Python 3.11+ (for dashboard server)

Optional but recommended:
- Azure OpenAI credentials (needed for embedding/generation steps)

---

## 1) Clone And Initialize

```bash
git clone <your-repo-url>
cd pg_durable
git submodule update --init
```

If your org requires PAT auth for GitHub HTTPS, configure it first.

---

## 2) Start PostgreSQL With pg_durable

From repo root:

```bash
./scripts/pg-start.sh
```

This script builds and installs the extension, then starts PostgreSQL on port `28817`.

Connect with:

```bash
/home/$USER/.pgrx/17.*/pgrx-install/bin/psql -h localhost -p 28817 -U postgres -d postgres
```

If wildcard path does not expand in your shell, use the exact path printed by `./scripts/pg-start.sh`.

---

## 3) Build And Install PGVector And Azure AI Extensions

These are PostgreSQL C extensions that must be compiled and installed into your local pgrx-managed PostgreSQL **before** you can `CREATE EXTENSION` them.

### a) Find your pgrx `pg_config`

All `make install` commands below need the path to the `pg_config` binary inside your pgrx install:

```bash
# This is typically:
PG_CONFIG=~/.pgrx/17.*/pgrx-install/bin/pg_config

# Verify it resolves:
ls $PG_CONFIG
```

### b) Build and install PGVector

```bash
git clone https://github.com/pgvector/pgvector.git
cd pgvector
make PG_CONFIG=$PG_CONFIG
make install PG_CONFIG=$PG_CONFIG
cd ..
```

### c) Build and install Azure AI

```bash
git clone https://github.com/microsoft/azure-ai.git
cd azure-ai
make PG_CONFIG=$PG_CONFIG
make install PG_CONFIG=$PG_CONFIG
cd ..
```

> **Note:** If the Azure AI repo is private or internal, ask the repo owner for access.

### d) Enable the extensions in your database

If PostgreSQL is already running, restart it so it picks up the new `.so` files:

```bash
./scripts/pg-stop.sh
./scripts/pg-start.sh
```

Then in `psql`:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS azure_ai;
```

### e) Quick verify

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'azure_ai')
ORDER BY extname;
```

Expected result: two rows — `azure_ai` (2.0.0) and `vector` (0.8.0) or newer.

---

## 4) Install AI Pipeline Functions In The Database

In `psql`, run:

```sql
CREATE EXTENSION IF NOT EXISTS pg_durable;
```

Then load pipeline SQL functions from the repo root:

```sql
\i sql/ai/ai_pipeline_functions.sql
```

This creates the `ai` schema and functions such as `ai.create_pipeline`, `ai.run`, `ai.status`, `ai.explain`, and more.

Quick sanity check:

```sql
SELECT ai.list_pipelines();
```

---

## 5) Configure Azure OpenAI (Required For Embed/Generate Steps)

In `psql`:

```sql
SELECT azure_ai.set_setting('azure_openai.endpoint', 'https://<your-resource>.openai.azure.com/');
SELECT azure_ai.set_setting('azure_openai.subscription_key', '<your-subscription-key>');
```

Optional verify:

```sql
SELECT azure_ai.get_setting('azure_openai.endpoint');
```

---

## 6) Run The AI Pipeline Demo

Run the short demo script:

```sql
\i sql/ai/demo_rag_pipeline_short.sql
```

This script:
- Creates a `documents` source table.
- Creates a pipeline (`rag_pipeline`) with `chunk` + `embed` steps.
- Runs semantic vector search.
- Creates a richer pipeline example (`rag_pipeline_plus`) with extract, approval, embed, and generate steps.

Check run history:

```sql
SELECT * FROM ai.list_pipelines();
SELECT * FROM ai.status('rag_pipeline');
SELECT * FROM ai.status('rag_pipeline_plus');
```

---

## 7) Start The Dashboard

In a second terminal from repo root:

```bash
source .venv/bin/activate
PORT=8889 PG_HOST=localhost PG_PORT=28817 PG_DB=postgres python dashboard-v2/server.py
```

Open:
- `http://localhost:8889`

What to click:
1. Pick a pipeline instance on the left.
2. Open **Execution Timeline** to see per-step timing.
3. Open **Workflow Graph** to inspect node relationships.

---

## Day-1 Workflow (Recommended)

Use this sequence when demoing to non-engineers:

1. Start DB: `./scripts/pg-start.sh`
2. Start dashboard: `python dashboard-v2/server.py`
3. In `psql`, run:
   - `CREATE EXTENSION IF NOT EXISTS vector;` (must be built first — see step 3 above)
   - `CREATE EXTENSION IF NOT EXISTS azure_ai;` (must be built first — see step 3 above)

---

## Troubleshooting

### `schema "ai" does not exist`
You did not run:

```sql
\i sql/ai/ai_pipeline_functions.sql
```

### `function azure_openai.create_embeddings(...) does not exist`
`azure_ai` extension is missing or not available in your Postgres build.

Run:

```sql
CREATE EXTENSION IF NOT EXISTS azure_ai;
```

If that fails, use a Postgres environment that includes `azure_ai`.

### Dashboard opens but shows no data
- Confirm dashboard points to the right DB:
  - `PG_HOST=localhost`
  - `PG_PORT=28817`
  - `PG_DB=postgres`
- Confirm data exists:

```sql
SELECT COUNT(*) FROM df.instances;
SELECT COUNT(*) FROM df.nodes;
```

### `git submodule update --init` fails
You likely do not have access to the private submodule.
Ask the repo maintainers to grant access.

---

## Stop Everything

Stop PostgreSQL:

```bash
./scripts/pg-stop.sh
```

Stop dashboard:
- In the dashboard terminal, press `Ctrl+C`.

---

## Useful Files

- Main project overview: `README.md`
- AI function definitions: `sql/ai/ai_pipeline_functions.sql`
- Demo SQL (short): `sql/ai/demo_rag_pipeline_short.sql`
- Demo SQL (longer): `sql/ai/demo_rag_pipeline.sql`
- Dashboard server: `dashboard-v2/server.py`
- Dashboard UI: `dashboard-v2/index.html`

---

If you want this adapted for a pure copy/paste workshop handout, duplicate this file and remove the optional sections.
