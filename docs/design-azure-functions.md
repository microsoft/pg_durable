# Design: Azure Functions Integration for AI Workloads

This document outlines the design for calling Azure Functions from pg_durable, with a focus on AI scenarios like RAG pipelines, embeddings, and intelligent data processing.

> **Historical proposal; credential handling superseded (2026-09-10).**
> The `df.azure` helper and `df.secrets` table below are unimplemented proposals. Their construction-time key lookup would embed credentials in workflow state and must not be used for the new implementation. [Endpoint credentials](spec-security-model.md#44-endpoint-credentials) instead store references to foreign servers and user mappings, resolving them inside HTTP activities.
>
> The scenarios remain design examples, not a statement that all shown APIs are supported. See the [API reference](api-reference.md) and [HTTP security documentation](http-security.md) for current behavior.

---

## Table of Contents

1. [Overview](#overview)
2. [Proposed DSL](#proposed-dsl)
3. [Implementation](#implementation)
4. [AI Scenarios](#ai-scenarios)
   - [RAG Pipeline](#1-rag-pipeline)
   - [Document Processing & Embeddings](#2-document-processing--embeddings)
   - [Semantic Search](#3-semantic-search)
   - [Content Enrichment](#4-content-enrichment)
   - [Intelligent ETL](#5-intelligent-etl)
   - [Agentic Workflows](#6-agentic-workflows)
   - [Batch AI Processing](#7-batch-ai-processing)
   - [Real-time AI Triggers](#8-real-time-ai-triggers)
5. [Configuration](#configuration)

---

## Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           pg_durable                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                 │
│  │   df.sql()  │───►│  df.http()  │───►│  df.sql()   │                 │
│  │  Get Data   │    │ Call Azure  │    │Store Result │                 │
│  └─────────────┘    └──────┬──────┘    └─────────────┘                 │
└────────────────────────────┼────────────────────────────────────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │      Azure Functions         │
              │  ┌────────────────────────┐  │
              │  │ • OpenAI / Azure OpenAI│  │
              │  │ • Embeddings           │  │
              │  │ • Document parsing     │  │
              │  │ • Image analysis       │  │
              │  │ • Custom ML models     │  │
              │  └────────────────────────┘  │
              └──────────────────────────────┘
```

**Why Azure Functions for AI?**
- Access to Azure OpenAI, Cognitive Services, custom models
- Handle rate limits and retries at the function level
- Keep API keys secure (not in database)
- Scale compute independently from PostgreSQL
- Process large documents, images, audio outside the database

---

## Proposed DSL

### `df.http()` - HTTP Calls

```sql
df.http(
    url TEXT,                           -- Endpoint URL
    method TEXT DEFAULT 'POST',         -- GET, POST, PUT, DELETE
    body TEXT DEFAULT NULL,             -- Request body (JSON)
    headers JSONB DEFAULT '{}',         -- Custom headers
    timeout_seconds INT DEFAULT 60      -- Request timeout
) RETURNS TEXT
```

### `df.azure()` - Azure Functions Shorthand

```sql
df.azure(
    function_app TEXT,                  -- e.g., 'my-ai-functions'
    function_name TEXT,                 -- e.g., 'generate-embedding'
    body TEXT DEFAULT NULL              -- JSON payload
) RETURNS TEXT
```

Automatically constructs URL: `https://{function_app}.azurewebsites.net/api/{function_name}`
and adds function key from `df.secrets` table.

---

## Implementation

### DSL Function (Rust) - in `src/dsl.rs`

```rust
/// Creates an HTTP request node
#[pg_extern(schema = "df")]
pub fn http(
    url: &str,
    method: default!(&str, "'POST'"),
    body: default!(Option<&str>, "NULL"),
    headers: default!(Option<pgrx::JsonB>, "NULL"),
    timeout_seconds: default!(i32, "60"),
) -> String {
    let config = serde_json::json!({
        "url": url,
        "method": method,
        "body": body,
        "headers": headers.map(|h| h.0),
        "timeout_seconds": timeout_seconds
    });

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "HTTP".to_string(),
        left_node: None,
        right_node: None,
        query: Some(config.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Azure Functions convenience wrapper
#[pg_extern(schema = "df")]
pub fn azure(
    function_app: &str,
    function_name: &str,
    body: default!(Option<&str>, "NULL"),
) -> String {
    let url = format!(
        "https://{}.azurewebsites.net/api/{}",
        function_app, function_name
    );
    
    // Get function key from secrets table
    let key: Option<String> = Spi::get_one(&format!(
        "SELECT value FROM df.secrets WHERE name = '{}_key'",
        function_app
    )).ok().flatten();
    
    let mut headers = serde_json::Map::new();
    if let Some(k) = key {
        headers.insert("x-functions-key".to_string(), serde_json::json!(k));
    }
    headers.insert("Content-Type".to_string(), serde_json::json!("application/json"));
    
    http(&url, "POST", body, Some(pgrx::JsonB(serde_json::json!(headers))), 60)
}
```

### Activity Registration - in `src/runtime.rs`

The `ExecuteHTTP` activity is registered alongside existing activities like `ExecuteSQL`:

```rust
// In run_duroxide_runtime_with_shutdown(), add to ActivityRegistry::builder()

let activities = ActivityRegistry::builder()
    // ... existing activities (ExecuteSQL, LoadFunctionGraph, etc.) ...
    
    .register("ExecuteHTTP", move |ctx: ActivityContext, config_json: String| {
        async move {
            let config: HttpConfig = serde_json::from_str(&config_json)
                .map_err(|e| format!("Invalid HTTP config: {}", e))?;
            
            ctx.trace_info(format!("HTTP {} {}", config.method, config.url));
            
            let client = reqwest::Client::builder()
                .timeout(Duration::from_secs(config.timeout_seconds as u64))
                .build()
                .map_err(|e| format!("Failed to create HTTP client: {}", e))?;
            
            let mut request = match config.method.as_str() {
                "GET" => client.get(&config.url),
                "POST" => client.post(&config.url),
                "PUT" => client.put(&config.url),
                "DELETE" => client.delete(&config.url),
                _ => return Err(format!("Unsupported method: {}", config.method)),
            };
            
            // Add headers
            if let Some(headers) = &config.headers {
                if let Some(obj) = headers.as_object() {
                    for (key, value) in obj {
                        if let Some(v) = value.as_str() {
                            request = request.header(key, v);
                        }
                    }
                }
            }
            
            // Add body
            if let Some(body) = &config.body {
                request = request.body(body.clone());
            }
            
            // Execute request
            let response = request.send().await
                .map_err(|e| format!("HTTP request failed: {}", e))?;
            
            let status = response.status();
            let response_body = response.text().await
                .map_err(|e| format!("Failed to read response: {}", e))?;
            
            if !status.is_success() {
                return Err(format!("HTTP {} {} returned {}: {}", 
                    config.method, config.url, status, response_body));
            }
            
            ctx.trace_info(format!("HTTP {} completed with status {}", config.method, status));
            Ok(response_body)
        }
    })
    .build();
```

### Node Execution - in `execute_node_inner()`

Add the HTTP node type handler:

```rust
// In execute_node_inner() match statement, add:

"http" => {
    let config_str = node
        .query
        .as_ref()
        .ok_or_else(|| format!("HTTP node {} has no config", node_id))?;
    
    // Substitute variables in the config (for body with $variables)
    let config: serde_json::Value = serde_json::from_str(config_str)
        .map_err(|e| format!("Invalid HTTP config: {}", e))?;
    
    // Substitute variables in body if present
    let final_config = if let Some(body) = config.get("body").and_then(|b| b.as_str()) {
        let substituted_body = substitute_variables(body, results);
        let mut config_map = config.as_object().unwrap().clone();
        config_map.insert("body".to_string(), serde_json::json!(substituted_body));
        serde_json::to_string(&config_map).unwrap()
    } else {
        config_str.clone()
    };
    
    ctx.trace_info(format!("Executing HTTP request"));
    
    let result = ctx
        .schedule_activity("ExecuteHTTP", final_config)
        .into_activity()
        .await?;
    
    // Store result if named
    if let Some(name) = &node.result_name {
        ctx.trace_info(format!("Storing HTTP result as ${}", name));
        results.insert(name.clone(), result.clone());
    }
    
    Ok(result)
}
```

### Config Struct

```rust
// In src/types.rs

#[derive(Debug, Serialize, Deserialize)]
pub struct HttpConfig {
    pub url: String,
    pub method: String,
    pub body: Option<String>,
    pub headers: Option<serde_json::Value>,
    pub timeout_seconds: u64,
}
```

### Cargo.toml Addition

```toml
[dependencies]
reqwest = { version = "0.11", features = ["json", "rustls-tls"] }
```

---

## AI Scenarios

### 1. RAG Pipeline

Retrieve relevant documents, augment with context, generate response.

```sql
-- Azure Function: generate-embedding
-- Azure Function: chat-completion

SELECT df.start(
    -- Step 1: Get user query
    'SELECT query, session_id FROM chat_messages 
     WHERE id = $1' |=> 'input'

    -- Step 2: Generate embedding for the query
    ~> df.azure(
        'ai-functions',
        'generate-embedding',
        '{"text": "' || ($input).query || '"}'
    ) |=> 'query_embedding'

    -- Step 3: Find similar documents (vector search)
    ~> 'SELECT array_agg(content) as docs
        FROM (
            SELECT content 
            FROM knowledge_base
            ORDER BY embedding <=> ($query_embedding::jsonb->>''embedding'')::vector
            LIMIT 5
        ) t' |=> 'context_docs'

    -- Step 4: Generate response with context
    ~> df.azure(
        'ai-functions',
        'chat-completion',
        '{
            "messages": [
                {"role": "system", "content": "Answer based on this context: ' || $context_docs || '"},
                {"role": "user", "content": "' || ($input).query || '"}
            ]
        }'
    ) |=> 'response'

    -- Step 5: Store response
    ~> 'INSERT INTO chat_messages (session_id, role, content)
        VALUES (($input).session_id, ''assistant'', ($response::jsonb->>''content''))',

    'rag-query'
);
```

### 2. Document Processing & Embeddings

Process uploaded documents, chunk, embed, and store.

```sql
-- Azure Function: parse-document (PDF, DOCX, etc.)
-- Azure Function: chunk-text
-- Azure Function: batch-embeddings

SELECT df.start(
    -- Get unprocessed documents
    'SELECT id, file_url, filename FROM documents 
     WHERE status = ''pending'' 
     LIMIT 10' |=> 'docs'

    -- Parse documents (extract text from PDF/DOCX)
    ~> df.azure(
        'ai-functions',
        'parse-document',
        '{"documents": ' || $docs || '}'
    ) |=> 'parsed'

    -- Chunk the text
    ~> df.azure(
        'ai-functions',
        'chunk-text',
        '{
            "documents": ' || $parsed || ',
            "chunk_size": 512,
            "chunk_overlap": 50
        }'
    ) |=> 'chunks'

    -- Generate embeddings for all chunks
    ~> df.azure(
        'ai-functions',
        'batch-embeddings',
        '{"texts": ' || ($chunks::jsonb->>'texts') || '}'
    ) |=> 'embeddings'

    -- Store chunks with embeddings
    ~> 'INSERT INTO document_chunks (document_id, chunk_index, content, embedding)
        SELECT 
            (c->>''document_id'')::int,
            (c->>''chunk_index'')::int,
            c->>''content'',
            (e->>''embedding'')::vector
        FROM json_array_elements($chunks::json) WITH ORDINALITY AS t(c, idx)
        JOIN json_array_elements($embeddings::json) WITH ORDINALITY AS e(e, eidx)
        ON t.idx = e.eidx'

    -- Update document status
    ~> 'UPDATE documents SET status = ''processed'' 
        WHERE id IN (SELECT (d->>''id'')::int FROM json_array_elements($docs::json) d)',

    'process-documents'
);

-- Schedule continuous document processing
SELECT df.start(
    @> (
        df.wait_for_schedule('*/5 * * * *')  -- Every 5 minutes
        ~> 'SELECT df.start(
                ''SELECT 1 FROM documents WHERE status = ''''pending'''' LIMIT 1'' 
                ~> df.if(
                    ''SELECT EXISTS (SELECT 1 FROM documents WHERE status = ''''pending'''')'',
                    -- Trigger batch processing
                    ''SELECT df.start(..., ''''process-documents-batch'''')'',
                    ''SELECT ''''no pending documents''''''
                ),
                ''check-pending-docs''
            )'
    ),
    'document-processing-scheduler'
);
```

### 3. Semantic Search

Build a semantic search API using embeddings.

```sql
-- Azure Function: generate-embedding
-- Azure Function: rerank (optional)

-- Search function that can be called from your application
CREATE OR REPLACE FUNCTION search_knowledge_base(
    query TEXT,
    top_k INT DEFAULT 10
) RETURNS TABLE(id INT, content TEXT, score FLOAT) AS $$
DECLARE
    instance_id TEXT;
    result JSONB;
BEGIN
    -- Start durable search
    instance_id := df.start(
        'SELECT ''' || query || '''::text' |=> 'query'
        
        -- Generate query embedding
        ~> df.azure(
            'ai-functions',
            'generate-embedding',
            '{"text": "' || query || '"}'
        ) |=> 'embedding'
        
        -- Vector search
        ~> 'SELECT json_agg(row_to_json(t)) FROM (
                SELECT id, content, 
                       1 - (embedding <=> (''' || '||$embedding::jsonb->>''embedding''||' || ''')::vector) as score
                FROM knowledge_base
                ORDER BY embedding <=> (''' || '||$embedding::jsonb->>''embedding''||' || ''')::vector
                LIMIT ' || top_k || '
            ) t' |=> 'results',
        'semantic-search-' || md5(query)
    );
    
    -- Wait for completion (simplified - real impl would poll)
    PERFORM pg_sleep(2);
    
    -- Get results
    SELECT df.result(instance_id)::jsonb INTO result;
    
    RETURN QUERY
    SELECT 
        (r->>'id')::int,
        r->>'content',
        (r->>'score')::float
    FROM jsonb_array_elements(result) r;
END;
$$ LANGUAGE plpgsql;

-- With re-ranking for better accuracy
SELECT df.start(
    'SELECT $1' |=> 'query'
    
    -- Initial vector search (get more candidates)
    ~> df.azure('ai-functions', 'generate-embedding', '{"text": "$query"}') |=> 'emb'
    ~> 'SELECT json_agg(row_to_json(t)) FROM (
            SELECT id, content FROM knowledge_base
            ORDER BY embedding <=> ($emb::jsonb->>''embedding'')::vector
            LIMIT 50
        ) t' |=> 'candidates'
    
    -- Re-rank with cross-encoder
    ~> df.azure(
        'ai-functions',
        'rerank',
        '{
            "query": "$query",
            "documents": $candidates
        }'
    ) |=> 'reranked'
    
    -- Return top results
    ~> 'SELECT json_agg(r) FROM (
            SELECT * FROM json_array_elements($reranked::json) 
            LIMIT 10
        ) r',
    
    'semantic-search-reranked'
);
```

### 4. Content Enrichment

Automatically enrich content with AI-generated metadata.

```sql
-- Azure Functions:
-- - extract-entities (NER)
-- - classify-content (categorization)
-- - generate-summary
-- - analyze-sentiment
-- - extract-keywords

SELECT df.start(
    -- Get articles to enrich
    'SELECT id, title, content FROM articles 
     WHERE enriched_at IS NULL 
     LIMIT 20' |=> 'articles'

    -- Run enrichments in parallel
    ~> df.join3(
        -- Entity extraction
        df.azure(
            'ai-functions',
            'extract-entities',
            '{"articles": ' || $articles || '}'
        ) |=> 'entities',

        -- Classification + Sentiment (can batch together)
        df.azure(
            'ai-functions',
            'classify-content',
            '{"articles": ' || $articles || ', "categories": ["tech", "business", "science", "health"]}'
        ) |=> 'classifications',

        -- Summarization
        df.azure(
            'ai-functions',
            'generate-summaries',
            '{"articles": ' || $articles || ', "max_length": 150}'
        ) |=> 'summaries'
    )

    -- Store enrichments
    ~> 'UPDATE articles a SET
            entities = (SELECT entities FROM json_array_elements($entities::json) e WHERE (e->>''id'')::int = a.id),
            category = (SELECT category FROM json_array_elements($classifications::json) c WHERE (c->>''id'')::int = a.id),
            sentiment = (SELECT sentiment FROM json_array_elements($classifications::json) c WHERE (c->>''id'')::int = a.id),
            summary = (SELECT summary FROM json_array_elements($summaries::json) s WHERE (s->>''id'')::int = a.id),
            enriched_at = now()
        WHERE a.id IN (SELECT (x->>''id'')::int FROM json_array_elements($articles::json) x)',

    'enrich-articles'
);

-- Scheduled enrichment job
SELECT df.start(
    @> (
        df.wait_for_schedule('*/15 * * * *')
        ~> 'SELECT COUNT(*) FROM articles WHERE enriched_at IS NULL' |=> 'pending'
        ~> df.if(
            'SELECT $pending > 0',
            'SELECT df.start(''...'', ''enrich-batch'')',
            'SELECT ''nothing to enrich'''
        )
    ),
    'content-enrichment-scheduler'
);
```

### 5. Intelligent ETL

AI-powered data transformation and cleaning.

```sql
-- Azure Functions:
-- - normalize-addresses
-- - deduplicate-fuzzy
-- - classify-transactions
-- - detect-anomalies

SELECT df.start(
    -- Extract: Get raw data
    'SELECT json_agg(row_to_json(r)) FROM raw_transactions r
     WHERE processed_at IS NULL
     LIMIT 1000' |=> 'raw_data'

    -- Transform: Normalize and classify
    ~> df.azure(
        'ai-functions',
        'normalize-addresses',
        '{"records": ' || $raw_data || '}'
    ) |=> 'normalized'

    ~> df.azure(
        'ai-functions',
        'classify-transactions',
        '{
            "transactions": ' || $normalized || ',
            "categories": ["groceries", "utilities", "entertainment", "travel", "other"]
        }'
    ) |=> 'classified'

    -- Detect anomalies
    ~> df.azure(
        'ai-functions',
        'detect-anomalies',
        '{"transactions": ' || $classified || '}'
    ) |=> 'with_anomalies'

    -- Load: Insert into clean tables
    ~> 'INSERT INTO transactions (
            id, amount, category, normalized_merchant, 
            normalized_address, is_anomaly, anomaly_reason
        )
        SELECT 
            (t->>''id'')::int,
            (t->>''amount'')::numeric,
            t->>''category'',
            t->>''normalized_merchant'',
            t->>''normalized_address'',
            (t->>''is_anomaly'')::boolean,
            t->>''anomaly_reason''
        FROM json_array_elements($with_anomalies::json) t'

    -- Mark as processed
    ~> 'UPDATE raw_transactions SET processed_at = now()
        WHERE id IN (SELECT (r->>''id'')::int FROM json_array_elements($raw_data::json) r)'

    -- Alert on anomalies
    ~> 'SELECT COUNT(*) FROM json_array_elements($with_anomalies::json) t 
        WHERE (t->>''is_anomaly'')::boolean' |=> 'anomaly_count'
    ~> df.if(
        'SELECT $anomaly_count > 0',
        'INSERT INTO alerts (type, message, data)
         VALUES (''anomaly'', $anomaly_count || '' anomalies detected'', $with_anomalies::jsonb)',
        'SELECT ''no anomalies'''
    ),

    'intelligent-etl-pipeline'
);
```

### 6. Agentic Workflows

Multi-step AI reasoning with tool use.

```sql
-- Azure Functions:
-- - agent-reason (LLM reasoning step)
-- - agent-tool-search (search tool)
-- - agent-tool-calculate (calculation tool)
-- - agent-tool-lookup (database lookup tool)

SELECT df.start(
    -- Initialize agent with task
    'SELECT $1 as task, ''[]''::jsonb as history' |=> 'state'

    -- Agent loop (max 10 iterations)
    ~> df.loop(
        -- Reasoning step: decide next action
        df.azure(
            'ai-functions',
            'agent-reason',
            '{
                "task": "($state).task",
                "history": ($state).history,
                "available_tools": ["search", "calculate", "lookup", "respond"]
            }'
        ) |=> 'decision'

        -- Check if agent wants to respond (done)
        ~> df.if(
            'SELECT ($decision::jsonb->>''action'') = ''respond''',
            -- Final response - exit loop
            'SELECT ($decision::jsonb->>''response'')' 
            ~> 'SELECT df.cancel(df.current_instance(), ''agent complete'')',

            -- Execute tool
            df.if(
                'SELECT ($decision::jsonb->>''action'') = ''search''',
                df.azure('ai-functions', 'agent-tool-search', 
                    '{"query": "' || ($decision::jsonb->'params'->>'query') || '"}'),
                df.if(
                    'SELECT ($decision::jsonb->>''action'') = ''calculate''',
                    df.azure('ai-functions', 'agent-tool-calculate',
                        '{"expression": "' || ($decision::jsonb->'params'->>'expression') || '"}'),
                    df.azure('ai-functions', 'agent-tool-lookup',
                        '{"table": "' || ($decision::jsonb->'params'->>'table') || '", 
                          "query": "' || ($decision::jsonb->'params'->>'query') || '"}')
                )
            ) |=> 'tool_result'

            -- Update history
            ~> 'SELECT jsonb_build_object(
                    ''task'', ($state).task,
                    ''history'', ($state).history || jsonb_build_array(
                        jsonb_build_object(
                            ''action'', ($decision::jsonb->>''action''),
                            ''params'', ($decision::jsonb->''params''),
                            ''result'', $tool_result::jsonb
                        )
                    )
                )' |=> 'state'
        )
    ),

    'agent-workflow'
);

-- Simplified: ReAct-style agent
SELECT df.start(
    'SELECT ''What were our top 5 products by revenue last month?''' |=> 'question'

    -- Step 1: Plan
    ~> df.azure('ai-functions', 'agent-plan',
        '{"question": "$question", "available_actions": ["sql_query", "summarize"]}') |=> 'plan'

    -- Step 2: Execute SQL (agent generates the query)
    ~> 'SELECT json_agg(row_to_json(t)) FROM (' || ($plan::jsonb->'steps'->>0) || ') t' |=> 'data'

    -- Step 3: Summarize results
    ~> df.azure('ai-functions', 'summarize-data',
        '{"question": "$question", "data": ' || $data || '}') |=> 'answer'

    -- Store Q&A
    ~> 'INSERT INTO qa_log (question, answer, data) VALUES ($question, $answer, $data::jsonb)',

    'data-analyst-agent'
);
```

### 7. Batch AI Processing

Process large datasets efficiently with batching.

```sql
-- Azure Function: batch-process (handles rate limits, batching internally)

SELECT df.start(
    @> (
        -- Get batch of unprocessed items
        'WITH batch AS (
            SELECT id, content 
            FROM items 
            WHERE ai_processed = false 
            LIMIT 100
            FOR UPDATE SKIP LOCKED
        )
        SELECT json_agg(row_to_json(b)) FROM batch b' |=> 'batch'

        ~> df.if(
            'SELECT $batch IS NOT NULL AND json_array_length($batch::json) > 0',

            -- Process batch
            df.azure(
                'ai-functions',
                'batch-process',
                '{
                    "items": ' || $batch || ',
                    "operations": ["embed", "classify", "extract_keywords"]
                }'
            ) |=> 'results'

            -- Update items with results
            ~> 'UPDATE items i SET
                    embedding = (r->>''embedding'')::vector,
                    category = r->>''category'',
                    keywords = (r->''keywords'')::jsonb,
                    ai_processed = true
                FROM json_array_elements($results::json) r
                WHERE i.id = (r->>''id'')::int'

            -- Log progress
            ~> 'INSERT INTO processing_log (batch_size, processed_at)
                VALUES (json_array_length($batch::json), now())'

            -- Small delay to respect rate limits
            ~> df.sleep(2),

            -- No more items, longer sleep
            df.sleep(60)
        )
    ),
    'batch-ai-processor'
);

-- Parallel batch processing for higher throughput
SELECT df.start(
    @> (
        df.sleep(10)
        
        -- Get 3 batches
        ~> 'SELECT json_agg(batch) FROM (
                SELECT json_agg(row_to_json(i)) as batch
                FROM (
                    SELECT id, content, row_number() OVER () as rn
                    FROM items WHERE ai_processed = false LIMIT 300
                ) i
                GROUP BY (rn - 1) / 100
            ) batches' |=> 'batches'

        ~> df.if(
            'SELECT $batches IS NOT NULL',
            -- Process 3 batches in parallel
            df.join3(
                df.azure('ai-functions', 'batch-process', 
                    '{"items": ' || ($batches::jsonb->0) || '}'),
                df.azure('ai-functions', 'batch-process', 
                    '{"items": ' || ($batches::jsonb->1) || '}'),
                df.azure('ai-functions', 'batch-process', 
                    '{"items": ' || ($batches::jsonb->2) || '}')
            ),
            df.sleep(60)
        )
    ),
    'parallel-batch-processor'
);
```

### 8. Idle-Time Content Enrichment

Process documents in the background when the database is idle using `df.wait_for_idle()`.

**Why idle-time processing?**
- Don't compete with OLTP workloads during peak hours
- AI API calls are expensive - batch them efficiently  
- Large document processing can be deferred
- Embeddings don't need to be real-time for most use cases

```sql
-- df.wait_for_idle() waits until database activity drops below threshold
-- Parameters:
--   idle_threshold_pct: CPU/connection usage threshold (default 20%)
--   min_idle_seconds: How long to wait at idle before triggering (default 30)
--   check_interval_seconds: How often to check (default 10)

df.wait_for_idle(
    idle_threshold_pct => 20,      -- Trigger when < 20% busy
    min_idle_seconds => 30,        -- Must be idle for 30s
    max_wait_seconds => 3600       -- Give up after 1 hour
)
```

**Document Enrichment Pipeline (Idle-Time):**

```sql
SELECT df.start(
    @> (
        -- Wait for database to be idle
        df.wait_for_idle(
            idle_threshold_pct => 15,
            min_idle_seconds => 60
        )
        
        -- Get batch of unenriched documents
        ~> 'SELECT id, title, content, file_type 
            FROM documents 
            WHERE enriched_at IS NULL 
            AND created_at < now() - interval ''5 minutes''  -- Not too fresh
            ORDER BY priority DESC, created_at
            LIMIT 50
            FOR UPDATE SKIP LOCKED' |=> 'batch'
        
        ~> df.if(
            'SELECT $batch IS NOT NULL AND json_array_length($batch::json) > 0',
            
            -- Process the batch
            df.join3(
                -- Generate embeddings
                df.azure('ai-functions', 'batch-embeddings',
                    '{"documents": ' || $batch || '}') |=> 'embeddings',
                
                -- Extract entities and keywords
                df.azure('ai-functions', 'extract-metadata',
                    '{"documents": ' || $batch || '}') |=> 'metadata',
                
                -- Generate summaries
                df.azure('ai-functions', 'generate-summaries',
                    '{"documents": ' || $batch || ', "max_length": 200}') |=> 'summaries'
            )
            
            -- Store all enrichments
            ~> 'UPDATE documents d SET
                    embedding = (e->>''embedding'')::vector,
                    entities = (m->''entities'')::jsonb,
                    keywords = (m->''keywords'')::jsonb,
                    summary = s->>''summary'',
                    enriched_at = now()
                FROM json_array_elements($embeddings::json) WITH ORDINALITY AS t1(e, idx)
                JOIN json_array_elements($metadata::json) WITH ORDINALITY AS t2(m, midx) ON t1.idx = t2.midx
                JOIN json_array_elements($summaries::json) WITH ORDINALITY AS t3(s, sidx) ON t1.idx = t3.sidx
                WHERE d.id = (e->>''id'')::int'
            
            -- Log progress
            ~> 'INSERT INTO enrichment_log (batch_size, processed_at)
                VALUES (json_array_length($batch::json), now())',
            
            -- Nothing to process, sleep longer before next idle check
            df.sleep(300)
        )
    ),
    'idle-document-enrichment'
);
```

**Multi-Stage Document Pipeline (Idle-Aware):**

```sql
-- Stage 1: Quick metadata extraction (runs frequently)
SELECT df.start(
    @> (
        df.wait_for_schedule('*/2 * * * *')  -- Every 2 minutes
        
        ~> 'SELECT id, filename, file_type FROM documents 
            WHERE basic_metadata IS NULL LIMIT 100' |=> 'docs'
        
        ~> df.if(
            'SELECT json_array_length($docs::json) > 0',
            -- Quick local processing (no AI needed)
            'UPDATE documents SET 
                basic_metadata = jsonb_build_object(
                    ''filename'', filename,
                    ''extension'', split_part(filename, ''.'', -1),
                    ''size_category'', CASE 
                        WHEN length(content) < 1000 THEN ''small''
                        WHEN length(content) < 10000 THEN ''medium''
                        ELSE ''large''
                    END
                ),
                processing_stage = ''metadata_done''
            WHERE id IN (SELECT (d->>''id'')::int FROM json_array_elements($docs::json) d)',
            'SELECT ''no docs'''
        )
    ),
    'quick-metadata-extraction'
);

-- Stage 2: AI enrichment (runs during idle time only)
SELECT df.start(
    @> (
        -- Only run when database is idle
        df.wait_for_idle(idle_threshold_pct => 10, min_idle_seconds => 120)
        
        -- Get documents ready for AI processing
        ~> 'SELECT id, content, basic_metadata 
            FROM documents 
            WHERE processing_stage = ''metadata_done''
            AND (basic_metadata->>''size_category'') != ''large''  -- Skip large docs for now
            ORDER BY created_at
            LIMIT 25' |=> 'ready_docs'
        
        ~> df.if(
            'SELECT json_array_length($ready_docs::json) > 0',
            
            -- Full AI enrichment
            df.azure('ai-functions', 'full-enrichment', '{
                "documents": ' || $ready_docs || ',
                "operations": ["embed", "summarize", "extract_entities", "classify"]
            }') |=> 'enriched'
            
            ~> 'UPDATE documents d SET
                    embedding = (e->>''embedding'')::vector,
                    summary = e->>''summary'',
                    entities = (e->''entities'')::jsonb,
                    category = e->>''category'',
                    processing_stage = ''ai_done'',
                    enriched_at = now()
                FROM json_array_elements($enriched::json) e
                WHERE d.id = (e->>''id'')::int',
            
            df.sleep(60)
        )
    ),
    'idle-ai-enrichment'
);

-- Stage 3: Large document processing (runs during extended idle periods)
SELECT df.start(
    @> (
        -- Wait for extended idle period (e.g., late night)
        df.wait_for_idle(idle_threshold_pct => 5, min_idle_seconds => 300)
        
        ~> 'SELECT id, content FROM documents 
            WHERE processing_stage = ''metadata_done''
            AND (basic_metadata->>''size_category'') = ''large''
            LIMIT 5' |=> 'large_docs'
        
        ~> df.if(
            'SELECT json_array_length($large_docs::json) > 0',
            
            -- Process large docs one at a time (chunking required)
            df.azure('ai-functions', 'process-large-document', '{
                "document": ' || ($large_docs::jsonb->0) || ',
                "chunk_size": 4000,
                "chunk_overlap": 200
            }') |=> 'result'
            
            ~> 'UPDATE documents SET
                    chunks = ($result->''chunks'')::jsonb,
                    embedding = NULL,  -- Large docs use chunk embeddings instead
                    processing_stage = ''chunked'',
                    enriched_at = now()
                WHERE id = (($large_docs::jsonb->0)->>''id'')::int'
            
            -- Store chunk embeddings separately
            ~> 'INSERT INTO document_chunks (document_id, chunk_index, content, embedding)
                SELECT 
                    (($large_docs::jsonb->0)->>''id'')::int,
                    (c->>''index'')::int,
                    c->>''content'',
                    (c->>''embedding'')::vector
                FROM json_array_elements(($result->''chunks'')::json) c',
            
            df.sleep(600)  -- Long sleep if no large docs
        )
    ),
    'idle-large-document-processor'
);
```

**Adaptive Processing Based on Load:**

```sql
SELECT df.start(
    @> (
        -- Check current database load
        'SELECT 
            (SELECT count(*) FROM pg_stat_activity WHERE state = ''active'') as active_connections,
            (SELECT COALESCE(avg(xact_commit + xact_rollback), 0) 
             FROM pg_stat_database WHERE datname = current_database()) as txn_rate
        ' |=> 'load'
        
        ~> df.if(
            -- Very idle: aggressive processing
            'SELECT ($load).active_connections < 3',
            
            'SELECT 100' |=> 'batch_size'
            ~> df.azure('ai-functions', 'batch-process', 
                '{"documents": (SELECT json_agg(d) FROM documents d WHERE enriched_at IS NULL LIMIT $batch_size)}'),
            
            df.if(
                -- Moderately idle: conservative processing
                'SELECT ($load).active_connections < 10',
                
                'SELECT 20' |=> 'batch_size'
                ~> df.azure('ai-functions', 'batch-process',
                    '{"documents": (SELECT json_agg(d) FROM documents d WHERE enriched_at IS NULL LIMIT $batch_size)}'),
                
                -- Busy: skip this cycle
                df.sleep(60)
            )
        )
        
        ~> df.sleep(30)
    ),
    'adaptive-enrichment'
);
```

**Efficient Implementation of `df.wait_for_idle()`:**

The challenge: How do we efficiently detect database idleness without creating load ourselves?

**Design Goals:**
1. Minimal overhead - don't poll constantly
2. Accurate idle detection - use multiple signals
3. Durable - survive restarts mid-wait
4. Adaptive - back off when busy, check more when trending idle

**Approach: Timer-based with adaptive interval + composite idle score**

```
┌─────────────────────────────────────────────────────────────────┐
│                     WAIT_IDLE Node Execution                    │
├─────────────────────────────────────────────────────────────────┤
│  1. Schedule durable timer (not activity - no overhead)         │
│  2. On wake: single lightweight activity to compute idle score  │
│  3. If idle: check if sustained → proceed                       │
│  4. If busy: exponential backoff on next timer                  │
│  5. Persist state in node for crash recovery                    │
└─────────────────────────────────────────────────────────────────┘
```

**Key Insight**: Use `ctx.schedule_timer()` (durable timer) not polling activities. Timers are cheap - they're just timestamps in the duroxide store.

```rust
// DSL function
#[pg_extern(schema = "df")]
pub fn wait_for_idle(
    idle_threshold_pct: default!(i32, "20"),
    min_idle_seconds: default!(i32, "30"),
    max_wait_seconds: default!(i32, "3600"),
) -> String {
    let config = serde_json::json!({
        "idle_threshold_pct": idle_threshold_pct,
        "min_idle_seconds": min_idle_seconds,
        "max_wait_seconds": max_wait_seconds
    });

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "WAIT_IDLE".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    };
    durofut.insert_node();
    durofut.to_json()
}
```

**Idle Score Calculation (Single Query):**

```sql
-- One efficient query that computes a composite idle score (0-100)
-- Higher = more idle
CREATE OR REPLACE FUNCTION df.compute_idle_score() 
RETURNS TABLE(score INT, details JSONB) AS $$
WITH metrics AS (
    -- Active connections (excluding our own)
    SELECT 
        COUNT(*) FILTER (WHERE state = 'active' AND pid != pg_backend_pid()) as active_queries,
        COUNT(*) FILTER (WHERE state = 'idle in transaction') as idle_in_txn,
        COUNT(*) as total_connections,
        MAX(EXTRACT(EPOCH FROM (now() - query_start)) FILTER (WHERE state = 'active')) as longest_query_sec
    FROM pg_stat_activity
    WHERE datname = current_database()
),
db_stats AS (
    -- Transaction rate (compare to recent history)
    SELECT 
        xact_commit + xact_rollback as total_txns,
        blks_read + blks_hit as total_blocks
    FROM pg_stat_database 
    WHERE datname = current_database()
),
lock_stats AS (
    -- Lock contention
    SELECT COUNT(*) as waiting_locks
    FROM pg_locks WHERE NOT granted
)
SELECT 
    -- Compute score: 100 = completely idle, 0 = very busy
    GREATEST(0, LEAST(100,
        100 
        - (m.active_queries * 15)        -- -15 per active query
        - (m.idle_in_txn * 5)            -- -5 per idle-in-transaction
        - (l.waiting_locks * 10)         -- -10 per waiting lock
        - LEAST(50, COALESCE(m.longest_query_sec, 0)::int)  -- -1 per second of longest query (max -50)
    ))::INT as score,
    jsonb_build_object(
        'active_queries', m.active_queries,
        'idle_in_txn', m.idle_in_txn,
        'total_connections', m.total_connections,
        'waiting_locks', l.waiting_locks,
        'longest_query_sec', m.longest_query_sec
    ) as details
FROM metrics m, lock_stats l;
$$ LANGUAGE sql;
```

**Runtime Execution (Efficient):**

```rust
"wait_idle" => {
    let config: IdleConfig = serde_json::from_str(node.query.as_ref().unwrap())?;
    let threshold = config.idle_threshold_pct;
    let min_idle_secs = config.min_idle_seconds as u64;
    let max_wait_secs = config.max_wait_seconds as u64;
    
    // State tracked across timer wakeups
    let mut consecutive_idle_checks = 0u64;
    let mut current_interval = 10u64;  // Start with 10 second checks
    let mut total_waited = 0u64;
    
    loop {
        // Check timeout
        if total_waited >= max_wait_secs {
            ctx.trace_info("wait_for_idle: timeout reached");
            return Ok(r#"{"idle": false, "reason": "timeout"}"#.to_string());
        }
        
        // Single lightweight activity to get idle score
        let score_result = ctx
            .schedule_activity("GetIdleScore", "".to_string())
            .into_activity()
            .await?;
        
        let score: i32 = serde_json::from_str::<serde_json::Value>(&score_result)
            .ok()
            .and_then(|v| v["score"].as_i64())
            .unwrap_or(0) as i32;
        
        let is_idle = score >= (100 - threshold);
        
        if is_idle {
            consecutive_idle_checks += current_interval;
            
            // Check if we've been idle long enough
            if consecutive_idle_checks >= min_idle_secs {
                ctx.trace_info(format!("wait_for_idle: idle for {}s, proceeding", consecutive_idle_checks));
                return Ok(format!(r#"{{"idle": true, "idle_seconds": {}, "score": {}}}"#, 
                    consecutive_idle_checks, score));
            }
            
            // Trending idle: check more frequently
            current_interval = (current_interval / 2).max(5);
            ctx.trace_info(format!("wait_for_idle: idle (score={}), checking again in {}s", score, current_interval));
        } else {
            // Reset idle counter
            consecutive_idle_checks = 0;
            
            // Busy: exponential backoff (up to 60s)
            current_interval = (current_interval * 2).min(60);
            ctx.trace_info(format!("wait_for_idle: busy (score={}), backing off to {}s", score, current_interval));
        }
        
        // Durable timer - no activity overhead, just a timestamp
        ctx.schedule_timer(Duration::from_secs(current_interval))
            .into_timer()
            .await;
        
        total_waited += current_interval;
    }
}
```

**Register the lightweight activity:**

```rust
.register("GetIdleScore", move |ctx: ActivityContext, _: String| {
    let pool = idle_pool.clone();
    async move {
        // Single efficient query
        let result = sqlx::query_scalar::<_, i32>(
            "SELECT score FROM df.compute_idle_score()"
        )
        .fetch_one(pool.as_ref())
        .await
        .unwrap_or(0);
        
        Ok(format!(r#"{{"score": {}}}"#, result))
    }
})
```

**Why This Design is Efficient:**

| Aspect | Design Choice | Benefit |
|--------|--------------|---------|
| **Waiting** | Durable timers | Zero overhead while waiting |
| **Checking** | Single composite query | One round-trip per check |
| **Frequency** | Adaptive intervals | Fewer checks when busy |
| **State** | In orchestration | Survives crashes |
| **Scoring** | Composite metric | More accurate than single signal |

**Adaptive Interval Behavior:**

```
Time    Score   Interval   Notes
─────────────────────────────────────────────────
0s      20      10s       Initial check, busy
10s     15      20s       Still busy, back off
30s     25      40s       Still busy, back off more
70s     85      20s       Getting idle, check sooner
90s     90      10s       Trending idle, check more
100s    92      5s        Very idle, check frequently
105s    95      5s        Still idle (10s sustained)
110s    93      5s        Still idle (15s sustained)
...
135s    91      5s        Idle for 30s → PROCEED!
```

**Alternative: Shared Idle Monitor (Single Workflow for All Waiters)**

Instead of each `wait_for_idle()` polling independently, have one shared monitor workflow:

```sql
-- Single idle monitor workflow (started once at extension init)
SELECT df.start(
    @> (
        -- Compute idle score
        'SELECT * FROM df.compute_idle_score()' |=> 'status'
        
        -- Update shared state table
        ~> 'INSERT INTO df.idle_state (score, details, checked_at)
            VALUES (($status).score, ($status).details, now())
            ON CONFLICT (id) DO UPDATE SET 
                score = EXCLUDED.score,
                details = EXCLUDED.details,
                checked_at = EXCLUDED.checked_at'
        
        -- Adaptive sleep based on score
        ~> df.if(
            'SELECT ($status).score > 80',
            df.sleep(5),   -- Idle: check frequently to catch transitions
            df.sleep(15)   -- Busy: check less often
        )
    ),
    'idle-monitor-singleton'
);
```

Then `wait_for_idle()` just reads from the shared state (zero overhead):

```rust
"wait_idle" => {
    let config: IdleConfig = serde_json::from_str(node.query.as_ref().unwrap())?;
    let threshold = 100 - config.idle_threshold_pct;
    let min_idle_secs = config.min_idle_seconds as u64;
    let max_wait_secs = config.max_wait_seconds as u64;
    
    let mut idle_since: Option<u64> = None;
    let mut total_waited = 0u64;
    let check_interval = 5u64;  // Just read cached state, very cheap
    
    loop {
        if total_waited >= max_wait_secs {
            return Ok(r#"{"idle": false, "reason": "timeout"}"#.to_string());
        }
        
        // Read from cached state table (single row, indexed, instant)
        let score: i32 = ctx
            .schedule_activity("ExecuteSQL", 
                "SELECT score FROM df.idle_state WHERE id = 1".to_string())
            .into_activity()
            .await
            .and_then(|r| /* parse */)
            .unwrap_or(0);
        
        if score >= threshold {
            idle_since = idle_since.or(Some(total_waited));
            if total_waited - idle_since.unwrap() >= min_idle_secs {
                return Ok(format!(r#"{{"idle": true, "score": {}}}"#, score));
            }
        } else {
            idle_since = None;
        }
        
        // Durable timer - zero overhead
        ctx.schedule_timer(Duration::from_secs(check_interval)).into_timer().await;
        total_waited += check_interval;
    }
}
```

**Why this is better:**
- One workflow computes idle score for everyone
- N waiters just read a cached single-row table
- No pg_cron dependency
- Fully durable using existing pg_durable primitives

### 9. Real-time AI Triggers

React to database changes with AI processing.

```sql
-- Trigger function to queue AI processing
CREATE OR REPLACE FUNCTION trigger_ai_processing() RETURNS TRIGGER AS $$
BEGIN
    -- Queue for AI processing
    INSERT INTO ai_processing_queue (table_name, record_id, operation)
    VALUES (TG_TABLE_NAME, NEW.id, TG_OP);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to tables
CREATE TRIGGER ai_process_on_insert
    AFTER INSERT ON customer_feedback
    FOR EACH ROW EXECUTE FUNCTION trigger_ai_processing();

-- Durable processor for the queue
SELECT df.start(
    @> (
        -- Get next item from queue
        'DELETE FROM ai_processing_queue
         WHERE id = (
             SELECT id FROM ai_processing_queue
             ORDER BY created_at
             LIMIT 1
             FOR UPDATE SKIP LOCKED
         )
         RETURNING *' |=> 'item'

        ~> df.if(
            'SELECT $item IS NOT NULL',

            -- Process based on table
            df.if(
                'SELECT ($item).table_name = ''customer_feedback''',
                
                -- Get the feedback
                'SELECT content FROM customer_feedback WHERE id = ($item).record_id' |=> 'content'
                
                -- Analyze sentiment and extract issues
                ~> df.azure('ai-functions', 'analyze-feedback',
                    '{"text": "$content"}') |=> 'analysis'
                
                -- Update with analysis
                ~> 'UPDATE customer_feedback SET
                        sentiment = ($analysis::jsonb->>''sentiment''),
                        issues = ($analysis::jsonb->''issues''),
                        priority = ($analysis::jsonb->>''priority''),
                        analyzed_at = now()
                    WHERE id = ($item).record_id'
                
                -- Auto-create ticket for negative feedback
                ~> df.if(
                    'SELECT ($analysis::jsonb->>''sentiment'') = ''negative'' 
                        AND ($analysis::jsonb->>''priority'') = ''high''',
                    'INSERT INTO support_tickets (source_id, source_type, summary, priority)
                     VALUES (($item).record_id, ''feedback'', 
                             ($analysis::jsonb->>''summary''), ''high'')',
                    'SELECT ''no ticket needed'''
                ),
                
                -- Other table handlers...
                'SELECT ''unknown table'''
            ),

            -- Nothing in queue
            df.sleep(5)
        )
    ),
    'real-time-ai-processor'
);
```

---

## Configuration

### Secrets Table

**Superseded:** The table and provisioning examples below belong to the historical proposal. The FDW store holds per-role credentials, which are readable by the mapped role with server `USAGE`; it does not implement opaque admin-managed shared secrets. See the [security contract and open decisions](spec-security-model.md#44-endpoint-credentials).

```sql
CREATE TABLE df.secrets (
    name TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Store Azure Function keys
INSERT INTO df.secrets (name, value) VALUES
    ('ai-functions_key', 'your-function-key-here'),
    ('openai_api_key', 'sk-...');

-- Restrict access
REVOKE ALL ON df.secrets FROM PUBLIC;
```

### Azure Function Examples

**generate-embedding (Python)**
```python
import azure.functions as func
import openai
import json

def main(req: func.HttpRequest) -> func.HttpResponse:
    body = req.get_json()
    text = body.get('text')
    
    response = openai.Embedding.create(
        model="text-embedding-3-small",
        input=text
    )
    
    return func.HttpResponse(
        json.dumps({"embedding": response['data'][0]['embedding']}),
        mimetype="application/json"
    )
```

**chat-completion (Python)**
```python
import azure.functions as func
import openai
import json

def main(req: func.HttpRequest) -> func.HttpResponse:
    body = req.get_json()
    messages = body.get('messages', [])
    
    response = openai.ChatCompletion.create(
        model="gpt-4",
        messages=messages,
        max_tokens=1000
    )
    
    return func.HttpResponse(
        json.dumps({"content": response.choices[0].message.content}),
        mimetype="application/json"
    )
```

**batch-process (Python)**
```python
import azure.functions as func
import openai
import json
from concurrent.futures import ThreadPoolExecutor

def process_item(item, operations):
    result = {"id": item["id"]}
    
    if "embed" in operations:
        resp = openai.Embedding.create(model="text-embedding-3-small", input=item["content"])
        result["embedding"] = resp['data'][0]['embedding']
    
    if "classify" in operations:
        resp = openai.ChatCompletion.create(
            model="gpt-3.5-turbo",
            messages=[{"role": "user", "content": f"Classify: {item['content']}"}]
        )
        result["category"] = resp.choices[0].message.content
    
    return result

def main(req: func.HttpRequest) -> func.HttpResponse:
    body = req.get_json()
    items = body.get('items', [])
    operations = body.get('operations', ['embed'])
    
    with ThreadPoolExecutor(max_workers=10) as executor:
        results = list(executor.map(lambda i: process_item(i, operations), items))
    
    return func.HttpResponse(json.dumps(results), mimetype="application/json")
```

---

### 10. Knowledge Graph from Customer Transactions (AGE)

Build a rich knowledge graph from transactional data using Apache AGE extension + LLM-powered entity/relationship extraction.

**Source Schema (Relational):**

```sql
-- Existing relational tables
CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    name TEXT,
    email TEXT,
    signup_date DATE,
    notes TEXT  -- Unstructured: "VIP client, prefers eco-friendly products"
);

CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name TEXT,
    description TEXT,  -- Unstructured: LLM will extract features
    price DECIMAL,
    category_id INT    -- May be NULL or incorrect
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id INT REFERENCES customers(id),
    created_at TIMESTAMPTZ,
    total DECIMAL
);

CREATE TABLE order_items (
    order_id INT REFERENCES orders(id),
    product_id INT REFERENCES products(id),
    quantity INT,
    price DECIMAL
);

CREATE TABLE reviews (
    id SERIAL PRIMARY KEY,
    customer_id INT REFERENCES customers(id),
    product_id INT REFERENCES products(id),
    rating INT,
    review_text TEXT,  -- Unstructured: sentiment, topics
    created_at TIMESTAMPTZ
);
```

**Target Graph Schema (AGE):**

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Customer   │         │   Product    │         │   Category   │
│              │         │              │         │              │
│ id, name,    │         │ id, name,    │         │ name,        │
│ segment,     │────────►│ features[],  │────────►│ parent       │
│ lifetime_val │purchased│ price        │in_cat   │              │
└──────────────┘         └──────────────┘         └──────────────┘
       │                        │                        
       │reviewed                │similar_to              
       ▼                        ▼                        
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│    Review    │         │    Brand     │         │   Feature    │
│              │         │              │         │              │
│ sentiment,   │         │ name,        │         │ name (e.g.   │
│ topics[]     │         │ reputation   │         │ "wireless")  │
└──────────────┘         └──────────────┘         └──────────────┘
```

**Edge Types:**
- `(Customer)-[:PURCHASED {count, total, last_date}]->(Product)`
- `(Customer)-[:REVIEWED {sentiment, rating}]->(Product)`
- `(Customer)-[:IN_SEGMENT]->(Segment)`
- `(Product)-[:IN_CATEGORY]->(Category)`
- `(Product)-[:HAS_FEATURE]->(Feature)`
- `(Product)-[:MADE_BY]->(Brand)`
- `(Product)-[:SIMILAR_TO {score}]->(Product)`
- `(Product)-[:BOUGHT_TOGETHER {lift}]->(Product)`

**Setup AGE:**

```sql
CREATE EXTENSION age;
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

SELECT create_graph('customer_graph');
```

---

**Stage 1: Initial Graph Scaffold (One-time)**

Create nodes from structured data without LLM:

```sql
SELECT df.start(
    -- Create Customer nodes from relational data
    'SELECT * FROM cypher(''customer_graph'', $$
        UNWIND $customers AS c
        CREATE (n:Customer {
            id: c.id, 
            name: c.name, 
            email: c.email,
            signup_date: c.signup_date
        })
        RETURN count(n)
    $$, (SELECT jsonb_build_object(''customers'', 
        (SELECT jsonb_agg(row_to_json(c)) FROM customers c)
    ))) AS (count agtype)' |=> 'customer_count'
    
    -- Create Product nodes
    ~> 'SELECT * FROM cypher(''customer_graph'', $$
        UNWIND $products AS p
        CREATE (n:Product {
            id: p.id,
            name: p.name,
            price: p.price
        })
        RETURN count(n)
    $$, (SELECT jsonb_build_object(''products'',
        (SELECT jsonb_agg(row_to_json(p)) FROM products p)
    ))) AS (count agtype)' |=> 'product_count'
    
    -- Create PURCHASED edges from order history
    ~> 'SELECT * FROM cypher(''customer_graph'', $$
        UNWIND $purchases AS p
        MATCH (c:Customer {id: p.customer_id})
        MATCH (pr:Product {id: p.product_id})
        MERGE (c)-[r:PURCHASED]->(pr)
        ON CREATE SET r.count = p.qty, r.total = p.total, r.first_date = p.first_date
        ON MATCH SET r.count = r.count + p.qty, r.total = r.total + p.total
        SET r.last_date = p.last_date
        RETURN count(r)
    $$, (SELECT jsonb_build_object(''purchases'', (
        SELECT jsonb_agg(row_to_json(x)) FROM (
            SELECT 
                o.customer_id,
                oi.product_id,
                SUM(oi.quantity) as qty,
                SUM(oi.price * oi.quantity) as total,
                MIN(o.created_at) as first_date,
                MAX(o.created_at) as last_date
            FROM orders o
            JOIN order_items oi ON oi.order_id = o.id
            GROUP BY o.customer_id, oi.product_id
        ) x
    )))) AS (count agtype)' |=> 'purchase_edges',
    
    'graph-initial-scaffold'
);
```

---

**Stage 2: LLM-Powered Product Enrichment**

Extract features, categories, and brands from product descriptions:

```sql
-- Azure Function: extract-product-attributes
-- Input: {"products": [{"id": 1, "name": "...", "description": "..."}]}
-- Output: [{"id": 1, "features": ["wireless", "bluetooth"], "category": "Electronics > Audio", "brand": "Sony"}]

SELECT df.start(
    @> (
        df.wait_for_idle(idle_threshold_pct => 20, min_idle_seconds => 60)
        
        -- Get products without enrichment
        ~> 'SELECT json_agg(row_to_json(p)) FROM (
                SELECT id, name, description 
                FROM products 
                WHERE graph_enriched_at IS NULL
                LIMIT 50
            ) p' |=> 'batch'
        
        ~> df.if(
            'SELECT $batch IS NOT NULL AND json_array_length($batch::json) > 0',
            
            -- LLM extracts structured attributes from descriptions
            df.azure('ai-functions', 'extract-product-attributes', 
                '{"products": ' || $batch || '}') |=> 'enriched'
            
            -- Create Feature nodes and edges
            ~> 'SELECT * FROM cypher(''customer_graph'', $$
                UNWIND $items AS item
                MATCH (p:Product {id: item.id})
                UNWIND item.features AS feat_name
                MERGE (f:Feature {name: feat_name})
                MERGE (p)-[:HAS_FEATURE]->(f)
                RETURN count(*)
            $$, jsonb_build_object(''items'', $enriched::jsonb)) AS (c agtype)'
            
            -- Create/link Category nodes (handles hierarchy like "Electronics > Audio")
            ~> 'SELECT * FROM cypher(''customer_graph'', $$
                UNWIND $items AS item
                MATCH (p:Product {id: item.id})
                WITH p, split(item.category, '' > '') AS cats
                UNWIND range(0, size(cats)-1) AS idx
                MERGE (c:Category {name: cats[idx]})
                WITH p, c, idx, cats
                WHERE idx = size(cats) - 1
                MERGE (p)-[:IN_CATEGORY]->(c)
                RETURN count(*)
            $$, jsonb_build_object(''items'', $enriched::jsonb)) AS (c agtype)'
            
            -- Create/link Brand nodes
            ~> 'SELECT * FROM cypher(''customer_graph'', $$
                UNWIND $items AS item
                WHERE item.brand IS NOT NULL
                MATCH (p:Product {id: item.id})
                MERGE (b:Brand {name: item.brand})
                MERGE (p)-[:MADE_BY]->(b)
                RETURN count(*)
            $$, jsonb_build_object(''items'', $enriched::jsonb)) AS (c agtype)'
            
            -- Mark as processed
            ~> 'UPDATE products SET graph_enriched_at = now()
                WHERE id IN (SELECT (e->>''id'')::int FROM json_array_elements($enriched::json) e)',
            
            df.sleep(300)
        )
    ),
    'graph-product-enrichment'
);
```

---

**Stage 3: Customer Segmentation & Notes Extraction**

Use LLM to segment customers and extract insights from notes:

```sql
-- Azure Function: analyze-customer
-- Input: {"customer": {...}, "orders": [...], "reviews": [...]}
-- Output: {"segment": "high_value_eco", "interests": ["sustainable", "premium"], "insights": "..."}

SELECT df.start(
    @> (
        df.wait_for_idle(idle_threshold_pct => 15)
        
        -- Get customers needing analysis (with their order/review history)
        ~> 'SELECT json_agg(row_to_json(x)) FROM (
                SELECT 
                    c.*,
                    (SELECT json_agg(row_to_json(o)) 
                     FROM orders o WHERE o.customer_id = c.id) as orders,
                    (SELECT json_agg(row_to_json(r)) 
                     FROM reviews r WHERE r.customer_id = c.id) as reviews
                FROM customers c
                WHERE c.graph_segment_at IS NULL
                LIMIT 20
            ) x' |=> 'customers'
        
        ~> df.if(
            'SELECT json_array_length($customers::json) > 0',
            
            -- LLM analyzes each customer
            df.azure('ai-functions', 'analyze-customers',
                '{"customers": ' || $customers || '}') |=> 'analyzed'
            
            -- Create Segment nodes and link customers
            ~> 'SELECT * FROM cypher(''customer_graph'', $$
                UNWIND $items AS item
                MATCH (c:Customer {id: item.id})
                MERGE (s:Segment {name: item.segment})
                MERGE (c)-[:IN_SEGMENT]->(s)
                SET c.interests = item.interests
                SET c.lifetime_value_tier = item.value_tier
                RETURN count(*)
            $$, jsonb_build_object(''items'', $analyzed::jsonb)) AS (c agtype)'
            
            -- Create Interest nodes and edges
            ~> 'SELECT * FROM cypher(''customer_graph'', $$
                UNWIND $items AS item
                MATCH (c:Customer {id: item.id})
                UNWIND item.interests AS interest
                MERGE (i:Interest {name: interest})
                MERGE (c)-[:INTERESTED_IN]->(i)
                RETURN count(*)
            $$, jsonb_build_object(''items'', $analyzed::jsonb)) AS (c agtype)'
            
            ~> 'UPDATE customers SET graph_segment_at = now()
                WHERE id IN (SELECT (a->>''id'')::int FROM json_array_elements($analyzed::json) a)',
            
            df.sleep(300)
        )
    ),
    'graph-customer-segmentation'
);
```

---

**Stage 4: Review Sentiment & Topic Extraction**

Extract sentiment and topics from reviews, create edges:

```sql
SELECT df.start(
    @> (
        df.wait_for_schedule('*/10 * * * *')  -- Every 10 minutes
        
        ~> 'SELECT json_agg(row_to_json(r)) FROM (
                SELECT id, customer_id, product_id, rating, review_text
                FROM reviews
                WHERE sentiment IS NULL
                LIMIT 100
            ) r' |=> 'reviews'
        
        ~> df.if(
            'SELECT json_array_length($reviews::json) > 0',
            
            df.azure('ai-functions', 'analyze-reviews',
                '{"reviews": ' || $reviews || '}') |=> 'analyzed'
            
            -- Update relational table
            ~> 'UPDATE reviews r SET
                    sentiment = (a->>''sentiment''),
                    topics = (a->''topics'')::jsonb,
                    sentiment_score = (a->>''score'')::float
                FROM json_array_elements($analyzed::json) a
                WHERE r.id = (a->>''id'')::int'
            
            -- Create Review nodes and edges in graph
            ~> 'SELECT * FROM cypher(''customer_graph'', $$
                UNWIND $items AS item
                MATCH (c:Customer {id: item.customer_id})
                MATCH (p:Product {id: item.product_id})
                CREATE (c)-[:REVIEWED {
                    sentiment: item.sentiment,
                    score: item.score,
                    rating: item.rating,
                    topics: item.topics
                }]->(p)
                RETURN count(*)
            $$, jsonb_build_object(''items'', $analyzed::jsonb)) AS (c agtype)'
            
            -- Link products to topics mentioned in reviews
            ~> 'SELECT * FROM cypher(''customer_graph'', $$
                UNWIND $items AS item
                MATCH (p:Product {id: item.product_id})
                UNWIND item.topics AS topic
                MERGE (t:Topic {name: topic})
                MERGE (p)-[:DISCUSSED_IN {sentiment: item.sentiment}]->(t)
                RETURN count(*)
            $$, jsonb_build_object(''items'', $analyzed::jsonb)) AS (c agtype)',
            
            'SELECT ''no reviews'''
        )
    ),
    'graph-review-analysis'
);
```

---

**Stage 5: Product Similarity (Embeddings + Graph)**

Find similar products using embeddings and create SIMILAR_TO edges:

```sql
SELECT df.start(
    @> (
        df.wait_for_idle(idle_threshold_pct => 10, min_idle_seconds => 120)
        
        -- Get products needing similarity calculation
        ~> 'SELECT json_agg(row_to_json(p)) FROM (
                SELECT id, name, description
                FROM products
                WHERE embedding IS NULL
                LIMIT 100
            ) p' |=> 'products'
        
        ~> df.if(
            'SELECT json_array_length($products::json) > 0',
            
            -- Generate embeddings
            df.azure('ai-functions', 'batch-embeddings',
                '{"items": ' || $products || ', "field": "description"}') |=> 'with_embeddings'
            
            -- Store embeddings
            ~> 'UPDATE products p SET
                    embedding = (e->>''embedding'')::vector
                FROM json_array_elements($with_embeddings::json) e
                WHERE p.id = (e->>''id'')::int'
            
            -- Find similar products and create edges
            ~> 'WITH similar_pairs AS (
                    SELECT 
                        p1.id as product1_id,
                        p2.id as product2_id,
                        1 - (p1.embedding <=> p2.embedding) as similarity
                    FROM products p1
                    CROSS JOIN LATERAL (
                        SELECT id, embedding
                        FROM products p2
                        WHERE p2.id != p1.id
                        ORDER BY p1.embedding <=> p2.embedding
                        LIMIT 5
                    ) p2
                    WHERE 1 - (p1.embedding <=> p2.embedding) > 0.7
                )
                SELECT * FROM cypher(''customer_graph'', $$
                    UNWIND $pairs AS pair
                    MATCH (p1:Product {id: pair.product1_id})
                    MATCH (p2:Product {id: pair.product2_id})
                    MERGE (p1)-[r:SIMILAR_TO]->(p2)
                    SET r.score = pair.similarity
                    RETURN count(*)
                $$, jsonb_build_object(''pairs'', 
                    (SELECT jsonb_agg(row_to_json(s)) FROM similar_pairs s)
                )) AS (c agtype)',
            
            df.sleep(600)
        )
    ),
    'graph-product-similarity'
);
```

---

**Stage 6: "Frequently Bought Together" from Graph Analysis**

Use graph patterns + LLM to find and validate product associations:

```sql
SELECT df.start(
    @> (
        df.wait_for_schedule('0 2 * * *')  -- Daily at 2 AM
        
        -- Find co-purchase patterns from graph
        ~> 'SELECT * FROM cypher(''customer_graph'', $$
            MATCH (c:Customer)-[:PURCHASED]->(p1:Product)
            MATCH (c)-[:PURCHASED]->(p2:Product)
            WHERE id(p1) < id(p2)
            WITH p1, p2, count(DISTINCT c) AS co_purchases
            WHERE co_purchases >= 3
            RETURN p1.id AS prod1, p2.id AS prod2, co_purchases
            ORDER BY co_purchases DESC
            LIMIT 100
        $$) AS (prod1 agtype, prod2 agtype, co_purchases agtype)' |=> 'co_purchases'
        
        -- LLM validates if the association makes sense
        ~> df.azure('ai-functions', 'validate-associations',
            '{
                "associations": ' || $co_purchases || ',
                "products": (SELECT json_agg(row_to_json(p)) FROM products p 
                             WHERE id IN (SELECT prod1 FROM ...) OR id IN (SELECT prod2 FROM ...))
            }') |=> 'validated'
        
        -- Create BOUGHT_TOGETHER edges for validated associations
        ~> 'SELECT * FROM cypher(''customer_graph'', $$
            UNWIND $assocs AS a
            WHERE a.valid = true
            MATCH (p1:Product {id: a.prod1})
            MATCH (p2:Product {id: a.prod2})
            MERGE (p1)-[r:BOUGHT_TOGETHER]->(p2)
            SET r.count = a.co_purchases
            SET r.lift = a.lift
            SET r.reason = a.reason
            RETURN count(*)
        $$, jsonb_build_object(''assocs'', $validated::jsonb)) AS (c agtype)',
        
        'graph-association-mining'
    ),
    'daily-association-mining'
);
```

---

**Stage 7: Real-Time Graph Updates (New Orders)**

When new orders come in, update the graph incrementally:

```sql
-- Trigger on new orders
CREATE OR REPLACE FUNCTION on_new_order() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO df.graph_update_queue (order_id, created_at)
    VALUES (NEW.id, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER order_graph_update
    AFTER INSERT ON orders
    FOR EACH ROW EXECUTE FUNCTION on_new_order();

-- Durable processor for graph updates
SELECT df.start(
    @> (
        df.sleep(5)  -- Check every 5 seconds
        
        ~> 'DELETE FROM df.graph_update_queue
            WHERE id = (SELECT id FROM df.graph_update_queue ORDER BY created_at LIMIT 1)
            RETURNING order_id' |=> 'order_id'
        
        ~> df.if(
            'SELECT $order_id IS NOT NULL',
            
            -- Get order details
            'SELECT json_build_object(
                ''order'', row_to_json(o),
                ''items'', (SELECT json_agg(row_to_json(i)) FROM order_items i WHERE i.order_id = o.id)
            ) FROM orders o WHERE o.id = $order_id' |=> 'order_data'
            
            -- Update PURCHASED edges
            ~> 'SELECT * FROM cypher(''customer_graph'', $$
                WITH $data AS data
                MATCH (c:Customer {id: data.order.customer_id})
                UNWIND data.items AS item
                MATCH (p:Product {id: item.product_id})
                MERGE (c)-[r:PURCHASED]->(p)
                ON CREATE SET r.count = item.quantity, r.total = item.price, r.first_date = data.order.created_at
                ON MATCH SET r.count = r.count + item.quantity, r.total = r.total + item.price
                SET r.last_date = data.order.created_at
                RETURN count(*)
            $$, jsonb_build_object(''data'', $order_data::jsonb)) AS (c agtype)',
            
            'SELECT ''queue empty'''
        )
    ),
    'graph-realtime-order-updates'
);
```

---

**Example Graph Queries:**

```sql
-- Product recommendations for a customer
SELECT * FROM cypher('customer_graph', $$
    MATCH (c:Customer {id: 123})-[:PURCHASED]->(bought:Product)
    MATCH (bought)-[:SIMILAR_TO]->(recommended:Product)
    WHERE NOT (c)-[:PURCHASED]->(recommended)
    RETURN DISTINCT recommended.name, recommended.id, count(*) AS score
    ORDER BY score DESC
    LIMIT 10
$$) AS (name agtype, id agtype, score agtype);

