# pg_durable — SQL-Native Durable Workflows for PostgreSQL

## Overview

| Field | Value |
|------|------|
| **Program Manager** | Abe Omorogbe |
| **Engineering Manager** |  Krishnakumar Ravi (KK) |
| **Engineer** | Pino de Candia |
| **Azure DevOps Feature ID** | FEATURE TBD |
| **Status** | Draft |
| **Last Modified** | 02/18/2026 |

---

## What & Why

pg_durable brings **durable execution** directly into PostgreSQL — enabling long-running, fault-tolerant workflows authored entirely in SQL, with no external orchestrators, YAML, or separate deployments.

Modern applications need workflows that:
- **Survive failures** — a crashed process shouldn't lose hours of work
- **Span long durations** — wait for human approval, schedule nightly jobs, retry for days
- **Coordinate complex operations** — fan-out/fan-in, conditional branching, parallel execution
- **React to database state** — wait for idle, check replica lag, respond to triggers

Today's solutions (Temporal, Airflow, Step Functions) require external infrastructure, languages, and deployment complexity. For database-centric workloads, **the database itself is the natural home for this logic**.

pg_durable is the **backend runtime** that can power higher-level products like **AI Pipelines** — providing the durable execution, state management, and crash recovery they depend on.

---

## Release Phasing: pg_durable vs. AI Pipelines

pg_durable and AI Pipelines are **two separate releases** with distinct scopes. AI-specific functionality (chunking, embedding, LLM calls) is **purposely descoped** from the pg_durable release.

### Phase 1 — pg_durable (Current)

| Item | Detail |
|------|--------|
| **What ships** | pg_durable extension + solution accelerator |
| **Included scenarios** | 5–7 starter scenarios (basic SQL workflows: ETL, scheduling, parallel aggregation, conditional logic, etc.) |
| **Scope** | General-purpose durable SQL execution — no AI-specific primitives |
| **Deliverable** | Getting-started guide with working SQL examples users can run immediately |

### Phase 2 — AI Pipelines (Future)

| Item | Detail |
|------|--------|
| **What ships** | AI Pipeline DSL + Python SDK, built on top of pg_durable |
| **Experience** | Top-down, SDK-first — users define pipelines declaratively, not raw SQL |
| **VS Code integration** | Pipeline monitoring and management in the PostgreSQL extension |
| **New primitives** | Built-in chunking, retry logic, email extensions, human-in-the-loop approval |

### Why We Descoped AI from pg_durable

We intentionally separated these releases to:

1. **Get the real AI pipeline experience right** — AI pipelines need a top-down, SDK-first experience, not raw SQL. We need to understand the missing primitives (chunking, retry, approval workflows) before baking them into the runtime.
2. **Avoid unmaintainable AI scenarios** — AI scenarios in a pure SQL extension require significant code, custom retry logic, and model-specific handling. These belong in the AI Pipelines layer where they can be properly abstracted.
3. **Deliver a clean, general-purpose runtime first** — pg_durable should stand on its own as a durable execution engine. Customers like Walmart can be pointed directly to the AI Pipeline product without needing to learn SQL DSL internals.
4. **First-class operators over workarounds** — Patterns like agent approval workflows, email notifications, and tool-use loops need dedicated operators, not SQL hacks. Those operators will ship with AI Pipelines.

---

## Customer Evidence

**TODO**: Summary of customer interviews

---

## Goals

- **SQL-native DSL** — composable functions and operators (`~>`, `|=>`, `&`, `|`) to author workflows in plain SQL
- **Durable execution** — workflow state persisted to PostgreSQL; survives crashes, restarts, and failovers
- **Database-aware primitives** — first-class support for idle detection, replica lag, triggers, and table conditions
- **Zero external dependencies** — runs as a PostgreSQL background worker; no sidecar services
- **Foundation for AI Pipelines** — provides the execution engine that AI Pipelines will build on top of (separate release)
- **Solution accelerator** — ships with 5–7 starter scenarios covering common SQL workflow patterns
- **Lightweight monitoring** — `df.status()`, `df.explain()`, and instance tables for observability

### Non-Goals

- Replacing general-purpose orchestrators (Airflow, Temporal) for non-database workloads
- AI-specific primitives (chunking, embedding, LLM calls) — these ship with AI Pipelines
- Providing the user interface for AI pipelines
- Providing a visual workflow designer or drag-and-drop UI
- Multi-database or cross-cluster orchestration (single PostgreSQL instance for MVP)

---

## Competitor Capabilities


| Capability | pg_durable | pgflow (Supabase) | pgai Vectorizer | AlloyDB (Cloud Composer/Airflow) | Aurora (AWS Step Functions) | AWS Step Functions |
|-----------|-----------|------------------|----------------|---------|-----------|-------------------|
| **SQL-native authoring** | Yes | No (TypeScript DSL) | Limited (config-based) | No | No | No |
| **Runs inside PostgreSQL** | Yes | Limited (orchestration in PG, execution in Edge Functions) | Yes | Yes | Yes | No |
| **Durable execution** | Yes | Yes | No | No | No | Yes |
| **No external infra** | Yes | Limited (requires Supabase + Edge Functions) | No (requires external worker) | Yes | Yes | No |
| **Database-aware primitives** | Yes | No | Limited (vectorization only) | Limited | Limited | No |
| **General-purpose workflows** | Yes | Limited (DAG-only, no loops/conditionals) | No (embedding-specific) | No | No | Yes |
| **Parallel execution** | Yes | Yes | Yes | Limited | Limited | Yes |
| **Human-in-the-loop (triggers)** | Yes | No | No | No | No | Yes |

