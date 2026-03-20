# AI Pipelines

## Overview

| Field | Value |
|------|------|
| **Program Manager** | Maxim Lukiyanov & Abe Omorogbe |
| **Engineering Manager** | Rakesh Gujjula |
| **Engineer** | Krishnakumar Ravi (KK) |
| **Azure DevOps Feature ID** | FEATURE TBD |
| **Status** | Draft |
| **Last Modified** | 02/18/2026 |

---

## What & Why

We are introducing **AI Pipelines** to simplify data preparation in GenAI applications for PostgreSQL (and other databases in the future) — a top pain point for GenAI app developers.

Common GenAI steps such as:
- chunking  
- vectorization  
- feature extraction  

have become standard, but currently require **significant boilerplate code** and service integration. Today, building even a simple chunking + embedding pipeline requires hundreds of lines of Python, custom retry logic, state management, and careful error handling.

With AI Pipelines:
- Pipelines are defined declaratively using a **top-down, SDK-first** experience (Python SDK or Pipeline DSL)
- Pipelines are deployed directly into **Postgres** — powered by **pg_durable** as the stateful worker, with **no external infrastructure**
- First-class operators for common AI patterns: **chunking, embedding, retry, email, human-in-the-loop approval**
- Lightweight monitoring and management via the **PostgreSQL VS Code extension**
- Customers like Walmart can be pointed directly to the pipeline product without needing to learn raw SQL internals

See additional motivation in *In-database AI – evolving perspective*.

---

## Customer Evidence

**TODO**: Summary of customer interviews

**Walmart**: Key customer reference — the goal is to provide a pipeline experience where we can "just point them to the pipeline" without requiring deep knowledge of the underlying SQL DSL or durable execution internals. AI Pipelines should be self-service and approachable for data/AI teams.

---

## Goals

- **Top-down, SDK-first experience** — users define pipelines declaratively, not raw SQL
- **Python SDK** and **Pipeline DSL** for pipeline definitions (need to align on DSL design)
- **First-class operators** for common AI primitives:
  - Built-in **chunking** (text splitting, document parsing)
  - Built-in **embedding** (vector generation)
  - Built-in **retry logic** with configurable policies
  - **Email extension** (notifications, alerts)
  - **Human-in-the-loop / agent approval workflows** — approval steps are part of the pipeline, not bolted on
- **Powered by pg_durable** — stateful durable worker running inside PostgreSQL, no external infrastructure
- Deployment to:
  - OrionDB (Postgres extension)
  - Python Container App
- **VS Code experience** — pipeline monitoring, management, and status visualization in the PostgreSQL VS Code extension
- OSS and modular design:
  - Community can add sources, sinks, and transformations
  - Extensible with custom modules

### Non-Goals

- Complex non‑GenAI data transformations
- *(Future)* Training pipelines for custom embedding models
- *(Future)* Graph extraction using LLMs and LazyGraphRAG

---

## Competitor Capabilities

| Scenario | OrionDB | AlloyDB (Cloud Composer/Airflow) | Aurora (AWS Step Functions) |
|--------|--------|---------|--------|
| **AI Pipelines** | Yes | Yes (Apache Beam) | Yes (Amazon Bedrock) |

---

## Use Cases

| Priority | Use Case | Example |
|--------|---------|--------|
| **P0** | Chunk text into rows | Split documents into chunks stored with parent doc ID |
| **P0** | Generate embeddings | Store embeddings in vector column |
| **P0** | Bulk ingest external data | Load CSV → chunk → embed |
| **P0** | Incremental execution | Re‑process on data changes |
| **P0** | Manual backfill | User-triggered full reprocessing |
| **P0** | Agent approval workflow | Human-in-the-loop approval as a pipeline step (e.g., approve extracted data before loading) |
| **P1** | Extract features using LLM | Extract semantic attributes into columns |
| **P1** | Automatic backfill | Triggered by pipeline definition changes |
| **P1** | Email notifications | Send email alerts on pipeline completion, failure, or approval requests |
| **CUT** | PDF extraction | Document Intelligence-based parsing |

---

## Why a Pipeline DSL?

Users can define pipelines using three approaches:

### 1. Python SDK

**Pros**
- Familiar to developers
- Supports advanced pipelines and custom code

**Cons**
- Operationally complex
- Each pipeline requires a managed Python worker
- Hard to create, stop, or backfill pipelines

### 2. PostgreSQL SQL (Extension)

**Pros**
- Simplified lifecycle management
- Hosted directly in the database

**Cons**
- SQL is not expressive for AI pipelines
- UDF-heavy, complex syntax
- Poor developer ergonomics

### 3. Specialized Pipeline DSL

**Pros**
- Simple, purpose-built syntax
- Easy deployment and lifecycle management

**Cons**
- Limited for highly custom logic
- Learning curve for new language

### Proposed Direction

The experience is **SDK-first, top-down**:

1. **Python SDK** as the primary authoring surface — familiar, powerful, supports custom code
2. **Pipeline DSL** for common, declarative pipelines — simpler syntax, easier lifecycle management (syntax needs alignment)
3. Both compile down to the same **pg_durable execution engine** — no external infrastructure

The key insight: AI pipeline scenarios today require **a lot of code** — custom retry logic, state management, error handling, and model-specific boilerplate. AI Pipelines eliminates this by providing **first-class operators** rather than forcing users to build workarounds in raw code.

Strategically, this DSL could become an industry‑level innovation and a developer attention magnet.

---

## Functional Requirements

### Pipeline Definition

| Priority | Requirement |
|--------|------------|
| **P0** | Define declarative pipelines in **Python SDK** (top-down, SDK-first experience) |
| **P0** | Define declarative pipelines in **Pipeline DSL** (syntax TBD — needs alignment) |
| **P0** | Custom Python transformations |

