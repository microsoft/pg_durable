# pg_durable

**SQL-native durable workflows for PostgreSQL**

---

## Overview

pg_durable brings durable execution to PostgreSQL. It lets you author long-running, fault-tolerant workflows entirely in SQL—no external orchestrators, no YAML, no separate deployment.

### The Problem

Modern applications need workflows that:
- **Survive failures** — A crashed process shouldn't lose hours of work
- **Span long durations** — Wait for human approval, schedule nightly jobs, retry for days
- **Coordinate complex operations** — Fan-out/fan-in, conditional branching, parallel execution
- **React to database state** — Wait for idle, check replica lag, respond to triggers

Today's solutions require external systems (Temporal, Airflow, Step Functions) with their own infrastructure, languages, and deployment complexity. But for database-centric workloads, the database itself is the natural home for this logic.

### The Solution

pg_durable embeds a durable execution engine into PostgreSQL:

```sql
-- A workflow that runs forever, processing embeddings only when the database is idle
SELECT durable.start(
    durable.loop(
        durable.wait_idle(0.20, 3)
        ~> durable.func('generate_embeddings', '{"table": "documents"}')
    )
);
```

**Key properties:**
- **Durable** — Workflow state is persisted to PostgreSQL. Survives crashes, restarts, and failovers.
- **SQL-native** — Author workflows in SQL using composable functions and operators.
- **Database-aware** — First-class primitives for waiting on idle, replica lag, table conditions.
- **Transactional** — Workflow state changes are ACID. No split-brain, no lost updates.

### Design Principles

1. **SQL is the interface** — No new languages. If you know SQL, you can write workflows.
2. **PostgreSQL is the source of truth** — Workflow state lives in tables. Query it, back it up, replicate it.
3. **External runtime, minimal extension** — The SQL extension defines the DSL. A separate Rust process executes workflows, connecting via standard PostgreSQL protocol.
4. **Composition over configuration** — Simple primitives combine into complex workflows.

### Built on duroxide