---

## Use Cases

| Priority | Use Case | Example |
|--------|---------|--------|
| **P0** | Sequential SQL workflows | Multi-step ETL: extract → transform → load with checkpointing |
| **P0** | Parallel data aggregation | Fan-out queries, join results into a summary report |
| **P0** | Conditional branching | Check pending jobs → process or skip based on count |
| **P0** | Scheduled background tasks | Hourly cleanup with `loop` + `sleep`, survives restarts |
| **P0** | Multi-step data validation | Fetch → validate schema → validate rules → approve/reject |
| **P1** | Database migration safety | Wait for idle → run migration → verify, with automatic rollback |
| **P1** | Background maintenance | VACUUM, reindex, or partition management on a schedule |
| **P2** | Distributed coordination | Two-phase operations across shards with durable state |
| *Future* | AI pipeline execution | Chunk → embed → store (ships with AI Pipelines release) |
| *Future* | Human-in-the-loop approval | Agent approval workflows (ships with AI Pipelines release) |

---

## Why a SQL DSL?

Users can define workflows using three approaches:

### 1. External Orchestrator (Temporal, Airflow)

**Pros**
- Mature ecosystems, rich UIs
- Language-native SDKs

**Cons**
- Requires separate infrastructure and deployment
- Network round-trips for every database operation
- Workflow state lives outside the database

### 2. Application Code (PL/pgSQL, stored procedures)

**Pros**
- Runs inside the database
- Familiar to DBAs

**Cons**
- Not durable — crashes lose progress
- No built-in parallelism, sleep, or event waiting
- Complex control flow is hard to express

### 3. SQL DSL with Durable Runtime (pg_durable)

**Pros**
- Concise, composable operators
- Durable by default — survives crashes via replay
- Database-aware (idle detection, replica lag)
- No external infrastructure

**Cons**
- Limited to PostgreSQL
- New syntax to learn (operators)

### Proposed Direction

pg_durable provides a **SQL-native DSL** for common durable workflows. The same runtime can be targeted by higher-level abstractions (AI Pipeline DSL, Python SDK) for specialized use cases.

---

## Functional Requirements

### MVP (Current)

| Priority | Requirement |
|--------|------------|
| **P0** | `df.sql(query)` — execute SQL, return result as JSON |
| **P0** | `df.sleep(interval)` — pause execution for a duration |
| **P0** | `df.if(cond, then, else)` — conditional branching |
| **P0** | `df.seq(a, b)` / `~>` operator — sequential composition |
| **P0** | `df.join(a, b)` / `&` operator — parallel execution (all) |
| **P0** | `df.loop(body)` — infinite loop |
| **P0** | `\|=>` operator — name a result for `$var` reference |
| **P0** | `df.start(graph, label)` — start instance, return ID |
| **P0** | `df.status(id)` — check instance status |
| **P0** | Background worker with duroxide runtime |
| **P0** | Crash recovery via replay (checkpointed activities) |
| **P0** | E2E test suite |

### Post-MVP

| Priority | Requirement |
|--------|------------|
| **P0** | `df.race(a, b)` / `\|` operator — parallel execution (first wins) |
| **P0** | `df.for_each(var, source, body)` — iterate over result set |
| **P0** | `df.break()` / `df.continue()` — loop control |
| **P1** | `df.http_get()` / `df.http_post()` — HTTP requests |
| **P1** | `df.wait_idle()` — wait for database idle |
| **P1** | `df.wait_trigger()` / `df.fire_trigger()` — external events |
| **P1** | `df.cancel(id)` — cancel running instance |
| **P1** | `df.explain()` — visualize function graph |
| **P2** | `df.wait_replica_lag()` — wait for replication |
| **P2** | `df.case_when()` — multi-branch conditional |
| **P2** | `df.batch()` — group items for batch processing |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      PostgreSQL                         │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │           pg_durable Extension (pgrx/Rust)        │  │
│  │                                                   │  │
│  │   SQL DSL Layer          Background Worker        │  │
│  │   ─────────────          ─────────────────        │  │
│  │   • df.sql(), df.if()    • Polls df.instances     │  │
│  │   • Operators ~> & |     • Loads graph from       │  │
│  │   • Builds function        df.nodes               │  │
│  │     graph in df.nodes    • Executes via duroxide  │  │
│  │   • df.start() queues    • Activities are         │  │
│  │     instance               checkpointed           │  │
│  │                          • Crash → replay         │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │                   df Schema                       │  │
│  │                                                   │  │
│  │   df.nodes      — function graph (node_type,      │  │
│  │                   query, left/right, result_name) │  │
│  │   df.instances  — workflow instances (status,     │  │
│  │                   root_node, label, output)       │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## Appendix: Example Workflows