### First-Class Operators & Primitives

| Priority | Requirement |
|--------|------------|
| **P0** | Core operators: source, filter, derive, chunk, embed, update |
| **P0** | Built-in **chunking** — text splitting with configurable strategies |
| **P0** | Built-in **retry logic** — configurable retry policies with backoff |
| **P0** | **Human-in-the-loop / agent approval** — approval steps as first-class pipeline operators |
| **P1** | **Email extension** — send notifications, alerts, approval requests |
| **P1** | Join |
| **P2** | Group by, aggregate, sort, take |

### Deployment & Execution

| Priority | Requirement |
|--------|------------|
| **P0** | CLI deployment |
| **P0** | CLI execution/hosting |
| **P0** | Python Runner execution |
| **P0** | Deployment targets: Local Postgres, OrionDB, Azure Container App |
| **CUT** | Fabric, Logic Apps |

### Data Sources & Sinks

| Priority | Requirement |
|--------|------------|
| **P0** | Data sources: Postgres, local files, Azure Blob |
| **P1** | Kafka, EventHub |
| **CUT** | SQL Server, CosmosDB, MySQL, SQLite |
| **P0** | File formats: CSV, JSON |
| **P0** | Data sink: Postgres |

### Developer Experience

| Priority | Requirement |
|--------|------------|
| **P0** | **VS Code experience** — pipeline monitoring, status, management in PostgreSQL extension |
| **P0** | Extensible via custom modules |
| **P0** | OSS contribution support |

---

## Architecture

AI Pipelines are built on top of **pg_durable**, which serves as the **stateful durable worker** running inside PostgreSQL. This means:

- **No external infrastructure** — no sidecar services, no external orchestrators, no additional deployments
- **Durable execution** — pipeline state is persisted to PostgreSQL; survives crashes, restarts, and failovers
- **Crash recovery** — automatic replay from last checkpoint on failure
- **Built-in retry** — configurable retry policies at the operator level

```
┌─────────────────────────────────────────────────────────────┐
│                        PostgreSQL                           │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              AI Pipelines Layer                       │  │
│  │                                                       │  │
│  │   Python SDK          Pipeline DSL       VS Code UI   │  │
│  │   ───────────         ────────────       ──────────   │  │
│  │   • Declarative       • Purpose-built    • Monitor    │  │
│  │     pipeline defs       syntax             pipelines  │  │
│  │   • Custom Python     • Easy lifecycle   • View       │  │
│  │     transforms          management         status     │  │
│  │   • Advanced          • Common           • Manage     │  │
│  │     scenarios           patterns            runs      │  │
│  └───────────────────────┬───────────────────────────────┘  │
│                          │ compiles to                      │
│  ┌───────────────────────▼───────────────────────────────┐  │
│  │         pg_durable — Stateful Durable Worker          │  │
│  │                                                       │  │
│  │   • Durable execution via duroxide runtime            │  │
│  │   • Crash recovery via replay (checkpointed)          │  │
│  │   • No external infrastructure                        │  │
│  │   • Background worker inside PostgreSQL               │  │
│  │   • State persisted to df.nodes / df.instances        │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Why pg_durable as the Backend

pg_durable provides the durable execution, state management, and crash recovery that AI Pipelines depend on. By running inside PostgreSQL as a background worker, it eliminates the need for any external orchestrator (Temporal, Airflow, Step Functions) while providing the same guarantees.

This also means customers like **Walmart** can be pointed directly to the AI Pipeline product — they interact with the SDK/DSL layer and don't need to understand the underlying pg_durable runtime.

---

## VS Code Experience

The PostgreSQL VS Code extension provides a first-class experience for AI Pipelines:

- **Pipeline status dashboard** — see all running, completed, and failed pipelines
- **Real-time monitoring** — watch pipeline progress as steps execute
- **Step-level visibility** — drill into individual pipeline steps, see inputs/outputs
- **Error diagnostics** — view failure details, retry history, and checkpoint state
- **Pipeline management** — start, stop, backfill, and cancel pipelines from the editor

> **TODO**: Mockups and screenshots of the VS Code pipeline experience

---

## Appendix: Example Pipeline DSL (Hypothetical)

> ⚠️ **Final syntax TBD — needs alignment.** Inspired by **PRQL** and **Polars**.
>
> We are introducing a **new DSL specifically for pipelines**. This is distinct from the pg_durable SQL DSL (which uses operators like `~>`, `&`, `|`). The Pipeline DSL is higher-level, purpose-built for AI data preparation workflows.

```pipe
model embedding_model {
  provider = 'azure_open_ai'
  endpoint = 'https://text-embedding-v3-large.openai.azure.com'
}

model extract_model {
  provider = 'azure_open_ai'
  endpoint = 'https://gpt4.1-mini.openai.azure.com'
}

pipeline invoices {
  from read_csv 'test_invoices/*'
  chunk description strategy:'sentence' max_tokens:512
  derive {
    vector  = description | embed model:embedding_model
    company = description | extract 'Company Name' model:extract_model
  }
  approve when:manual message:'Review extracted companies before loading'
  into target_table
}
```

### Example: Python SDK

```python
from ai_pipelines import Pipeline, models, operators

embedding = models.AzureOpenAI(
    endpoint='https://text-embedding-v3-large.openai.azure.com'
)

pipeline = Pipeline('invoices')
pipeline.source('read_csv', 'test_invoices/*')
pipeline.chunk('description', strategy='sentence', max_tokens=512)
pipeline.embed('description', model=embedding, output='vector')
pipeline.approve(when='manual', message='Review before loading')
pipeline.sink('target_table')

pipeline.deploy(target='postgres')  # Runs on pg_durable — no external infra
```
