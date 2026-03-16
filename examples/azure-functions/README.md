# Azure Functions + pg_durable Example

Call an HTTP-triggered Azure Function from a pg_durable workflow using `df.http()`, then store the returned chunks in PostgreSQL.

## Scenario

Token-aware text chunking for ingestion.

Flow:

1. Read pending documents from PostgreSQL.
2. Call Azure Function over HTTPS.
3. Receive JSON with chunk metadata.
4. Insert chunks and mark documents processed.

## Azure Functions in one minute

For this example, you deploy a Python HTTP-triggered Azure Function and call it from `df.http()`.

Reference: https://learn.microsoft.com/en-us/azure/azure-functions/functions-overview?pivots=programming-language-python

## Authentication

Uses **Function** auth. `df.http()` sends `x-functions-key` from `.azure-functions.env`.

## Directory layout

- `function-app/chunk_text/`: Python function design contract
- `sql/`: SQL workflow design contract
- `scripts/`: setup/deploy script design contract

## Request/Response shape

Request body example:

```json
{
  "document_id": 123,
  "text": "<full document text>",
  "max_tokens": 400,
  "overlap_tokens": 40,
  "language": "en"
}
```

Response body example:
```json
{
  "document_id": 123,
  "model_hint": "cl100k_base",
  "total_tokens": 1842,
  "chunks": [
    {
      "chunk_index": 0,
      "text": "...",
      "token_count": 395
    }
  ]
}
```

SQL handling:

- Parse `df.http()` envelope (`status`, `ok`, `body`).
- Cast `body` to JSON/JSONB.
- Insert one row per chunk.
- Update source document status.

## What is intentionally out of scope

- Multi-function pipelines
- RAG orchestration
- idle-time schedulers and advanced runtime patterns
- provider-specific secret managers

## Prerequisites

- Azure CLI (`az`) installed
- Azure Functions Core Tools (`func`) installed
- Azure login completed (`az login`)
- PostgreSQL client (`psql`) available (or pgrx `psql` path)

## Quickstart

### 1) Provision Azure Function App

From this directory:

```bash
chmod +x scripts/*.sh

./scripts/create_function_app.sh -l <location>
```

What this creates:

- Resource group: `pgd_ex_af_<5 random hex>`
- Function app: derived from the resource group and sanitized for Azure naming rules
- Storage account: derived from the same base name and sanitized for Azure naming rules

Location defaults to `eastus`.

### 2) Deploy Python function

```bash
./scripts/deploy_function.sh
```

`deploy_function.sh` reads app/resource-group from `.azure-functions.env` and updates it with function base URL and key.

### 3) Prepare PostgreSQL demo schema

```bash
psql -d postgres -f sql/01_schema.sql
```

### 4) Configure pg_durable variables

```bash
./scripts/configure_pg.sh \
  -d postgres \
  -h localhost \
  -p 28817 \
  -U postgres
```

`configure_pg.sh` reads base URL and function key from `.azure-functions.env`.

### 5) Start workflow

```bash
psql -d postgres -f sql/03_start_workflow.sql
```

If there are no `pending` rows in `demo.af_documents`, the workflow completes as a no-op.

### 6) Verify results

```bash
psql -d postgres -f sql/04_verify.sql
```

You should see:

- one processed row in `demo.af_documents`
- one or more rows in `demo.af_document_chunks`

### 7) Cleanup Azure resources when done

```bash
./scripts/cleanup_azure.sh -y
```

This reads the resource group from `.azure-functions.env`.
You can also pass one explicitly:

```bash
./scripts/cleanup_azure.sh -g <resource-group> -y
```

## Operational Notes

- This scenario uses Function auth with `x-functions-key`.
- Keep function keys out of committed files and shell history where possible.
- `df.http()` response is an envelope; SQL parses `body` JSON only after checking `ok`/`status`.