The runtime is powered by [duroxide](https://github.com/microsoft/duroxide), a durable task framework for Rust. Orchestrations are deterministic and survive crashes via replay:

```rust
async fn order_workflow(ctx: OrchestrationContext, order_json: String) -> Result<String, String> {
    ctx.trace_info("Starting order workflow");
    
    // Each await is a persistence point — workflow resumes here after crash
    let reserved = ctx.schedule_activity("ReserveInventory", order_json.clone())
        .into_activity().await?;
    
    let payment = ctx.schedule_activity("ChargePayment", reserved)
        .into_activity().await?;
    
    // Parallel fan-out
    let notifications = vec![
        ctx.schedule_activity("SendEmail", payment.clone()),
        ctx.schedule_activity("SendSMS", payment.clone()),
    ];
    let _ = ctx.join(notifications).await;
    
    // Timer (durable — survives restart)
    ctx.schedule_timer(Duration::from_secs(3600)).into_timer().await;
    
    // Wait for external event with timeout
    let approval = ctx.schedule_wait("ApprovalEvent");
    let timeout = ctx.schedule_timer(Duration::from_secs(86400));
    let (winner, _) = ctx.select2(approval, timeout).await;
    
    if winner == 1 {
        return Err("Approval timed out".to_string());
    }
    
    Ok(payment)
}
```

**Learn more:** [GitHub](https://github.com/microsoft/duroxide) · [Docs](https://docs.rs/duroxide) · [Examples](https://github.com/microsoft/duroxide/tree/main/examples)

---

## Patterns

Simple building blocks that combine into complex workflows.

### Sequence

Execute steps one after another:

```sql
durable.sql('INSERT INTO logs VALUES (''started'')')
~> durable.func('do_work', '{}')
~> durable.sql('INSERT INTO logs VALUES (''finished'')')
```

### Parallel (Join)

Execute steps concurrently, wait for all to complete:

```sql
(
    durable.func('fetch_users', '{}')
    & durable.func('fetch_orders', '{}')
    & durable.func('fetch_products', '{}')
) => 'data'
```

### Parallel (Race)

Execute steps concurrently, return first to complete:

```sql
durable.http_get('https://api1.example.com/data')
| durable.http_get('https://api2.example.com/data')
| (durable.sleep('5 seconds') ~> durable.value('{"error": "timeout"}'))
```

### Sleep

Pause execution for a duration:

```sql
durable.func('send_email', '{"to": "user@example.com"}')
~> durable.sleep('1 hour')
~> durable.func('send_reminder', '{"to": "user@example.com"}')
```

### Named Results

Capture a result and reference it later:

```sql
durable.sql('SELECT id, email FROM users WHERE id = 1') => 'user'
~> durable.func('send_email', '{"to": "$user.rows[0].email"}')
```

### Loop with Condition

Repeat until a condition is met:

```sql
durable.loop(
    durable.sql('SELECT count(*) as pending FROM jobs WHERE status = ''pending''') => 'result'
    ~> durable.if(
        '$result.rows[0].pending = 0',
        durable.break(),
        durable.func('process_next_job', '{}') ~> durable.sleep('1 second')
    )
)
```

### Iterate Over Results

Process each row from a query:

```sql
durable.sql('SELECT id, url FROM images WHERE thumbnail IS NULL') => 'images'
~> durable.for_each('img', $images.rows,
    durable.func('generate_thumbnail', '{"id": "$img.id", "url": "$img.url"}')
)
```

---

## Scenarios

### Background Processing with Resource Awareness

Run expensive operations (embeddings, analytics, cleanup) only when the database has spare capacity:

```sql
SELECT durable.start(
    durable.loop(
        durable.wait_idle(0.20, 3)
        ~> durable.sql('SELECT id FROM documents WHERE embedding IS NULL LIMIT 100') => 'batch'
        ~> durable.if(
            '$batch.row_count > 0',
            durable.for_each('doc', $batch.rows,
                durable.if(
                    durable.is_idle(0.30, 5),
                    durable.func('generate_embedding', '{"id": "$doc.id"}'),
                    durable.break()
                )
            ),
            durable.sleep('30 seconds')
        )
    )
);
```

### Scheduled Maintenance

Wait for maintenance windows, coordinate multi-step operations:

```sql
SELECT durable.start(
    durable.loop(
        durable.wait_stat('SELECT EXTRACT(HOUR FROM now()) BETWEEN 2 AND 4', '1 minute')
        ~> durable.wait_idle(0.05, 1)
        ~> (
            durable.sql('VACUUM ANALYZE events')
            & durable.sql('VACUUM ANALYZE users')
        )
        ~> durable.sql('REINDEX TABLE CONCURRENTLY events')
        ~> durable.sleep('20 hours')
    )
);
```

### Human-in-the-Loop

Wait for external events with timeouts:

```sql
SELECT durable.start(
    durable.func('send_approval_request', '{"doc": "doc-123"}')
    ~> durable.wait_trigger('approval', '7 days') => 'decision'
    ~> durable.if(
        '$decision.approved',
        durable.func('publish_document', '{"doc": "doc-123"}'),
        durable.func('notify_rejection', '{"reason": "$decision.reason"}')
    )
);

-- Later, from application code:
SELECT durable.fire_trigger('instance-id', 'approval', '{"approved": true}');
```

### Data Pipelines

ETL with parallel extraction, error handling, and progress tracking:

```sql
SELECT durable.start(
    durable.loop(
        durable.wait_stat('SELECT EXTRACT(MINUTE FROM now()) < 5', '1 minute')
        ~> (
            durable.sql('INSERT INTO staging.events SELECT * FROM raw.events WHERE NOT processed RETURNING count(*)')
            & durable.sql('INSERT INTO staging.users SELECT * FROM raw.users WHERE NOT processed RETURNING count(*)')
        ) => 'extracted'
        ~> durable.if(
            '$extracted[0].count + $extracted[1].count > 0',
            durable.func('transform_and_load', '{"events": $extracted[0].count}') => 'loaded'
            ~> durable.sql('UPDATE raw.events SET processed = true WHERE NOT processed'),
            durable.noop()
        )
        ~> durable.sleep('55 minutes')
    )
);
```

### Distributed Coordination

Two-phase commit across database shards:

```sql
SELECT durable.start(
    (
        durable.sql('SELECT dblink_exec(''shard1'', ''PREPARE TRANSACTION ''''txn'''')')
        & durable.sql('SELECT dblink_exec(''shard2'', ''PREPARE TRANSACTION ''''txn'''')')
    ) => 'prepared'
    ~> durable.if(
        durable.all_ok('$prepared'),
        (
            durable.sql('SELECT dblink_exec(''shard1'', ''COMMIT PREPARED ''''txn'''')')
            & durable.sql('SELECT dblink_exec(''shard2'', ''COMMIT PREPARED ''''txn'''')')
        ),
        (
            durable.sql('SELECT dblink_exec(''shard1'', ''ROLLBACK PREPARED ''''txn'''')')
            & durable.sql('SELECT dblink_exec(''shard2'', ''ROLLBACK PREPARED ''''txn'''')')
        )
    )
);
```

### AI Pipelines

These scenarios demonstrate capabilities similar to pgflow and pgai—building RAG applications, document processing, and LLM-powered workflows entirely in SQL.

#### Automatic Vectorization Pipeline

Continuously embed new documents with chunking, rate limiting, and automatic sync:

```sql
SELECT durable.start(
    durable.loop(
        durable.wait_idle(0.15, 2)
        ~> durable.sql('SELECT id, content FROM documents WHERE embedding IS NULL LIMIT 50') => 'docs'
        ~> durable.if(
            '$docs.row_count > 0',
            durable.for_each('doc', $docs.rows,
                durable.func('chunk_text', '{"id": "$doc.id", "size": 512, "overlap": 50}') => 'chunks'
                ~> durable.for_each('chunk', $chunks,
                    durable.http_post('https://api.openai.com/v1/embeddings', 
                        '{"model": "text-embedding-3-small", "input": "$chunk.text"}',
                        '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
                    ) => 'embedding'
                    ~> durable.sql('INSERT INTO embeddings (doc_id, chunk_idx, vector, text) VALUES ($1, $2, $3, $4)',
                        $doc.id, $chunk.idx, $embedding.data[0].embedding, $chunk.text)
                )
            )
            ~> durable.sleep('5 seconds'),
            durable.sleep('30 seconds')
        )
    )
);
```

#### RAG Query Pipeline

Retrieve context, call LLM, and store the response:

```sql
SELECT durable.start(
    -- Generate query embedding
    durable.http_post('https://api.openai.com/v1/embeddings',
        '{"model": "text-embedding-3-small", "input": "$input.question"}',
        '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
    ) => 'query_emb'
    
    -- Semantic search for relevant chunks
    ~> durable.sql($$
        SELECT text, 1 - (vector <=> $1::vector) as score
        FROM embeddings
        ORDER BY vector <=> $1::vector
        LIMIT 5
    $$, $query_emb.data[0].embedding) => 'context'
    
    -- Call LLM with retrieved context
    ~> durable.http_post('https://api.openai.com/v1/chat/completions',
        '{
            "model": "gpt-4o",
            "messages": [
                {"role": "system", "content": "Answer based on the following context:\\n$context.rows[*].text"},
                {"role": "user", "content": "$input.question"}
            ]
        }',
        '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
    ) => 'answer'
    
    -- Store the interaction
    ~> durable.sql('INSERT INTO chat_history (question, context, answer) VALUES ($1, $2, $3)',
        $input.question, $context, $answer.choices[0].message.content)
);
```

#### Multi-Model Summarization with Fallback

Try multiple LLM providers, use first successful response:

```sql
SELECT durable.start(
    durable.sql('SELECT id, content FROM articles WHERE summary IS NULL LIMIT 10') => 'articles'
    ~> durable.for_each('article', $articles.rows,
        (
            -- Race: try multiple providers, take first success
            durable.http_post('https://api.openai.com/v1/chat/completions',
                '{"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "Summarize: $article.content"}]}',
                '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
            )
            | durable.http_post('https://api.anthropic.com/v1/messages',
                '{"model": "claude-3-haiku-20240307", "messages": [{"role": "user", "content": "Summarize: $article.content"}]}',
                '{"x-api-key": "$ENV.ANTHROPIC_API_KEY", "anthropic-version": "2023-06-01"}'
            )
            | (durable.sleep('10 seconds') ~> durable.value('{"error": "all providers failed"}'))
        ) => 'result'
        ~> durable.if(
            '$result.error IS NULL',
            durable.sql('UPDATE articles SET summary = $1 WHERE id = $2', 
                $result.choices[0].message.content, $article.id),
            durable.sql('INSERT INTO failed_jobs (article_id, error) VALUES ($1, $2)',
                $article.id, $result.error)
        )
    )
);
```

#### Document Ingestion from S3

Parse PDFs/HTML, chunk, and vectorize from object storage:

```sql
SELECT durable.start(
    durable.loop(
        durable.sql('SELECT id, s3_uri, mime_type FROM pending_imports WHERE status = ''pending'' LIMIT 20') => 'files'
        ~> durable.if(
            '$files.row_count > 0',
            durable.for_each('file', $files.rows,
                -- Download and parse
                durable.func('s3_download', '{"uri": "$file.s3_uri"}') => 'raw'
                ~> durable.case_when(
                    '$file.mime_type = ''application/pdf''' := durable.func('parse_pdf', '{"content": "$raw"}'),
                    '$file.mime_type = ''text/html''' := durable.func('parse_html', '{"content": "$raw"}'),
                    otherwise := durable.value('{"text": "$raw"}')
                ) => 'parsed'
                
                -- Chunk the text
                ~> durable.func('chunk_text', '{"text": "$parsed.text", "size": 1000}') => 'chunks'
                
                -- Embed all chunks in parallel batches
                ~> durable.for_each('chunk', $chunks,
                    durable.http_post('https://api.openai.com/v1/embeddings',
                        '{"model": "text-embedding-3-small", "input": "$chunk.text"}',
                        '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
                    ) => 'emb'
                    ~> durable.sql('INSERT INTO doc_chunks (file_id, chunk_idx, text, embedding) VALUES ($1, $2, $3, $4)',
                        $file.id, $chunk.idx, $chunk.text, $emb.data[0].embedding)
                )
                ~> durable.sql('UPDATE pending_imports SET status = ''completed'' WHERE id = $1', $file.id)
            )
            ~> durable.sleep('10 seconds'),
            durable.sleep('1 minute')
        )
    )
);
```

#### Agentic Tool-Use Loop

LLM decides which tools to call, loop until done:

```sql
SELECT durable.start(
    durable.sql('SELECT context FROM agent_sessions WHERE id = $1', $input.session_id) => 'session'
    ~> durable.loop(
        -- Ask LLM what to do next
        durable.http_post('https://api.openai.com/v1/chat/completions',
            '{
                "model": "gpt-4o",
                "messages": $session.messages,
                "tools": [
                    {"type": "function", "function": {"name": "search_db", "parameters": {...}}},
                    {"type": "function", "function": {"name": "send_email", "parameters": {...}}},
                    {"type": "function", "function": {"name": "complete", "parameters": {...}}}
                ]
            }',
            '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
        ) => 'response'
        
        ~> durable.case_when(
            '$response.choices[0].finish_reason = ''tool_calls'' AND $response.choices[0].message.tool_calls[0].function.name = ''search_db''' :=
                durable.sql('SELECT * FROM knowledge_base WHERE content ILIKE $1', 
                    $response.choices[0].message.tool_calls[0].function.arguments.query) => 'tool_result'
                ~> durable.sql('UPDATE agent_sessions SET messages = messages || $1 WHERE id = $2',
                    '[{"role": "tool", "content": "$tool_result"}]', $input.session_id),
            
            '$response.choices[0].finish_reason = ''tool_calls'' AND $response.choices[0].message.tool_calls[0].function.name = ''send_email''' :=
                durable.func('send_email', $response.choices[0].message.tool_calls[0].function.arguments) => 'tool_result'
                ~> durable.sql('UPDATE agent_sessions SET messages = messages || $1 WHERE id = $2',
                    '[{"role": "tool", "content": "email sent"}]', $input.session_id),
            
            otherwise := durable.break()
        )
    )
    ~> durable.sql('UPDATE agent_sessions SET status = ''completed'' WHERE id = $1', $input.session_id)
);
```

#### Semantic Search Index Maintenance

Rebuild embeddings when model changes, with zero downtime:

```sql
SELECT durable.start(
    -- Create new embeddings table
    durable.sql('CREATE TABLE embeddings_v2 (LIKE embeddings INCLUDING ALL)')
    
    -- Reprocess all documents with new model
    ~> durable.sql('SELECT id, text FROM embeddings') => 'existing'
    ~> durable.for_each('item', $existing.rows,
        durable.wait_idle(0.25, 3)
        ~> durable.http_post('https://api.openai.com/v1/embeddings',
            '{"model": "text-embedding-3-large", "input": "$item.text"}',  -- new model
            '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
        ) => 'new_emb'
        ~> durable.sql('INSERT INTO embeddings_v2 (id, text, vector) VALUES ($1, $2, $3)',
            $item.id, $item.text, $new_emb.data[0].embedding)
    )
    
    -- Atomic swap
    ~> durable.sql('ALTER TABLE embeddings RENAME TO embeddings_old')
    ~> durable.sql('ALTER TABLE embeddings_v2 RENAME TO embeddings')
    ~> durable.sql('DROP TABLE embeddings_old')
);
```

#### Fan-Out Classification Pipeline

Classify documents using multiple categories in parallel:

```sql
SELECT durable.start(
    durable.sql('SELECT id, content FROM documents WHERE categories IS NULL') => 'docs'
    ~> durable.for_each('doc', $docs.rows,
        -- Run all classifiers in parallel
        (
            durable.http_post('https://api.openai.com/v1/chat/completions',
                '{"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "Classify sentiment (positive/negative/neutral): $doc.content"}]}',
                '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
            ) => 'sentiment'
            & durable.http_post('https://api.openai.com/v1/chat/completions',
                '{"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "Extract topics as JSON array: $doc.content"}]}',
                '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
            ) => 'topics'
            & durable.http_post('https://api.openai.com/v1/chat/completions',
                '{"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "Rate urgency 1-5: $doc.content"}]}',
                '{"Authorization": "Bearer $ENV.OPENAI_API_KEY"}'
            ) => 'urgency'
        )
        ~> durable.sql('UPDATE documents SET sentiment = $1, topics = $2, urgency = $3, categories = true WHERE id = $4',
            $sentiment.choices[0].message.content,
            $topics.choices[0].message.content,
            $urgency.choices[0].message.content,
            $doc.id
        )
    )
);
```

---

## Function Reference

### Primitives

Execute actions that produce results.

| Function | Description |
|----------|-------------|
| `durable.sql(query, ...args)` | Execute SQL, return result as JSON |
| `durable.sql_bool(query)` | Execute SQL, return boolean result |
| `durable.func(name, args)` | Call registered activity function |
| `durable.http_get(url, headers)` | HTTP GET request, return response as JSON |
| `durable.http_post(url, body, headers)` | HTTP POST request, return response as JSON |
| `durable.sleep(duration)` | Sleep for interval (e.g., `'5 minutes'`) |
| `durable.value(json)` | Return literal JSON value |
| `durable.noop()` | Do nothing, return null |

### Wait Primitives

Block until a condition is met.

| Function | Description |
|----------|-------------|
| `durable.wait_idle(max_cpu, max_sessions)` | Wait until database load drops below thresholds |
| `durable.wait_stat(query, poll_interval)` | Wait until query returns true |
| `durable.wait_trigger(name, timeout)` | Wait for external trigger (with optional timeout) |
| `durable.wait_replica_lag(max_bytes, replica)` | Wait until replica lag is below threshold |
| `durable.is_idle(max_cpu, max_sessions)` | Check if idle (non-blocking, returns boolean) |

### Combinators

Compose futures into larger workflows.

| Function | Description |
|----------|-------------|
| `durable.then(a, b)` | Sequential: run a, then b |
| `durable.join(array)` | Parallel: run all, wait for all to complete |
| `durable.race(array)` | Parallel: run all, return first to complete |
| `durable.if(cond, then, else)` | Conditional branching |
| `durable.case_when(cases, otherwise)` | Multi-branch conditional (see below) |
| `durable.loop(body)` | Repeat body forever |
| `durable.for_each(var, source, body)` | Iterate over result set (see below) |
| `durable.batch(source, size)` | Group items into batches of N |
| `durable.as(name, fut)` | Name a future's result for later reference |

#### for_each

Iterate over rows from a result set with an explicit loop variable:

```sql
durable.for_each(variable_name, source, body)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `variable_name` | text | Name of the loop variable (without `$`) |
| `source` | step result | The result set to iterate over (e.g., `$blobs`) |
| `body` | step | The workflow step(s) to execute for each row |

Example:
```sql
durable.sql('SELECT path, bytes FROM files') => 'files'
~> durable.for_each('file', $files,
    durable.sql('INSERT INTO imports VALUES ($1)', $file.path)
)
```

The loop variable `$file` is available within the body to access columns like `$file.path`, `$file.bytes`.

#### case_when

Multi-branch conditional based on expressions:

```sql
durable.case_when(
    '$value < 100' := durable.func('small_handler', ...),
    '$value < 1000' := durable.func('medium_handler', ...),
    otherwise := durable.func('large_handler', ...)
)
```

Conditions are evaluated in order; first match wins.

### Control Flow

Control iteration within loops.

| Function | Description |
|----------|-------------|
| `durable.break()` | Exit current `for_each` or `loop` |
| `durable.continue()` | Skip to next iteration |

### Control Plane

Manage workflow instances.

| Function | Description |
|----------|-------------|
| `durable.start(fut)` | Start a workflow, return instance ID |
| `durable.status(id)` | Get workflow status |
| `durable.cancel(id)` | Cancel a running workflow |
| `durable.fire_trigger(id, name, payload)` | Fire external trigger |

---

## Operators

Operators provide concise syntax for common patterns.

| Operator | Equivalent Function | Description |
|----------|---------------------|-------------|
| `a ~> b` | `durable.then(a, b)` | Sequential composition |
| `a => 'name'` | `durable.as('name', a)` | Name result for `$name` reference |
| `a & b` | `durable.join(ARRAY[a, b])` | Parallel execution (all) |
| `a \| b` | `durable.race(ARRAY[a, b])` | Parallel execution (first) |

### Variable References

Results named with `=> 'name'` can be referenced using `$name`:

```sql
durable.sql('SELECT * FROM orders LIMIT 10') => 'orders'
~> durable.for_each('order', $orders.rows, ...)
```

Access nested fields with dot notation:

- `$orders.row_count` — Number of rows
- `$orders.rows[0].id` — First row's id field
- `$order.amount` — Current iteration item's amount (loop variable from `for_each`)

---

## Examples

### 1. RAG Pipeline: Chunking and Embedding

Process documents for retrieval-augmented generation with load awareness:

```sql
SELECT durable.start(
    durable.loop(
        durable.wait_idle(0.20, 3)
        
        -- Get documents, pre-batched for efficiency
        ~> durable.sql($$
            SELECT batch_num, json_agg(json_build_object('id', id, 'content', content)) as docs
            FROM (
                SELECT id, content, ntile(10) OVER (ORDER BY id) as batch_num
                FROM documents WHERE embedding IS NULL LIMIT 100
            ) t
            GROUP BY batch_num ORDER BY batch_num
        $$) => 'batches'
        
        ~> durable.if(
            '$batches.row_count > 0',
            durable.for_each('batch', $batches.rows,
                durable.if(
                    durable.is_idle(0.30, 5),
                    -- Process batch: chunk then embed
                    durable.for_each('doc', $batch.docs,
                        durable.func('chunk_document', '{"id": "$doc.id", "chunk_size": 512}') => 'chunks'
                        ~> durable.func('generate_embeddings', '{"chunks": $chunks}')
                    ),
                    durable.break()
                )
            )
            ~> durable.sleep('5 seconds'),
            durable.sleep('1 minute')
        )
    )
);
```

### 2. Order Processing

Process orders with validation:

```sql
SELECT durable.start(
    durable.sql('SELECT * FROM orders WHERE status = ''pending'' LIMIT 10') => 'orders'
    ~> durable.if(
        '$orders.row_count = 0',
        durable.sql('INSERT INTO log (msg) VALUES (''No pending orders'')'),
        durable.for_each('order', $orders.rows,
            -- Skip invalid orders
            durable.if('$order.amount < 10', durable.continue(), durable.noop())
            -- Process the order
            ~> durable.func('process_order', '{"id": "$order.id"}')
        )
    )
);
```

### 3. Event-Driven with Race and Timeout

Wait for payment or timeout, handle both cases:

```sql
SELECT durable.start(
    durable.func('send_invoice', '{"id": "inv-123"}')
    ~> (
        durable.wait_trigger('payment_received')
        | (durable.sleep('24 hours') ~> durable.value('{"timeout": true}'))
    ) => 'result'
    ~> durable.if(
        '$result.timeout',
        durable.func('escalate_invoice', '{"id": "inv-123"}'),
        durable.func('complete_order', '{"payment": "$result"}')
    )
);
```

### 4. Database Migration with Safety

Run migrations only when safe:

```sql
SELECT durable.start(
    durable.wait_idle(0.10, 5)
    ~> durable.wait_stat(
        'SELECT NOT EXISTS(SELECT 1 FROM pg_stat_activity WHERE state = ''active'' AND query_start < now() - ''5 min''::interval)',
        '30 seconds'
    )
    ~> durable.func('create_backup', '{"label": "pre_migration"}') => 'backup'
    ~> durable.func('run_migration', '{"version": "v42"}') => 'result'
    ~> durable.func('verify_migration', '{"version": "v42"}')
);
```

### 5. Azure Blob Storage Import with Checkpointing

Import large files from Azure Storage with batching, progress tracking, and automatic resume on failure.

Prerequisites:
```sql
CREATE EXTENSION azure_storage;
SELECT azure_storage.account_add('mystorageaccount', 'ACCESS_KEY_HERE');
```

Workflow:
```sql
SELECT durable.start(
    -- Get last sync checkpoint
    durable.sql($$
        SELECT last_path FROM sync_checkpoints 
        WHERE source = 'azure-events'
    $$) => 'checkpoint'
    
    -- List blobs after checkpoint
    ~> durable.sql($$ 
        SELECT path, bytes 
        FROM azure_storage.blob_list('mystorageaccount', 'events', '*.parquet')
        WHERE path > $1
        ORDER BY path
    $$, COALESCE($checkpoint.last_path, '')) => 'blobs'
    
    -- Process each blob
    ~> durable.for_each('blob', $blobs,
        -- Stream and insert
        durable.sql($$ 
            WITH imported AS (
                INSERT INTO events 
                SELECT * FROM azure_storage.blob_get(
                    'mystorageaccount', 'events', $1,
                    options := azure_storage.options_parquet_get()
                )
                RETURNING 1
            )
            SELECT count(*) as cnt FROM imported
        $$, $blob.path) => 'result'
        
        -- Update checkpoint after each file
        ~> durable.sql($$ 
            INSERT INTO sync_checkpoints (source, last_path, rows_imported, updated_at)
            VALUES ('azure-events', $1, $2, now())
            ON CONFLICT (source) DO UPDATE SET 
                last_path = EXCLUDED.last_path, 
                rows_imported = sync_checkpoints.rows_imported + EXCLUDED.rows_imported,
                updated_at = now()
        $$, $blob.path, $result.cnt)
    )
);
```

This workflow:
- Resumes from last checkpoint on restart
- Tracks per-file progress in `sync_checkpoints`
- Survives crashes mid-import (durability)
- Processes files in order for deterministic resume

### 6. Comprehensive Function Syntax

The same workflow using explicit function calls (no operators):

```sql
SELECT durable.start(
    durable.loop(
        durable.then(
            durable.wait_idle(0.20, 3),
            durable.then(
                durable.as('batch',
                    durable.sql('SELECT id FROM documents WHERE embedding IS NULL LIMIT 100')
                ),
                durable.if(
                    '$batch.row_count > 0',
                    durable.then(
                        durable.for_each('item', $batch.rows,
                            durable.if(
                                durable.is_idle(0.30, 5),
                                durable.func('generate_embedding', '{"id": "$item.id"}'),
                                durable.break()
                            )
                        ),
                        durable.sleep('5 seconds')
                    ),
                    durable.sleep('1 minute')
                )
            )
        )
    )
);
```

---

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PostgreSQL                                   │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    pg_durable Extension (pgrx)                  │ │
│  │                                                                  │ │
│  │  ┌──────────────────────────────────────────────────────────┐  │ │
│  │  │                    SQL DSL Layer                          │  │ │
│  │  │                                                            │  │ │
│  │  │  • SQL functions (durable.*)                              │  │ │
│  │  │  • Operators (~>, =>, &, |)                               │  │ │
│  │  │  • Composite types (durofut)                              │  │ │
│  │  │                                                            │  │ │
│  │  └──────────────────────────────────────────────────────────┘  │ │
│  │                                                                  │ │
│  │  ┌──────────────────────────────────────────────────────────┐  │ │
│  │  │              duroxide Runtime (background worker)         │  │ │
│  │  │                                                            │  │ │
│  │  │  • Polls duro_instances for new work                      │  │ │
│  │  │  • Loads workflow graph from duro_nodes                   │  │ │
│  │  │  • Executes as duroxide orchestration                     │  │ │
│  │  │  • Each step = duroxide activity (checkpointed)           │  │ │
│  │  │  • Survives crash via replay                              │  │ │
│  │  │                                                            │  │ │
│  │  │  Built-in Activities:                                     │  │ │
│  │  │    execute_sql   — Run SQL via SPI                        │  │ │
│  │  │    wait_idle     — Poll pg_stat_activity                  │  │ │
│  │  │    wait_trigger  — Wait for external event                │  │ │
│  │  │    http_request  — Make HTTP calls                        │  │ │
│  │  │                                                            │  │ │
│  │  └──────────────────────────────────────────────────────────┘  │ │
│  │                                                                  │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    durable Schema                               │ │
│  │                                                                  │ │
│  │  • duro_nodes     — Workflow graph (DAG of futures)            │ │
│  │  • duro_instances — Running workflow instances                  │ │
│  │  • duro_triggers  — Pending external events                     │ │
│  │  • duro_history   — Execution history (audit log)              │ │
│  │  • duroxide tables — Managed by duroxide-pg                     │ │
│  │                                                                  │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

**Key insight:** The duroxide runtime runs inside the PostgreSQL extension as a background worker, not as a separate process. This simplifies deployment and ensures the runtime has direct access to PostgreSQL internals via SPI.

### Data Flow

1. **User calls `durable.start(fut)`** — Extension builds workflow graph, stores in `duro_nodes`, creates instance in `duro_instances`, notifies background worker, returns instance ID.

2. **Background worker polls for work** — Queries for pending instances.

3. **Worker executes nodes** — Based on node type:
   - `THEN` — Execute left, then right
   - `JOIN` — Execute children in parallel, wait for all
   - `RACE` — Execute children in parallel, return first
   - `FUNC` — Dispatch to registered activity
   - `WAIT_*` — Poll or subscribe until condition met

4. **State persisted via duroxide-pg** — After each activity, duroxide persists checkpoint. Workflow survives PostgreSQL restart.

5. **Completion** — When root node completes, instance marked done in `duro_instances`.

### Schema

```sql
-- Workflow graph nodes
CREATE TABLE durable.duro_nodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id UUID NOT NULL,
    node_type TEXT NOT NULL,  -- THEN, JOIN, RACE, IF, LOOP, FOR_EACH, FUNC, SQL, WAIT_*, etc.
    config JSONB,             -- Node-specific configuration
    status TEXT DEFAULT 'Pending',  -- Pending, Running, Completed, Failed
    result JSONB,             -- Output when completed
    result_name TEXT,         -- Variable name for $ref substitution
    left_node UUID,           -- For THEN: first step
    right_node UUID,          -- For THEN: second step
    body_node UUID,           -- For LOOP, FOR_EACH: body to repeat
    children UUID[],          -- For JOIN, RACE: parallel children
    created_at TIMESTAMPTZ DEFAULT now(),
    completed_at TIMESTAMPTZ
);

-- Workflow instances
CREATE TABLE durable.duro_instances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    root_node UUID NOT NULL REFERENCES durable.duro_nodes(id),
    status TEXT DEFAULT 'Running',  -- Running, Completed, Failed, Cancelled
    created_at TIMESTAMPTZ DEFAULT now(),
    completed_at TIMESTAMPTZ
);