-- "Customers who bought X also bought Y"
SELECT * FROM cypher('customer_graph', $$
    MATCH (p:Product {id: 456})<-[:PURCHASED]-(c:Customer)-[:PURCHASED]->(other:Product)
    WHERE p <> other
    RETURN other.name, count(DISTINCT c) AS buyers
    ORDER BY buyers DESC
    LIMIT 5
$$) AS (name agtype, buyers agtype);

-- Customer 360 view
SELECT * FROM cypher('customer_graph', $$
    MATCH (c:Customer {id: 123})
    OPTIONAL MATCH (c)-[:IN_SEGMENT]->(s:Segment)
    OPTIONAL MATCH (c)-[:INTERESTED_IN]->(i:Interest)
    OPTIONAL MATCH (c)-[p:PURCHASED]->(prod:Product)
    OPTIONAL MATCH (c)-[r:REVIEWED]->(reviewed:Product)
    RETURN c, s, collect(DISTINCT i) AS interests, 
           collect(DISTINCT {product: prod, count: p.count}) AS purchases,
           collect(DISTINCT {product: reviewed, sentiment: r.sentiment}) AS reviews
$$) AS (customer agtype, segment agtype, interests agtype, purchases agtype, reviews agtype);

-- Find influence paths (how did customer discover products)
SELECT * FROM cypher('customer_graph', $$
    MATCH path = (c:Customer {id: 123})-[:IN_SEGMENT]->(:Segment)<-[:IN_SEGMENT]-(similar:Customer)
                 -[:PURCHASED]->(p:Product)
    WHERE NOT (c)-[:PURCHASED]->(p)
    RETURN p.name, count(DISTINCT similar) AS segment_buyers
    ORDER BY segment_buyers DESC
    LIMIT 10
$$) AS (product agtype, segment_buyers agtype);
```

---

**Architecture Summary:**

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        pg_durable Workflows                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
│  │  Initial    │  │  Product    │  │  Customer   │  │  Review     │    │
│  │  Scaffold   │  │  Enrichment │  │  Segment    │  │  Analysis   │    │
│  │  (one-time) │  │  (idle)     │  │  (idle)     │  │  (schedule) │    │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘    │
│         │                │                │                │           │
│         └────────────────┴────────────────┴────────────────┘           │
│                                    │                                    │
│                                    ▼                                    │
│  ┌─────────────┐  ┌─────────────────────────────────┐  ┌─────────────┐ │
│  │  Similarity │  │        Azure Functions          │  │  Real-time  │ │
│  │  Mining     │  │  - extract-product-attributes   │  │  Order      │ │
│  │  (idle)     │  │  - analyze-customers            │  │  Updates    │ │
│  │             │  │  - analyze-reviews              │  │  (trigger)  │ │
│  └──────┬──────┘  │  - batch-embeddings             │  └──────┬──────┘ │
│         │         │  - validate-associations        │         │        │
│         │         └─────────────────────────────────┘         │        │
│         │                        │                            │        │
│         └────────────────────────┴────────────────────────────┘        │
│                                  │                                      │
│                                  ▼                                      │
│                    ┌───────────────────────────┐                       │
│                    │     Apache AGE Graph      │                       │
│                    │     (customer_graph)      │                       │
│                    │                           │                       │
│                    │  Nodes: Customer, Product,│                       │
│                    │  Category, Brand, Feature,│                       │
│                    │  Segment, Interest, Topic │                       │
│                    │                           │                       │
│                    │  Edges: PURCHASED,        │                       │
│                    │  SIMILAR_TO, IN_CATEGORY, │                       │
│                    │  REVIEWED, BOUGHT_TOGETHER│                       │
│                    └───────────────────────────┘                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Summary

| Scenario | Key pg_durable Patterns | Azure Functions |
|----------|------------------------|-----------------|
| **RAG Pipeline** | `~>` sequence, `|=>` variables | embed, chat-completion |
| **Document Processing** | `~>` sequence, batch SQL | parse-document, chunk-text, batch-embeddings |
| **Semantic Search** | `df.http()`, vector SQL | generate-embedding, rerank |
| **Content Enrichment** | `df.join3()` parallel | extract-entities, classify, summarize |
| **Intelligent ETL** | `~>` sequence, `df.if()` | normalize, classify, detect-anomalies |
| **Agentic Workflows** | `df.loop()`, `df.if()` | agent-reason, agent-tool-* |
| **Batch Processing** | `@>` loop, `df.join3()` | batch-process |
| **Idle-Time Enrichment** | `df.wait_for_idle()`, `@>` | batch-embeddings, extract-metadata |
| **Real-time Triggers** | `@>` loop, triggers | analyze-feedback |
| **Knowledge Graph (AGE)** | `@>` idle loops, triggers, Cypher | extract-attributes, analyze-customers, embeddings |