### Sequential ETL

```sql
SELECT df.start(
    df.sql('SELECT id, raw_data FROM staging WHERE processed = false LIMIT 100') |=> 'batch'
    ~> df.sql('INSERT INTO warehouse SELECT id, parse(raw_data) FROM staging WHERE id = ANY($batch)')
    ~> df.sql('UPDATE staging SET processed = true WHERE id = ANY($batch)'),
    'etl-pipeline'
);
```

### Parallel Aggregation

```sql
SELECT df.start(
    (
        df.sql('SELECT sum(amount) FROM orders') |=> 'sales'
        & df.sql('SELECT count(*) FROM returns') |=> 'returns'
    )
    ~> df.sql('INSERT INTO reports VALUES ($sales, $returns, now())'),
    'daily-report'
);
```

### Scheduled Cleanup (Survives Restarts)

```sql
SELECT df.start(
    df.loop(
        df.sql('DELETE FROM temp_data WHERE created_at < now() - interval ''7 days''')
        ~> df.sleep('1 hour')
    ),
    'hourly-cleanup'
);
```

### Future: AI Pipeline Primitives (Phase 2)

The following operators are proposed for the AI Pipelines layer. They run on the pg_durable runtime but are **not part of the pg_durable release**.

| Operator | Parameters | Description |
|----------|-----------|-------------|
| `ai.start(graph, label)` | `graph` — pipeline expression, `label` — instance name | Start a durable AI pipeline (wrapper over `df.start` with AI-aware defaults) |
| `ai.chunk(table, ...)` | `table` — source table, `column` — text column, `method` — chunking strategy (e.g. `'recursive'`), `chunk_size` — max tokens per chunk | Split documents into chunks for embedding |
| `ai.embed(input, ...)` | `input` — variable reference to chunks, `model` — embedding model name (e.g. `'text-embedding-3-small'`) | Generate vector embeddings from text chunks |
| `ai.retrieve(query, ...)` | `query` — variable reference to search query, `index` — vector index name, `top_k` — number of results to return | Retrieve nearest-neighbor results from a vector index |
| `ai.llm_call(model, ...)` | `model` — LLM model name (e.g. `'gpt-4o'`), `prompt` — system/user prompt text, `inputs` — array of variable names to inject as context | Call a large language model with context variables |
| `ai.request_approval(input, ...)` | `input` — variable reference to content for review, `notify` — email or channel to notify, `timeout` — max wait duration (e.g. `'24 hours'`) | Pause pipeline for human approval; resumes on approve/reject |

### Future: AI Document Processing Pipeline

This example illustrates what the **AI Pipelines** layer (Phase 2) would look like built on top of pg_durable. The durable runtime handles checkpointing, crash recovery, and parallel fan-out — the AI layer adds chunking, embedding, and LLM-specific operators.

```sql
-- Phase 2 (AI Pipelines) — not part of pg_durable release
SELECT ai.start(
    ai.chunk('documents', column => 'content', method => 'recursive', chunk_size => 512)
        |=> 'chunks'
    ~> ai.embed('chunks', model => 'text-embedding-3-small')
        |=> 'embeddings'
    ~> df.sql('INSERT INTO doc_vectors (doc_id, chunk_idx, embedding)
              SELECT doc_id, chunk_idx, embedding FROM $embeddings'),
    'embed-knowledge-base'
);
```

This pipeline durably chunks documents, generates embeddings, and stores them — surviving crashes at any step. Without pg_durable's runtime, each stage would need custom retry logic and state management.

### Future: RAG with Human-in-the-Loop Approval

A more advanced AI pipeline combining retrieval-augmented generation with a human approval gate — showcasing primitives that belong in the AI Pipelines layer, not raw SQL.

```sql
-- Phase 2 (AI Pipelines) — not part of pg_durable release
SELECT ai.start(
    df.sql('SELECT question FROM support_queue WHERE status = ''pending'' LIMIT 1')
        |=> 'ticket'
    ~> ai.retrieve('ticket', index => 'doc_vectors', top_k => 5)
        |=> 'context'
    ~> ai.llm_call('gpt-4o',
            prompt => 'Answer this support question using the provided context.',
            inputs => ARRAY['ticket', 'context'])
        |=> 'draft_answer'
    ~> ai.request_approval('draft_answer',
            notify => 'support-team@example.com',
            timeout => '24 hours')
        |=> 'decision'
    ~> df.if(
        df.sql('SELECT $decision = ''approved'''),
        df.sql('UPDATE support_queue SET response = $draft_answer, status = ''answered''
                WHERE question = $ticket'),
        df.sql('UPDATE support_queue SET status = ''needs-human''
                WHERE question = $ticket')
       ),
    'rag-support-bot'
);
```

This pipeline executes durably end-to-end: if the server crashes while waiting for human approval (which could take hours), pg_durable replays from the last checkpoint — no work is lost, and the approval gate resumes exactly where it left off.