-- External triggers
CREATE TABLE durable.duro_triggers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id UUID NOT NULL,
    node_id UUID NOT NULL,
    trigger_name TEXT NOT NULL,
    payload JSONB,
    timeout_at TIMESTAMPTZ,
    fired_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Execution history (for debugging/audit)
CREATE TABLE durable.duro_history (
    id BIGSERIAL PRIMARY KEY,
    instance_id UUID NOT NULL,
    node_id UUID NOT NULL,
    event_type TEXT NOT NULL,  -- Started, Completed, Failed, Retried
    event_data JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);
```

### Variable Substitution

When a node references `$varname`, the executor:

1. Walks up the execution context to find a node with `result_name = 'varname'`
2. Retrieves that node's `result` JSONB
3. Applies the path (e.g., `$orders.rows[0].id` → `result->'rows'->0->>'id'`)
4. Substitutes into the current node's config

This happens at execution time, not at graph construction time.

---

## Implementation Details

### Extension (pgrx)

The PostgreSQL extension is built with [pgrx](https://github.com/pgcentralfoundation/pgrx) and provides:

**Composite Type:**
```sql
CREATE TYPE durable.durofut AS (
    node_id UUID
);
```

**Graph-Building Functions:**

Each `durable.*` function inserts a row into `duro_nodes` and returns a `durofut`:

```rust
#[pg_extern]
fn then(left: Durofut, right: Durofut) -> Durofut {
    let node_id = Uuid::new_v4();
    Spi::run(&format!(
        "INSERT INTO durable.duro_nodes (id, node_type, left_node, right_node)
         VALUES ('{}', 'THEN', '{}', '{}')",
        node_id, left.node_id, right.node_id
    ));
    Durofut { node_id }
}
```

**Operators:**
```sql
CREATE OPERATOR ~> (
    LEFTARG = durofut, RIGHTARG = durofut,
    FUNCTION = durable.then
);
```

### Runtime (Rust + duroxide)

The runtime is a standalone Rust binary using:
- `duroxide` — Durable task orchestration framework
- `duroxide-pg` — PostgreSQL backend for duroxide
- `sqlx` — Async PostgreSQL driver
- `tokio` — Async runtime

**Main Loop:**
```rust
async fn run_orchestrator(pool: PgPool) {
    loop {
        // Find instances with executable work
        let instances = sqlx::query_as::<_, Instance>(
            "SELECT * FROM durable.duro_instances WHERE status = 'Running'"
        ).fetch_all(&pool).await?;

        for instance in instances {
            // Execute the DAG from root
            execute_node(&pool, instance.root_node).await?;
        }

        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
```

**Node Execution:**
```rust
async fn execute_node(pool: &PgPool, node_id: Uuid) -> Result<JsonValue> {
    let node = fetch_node(pool, node_id).await?;
    
    match node.node_type.as_str() {
        "THEN" => {
            let left_result = execute_node(pool, node.left_node.unwrap()).await?;
            let right_result = execute_node(pool, node.right_node.unwrap()).await?;
            Ok(right_result)
        }
        "JOIN" => {
            let futures: Vec<_> = node.children.iter()
                .map(|id| execute_node(pool, *id))
                .collect();
            let results = futures::future::join_all(futures).await;
            Ok(json!(results))
        }
        "FUNC" => {
            let activity_name = node.config["name"].as_str().unwrap();
            let args = substitute_vars(&node.config["args"], &context);
            execute_activity(pool, activity_name, args).await
        }
        "WAIT_IDLE" => {
            loop {
                if check_idle(pool, &node.config).await? {
                    return Ok(json!({"idle": true}));
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
        // ... other node types
    }
}
```

### System Activities

Built-in activities implemented in Rust:

**execute_sql:**
```rust
async fn execute_sql(pool: &PgPool, query: &str) -> Result<JsonValue> {
    let rows = sqlx::query(query).fetch_all(pool).await?;
    Ok(json!({
        "row_count": rows.len(),
        "rows": rows_to_json(&rows)
    }))
}
```

**wait_idle:**
```rust
async fn wait_idle(pool: &PgPool, max_cpu: f64, max_sessions: i32) -> Result<JsonValue> {
    loop {
        let stats: (i64, f64) = sqlx::query_as(
            "SELECT count(*), COALESCE(avg(EXTRACT(EPOCH FROM (now() - query_start))), 0)
             FROM pg_stat_activity WHERE state = 'active'"
        ).fetch_one(pool).await?;
        
        if stats.0 <= max_sessions as i64 {
            return Ok(json!({"idle": true, "active_sessions": stats.0}));
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}
```

---

## Execution Plan

### MVP: Minimal Viable Proof-of-Concept

The goal is to prove the core architecture works: SQL DSL → Graph storage → duroxide execution.

**MVP Scope:**
- `durable.sql(query)` — Execute SQL, return result as JSON
- `durable.then(a, b)` — Sequential composition
- `durable.as(name, fut)` — Name a result for later reference
- `~>` operator — Shorthand for `then()`
- `=>` operator — Shorthand for `as()`
- `durable.start(fut)` — Start a workflow instance

**What MVP Proves:**
1. SQL functions can build a workflow graph and store it in tables
2. The duroxide runtime can load and execute that graph
3. Activity results persist and are available to subsequent steps
4. Workflow state survives runtime restart (durable execution)

**MVP Example:**
```sql
-- A simple 3-step workflow
SELECT durable.start(
    durable.sql('SELECT count(*) as total FROM users') => 'users'
    ~> durable.sql('SELECT count(*) as total FROM orders') => 'orders'
    ~> durable.sql('INSERT INTO stats (users, orders) VALUES ($1, $2)', 
        $users.rows[0].total, $orders.rows[0].total)
);
```

See `MVP.md` for detailed implementation plan and additional examples.

### Phase 0: Runtime Bootstrap (MVP Foundation)

**Step 1: duroxide-pg Hello World**
- [ ] Create runtime crate with duroxide + duroxide-pg dependencies
- [ ] Configure duroxide-pg to use `durable` schema for its internal tables
- [ ] Implement a trivial "hello world" orchestration
- [ ] Verify orchestration state persists across runtime restarts
- [ ] Validate replay works after simulated crash

**Step 2: Generic SQL Activity**
- [ ] Implement `execute_sql` activity that connects to the PG instance
- [ ] Accept query string and parameters
- [ ] Return result as JSON (`{rows: [...], row_count: N}`)
- [ ] Register as a duroxide activity

**Step 3: Extension Skeleton**
- [ ] Initialize pgrx project
- [ ] Create `durable` schema
- [ ] Define `durofut` composite type
- [ ] Create `duro_nodes`, `duro_instances` tables
- [ ] Implement `durable.sql()` — builds SQL node, stores in `duro_nodes`

**Step 4: Basic Combinators**
- [ ] `durable.then(a, b)` — builds THEN node linking two nodes
- [ ] `durable.as(name, fut)` — wraps node with result name
- [ ] `~>` operator for `then()`
- [ ] `=>` operator for `as()`

**Step 5: Control Plane**
- [ ] `durable.start(fut)` — creates instance, returns ID
- [ ] Runtime polls `duro_instances` for new work
- [ ] Runtime loads graph from `duro_nodes`
- [ ] Runtime executes via duroxide orchestration

**Step 6: End-to-End Test**
- [ ] Create a 3-step workflow via SQL
- [ ] Verify runtime picks it up and executes
- [ ] Kill runtime mid-execution
- [ ] Restart runtime, verify it resumes from checkpoint
- [ ] Verify final result is correct

### Phase 1: Extended Primitives

**Combinators:**
- [ ] `durable.join(array)` — parallel, wait all
- [ ] `durable.race(array)` — parallel, first wins
- [ ] `durable.if(cond, then, else)` — conditional
- [ ] `&` operator (join)
- [ ] `|` operator (race)

**Primitives:**
- [ ] `durable.func(name, args)` — call registered UDF
- [ ] `durable.sleep(interval)` — durable timer
- [ ] `durable.value(json)` — return literal
- [ ] `durable.noop()` — do nothing

### Phase 2: Advanced Flow Control

- [ ] `durable.loop(body)`
- [ ] `durable.for_each(var, source, body)`
- [ ] `durable.case_when(cases, otherwise)`
- [ ] `durable.break()`
- [ ] `durable.continue()`
- [ ] Variable substitution (`$name.path`)

### Phase 3: Wait Primitives

- [ ] `durable.wait_idle(max_cpu, max_sessions)`
- [ ] `durable.wait_stat(query, poll_interval)`
- [ ] `durable.wait_trigger(name, timeout)`
- [ ] `durable.fire_trigger(id, name, payload)`
- [ ] `durable.wait_replica_lag(max_bytes, replica)`
- [ ] `durable.is_idle(max_cpu, max_sessions)`

### Phase 4: HTTP & External

- [ ] `durable.http_get(url, headers)`
- [ ] `durable.http_post(url, body, headers)`
- [ ] Environment variable substitution (`$ENV.VAR`)

### Phase 5: Control Plane & Observability

- [ ] `durable.status(id)` — query workflow status
- [ ] `durable.cancel(id)` — cancel workflow
- [ ] `durable.batch(source, size)` — batch processing
- [ ] Execution history in `duro_history`
- [ ] Query interface for debugging
- [ ] Documentation

---

## Configuration

### Runtime (environment variables)

```bash
DATABASE_URL=postgres://user:pass@localhost:5432/mydb
DUROXIDE_WORKER_CONCURRENCY=10
DUROXIDE_ORCHESTRATION_CONCURRENCY=5
DUROXIDE_POLL_INTERVAL_MS=100
RUST_LOG=info,pg_durable=debug
```

### Extension (postgresql.conf)

```ini
shared_preload_libraries = 'pg_durable'  # optional
```

---

## Dependencies

### Extension

```toml
[dependencies]
pgrx = "0.12"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
uuid = { version = "1.0", features = ["v4", "serde"] }
```

### Runtime

```toml
[dependencies]
duroxide = "0.1"
duroxide-pg = "0.1"
tokio = { version = "1", features = ["full"] }
sqlx = { version = "0.8", features = ["runtime-tokio-rustls", "postgres", "uuid", "json"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
uuid = { version = "1.0", features = ["v4", "serde"] }
anyhow = "1.0"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
clap = { version = "4", features = ["derive"] }
```

---

## Success Criteria

- [ ] Workflows defined entirely in SQL
- [ ] Workflow state survives runtime restart
- [ ] Workflow state survives database restart (with WAL)
- [ ] Parallel execution works correctly (join, race)
- [ ] Nested loops and conditionals work
- [ ] Variable substitution works across nodes
- [ ] External triggers wake waiting workflows
- [ ] Status queries return accurate state
