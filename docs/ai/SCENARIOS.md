# AI Scenarios for pg_durable

**4 Production-Ready Patterns for AI/ML Workloads**

This guide provides detailed, copy-paste ready code samples for common AI orchestration patterns using pg_durable.

> 📖 **Prerequisites:** See [Getting Started](../SCENARIOS.md#scenario-1-getting-started) if you're new to pg_durable.

### Key Syntax Patterns

When working with pg_durable variables, follow these patterns for reliable execution:

| Pattern | Example | Use When |
|---------|---------|----------|
| **Parentheses around `\|=>`** | `('SELECT id FROM t' \|=> 'row_id')` | Always wrap variable capture |
| **Single-column selection** | `SELECT id FROM ...` then `$row_id::int` | Prefer over multi-column JSON |
| **Subqueries for data** | `(SELECT col FROM t WHERE id = $row_id::int)` | Fetching related data |
| **DB checks in conditionals** | `'SELECT score >= 0.9 FROM t WHERE id = $id::int'` | Conditions inside `df.if()` |
| **jsonb_build_object()** | `jsonb_build_object('key', $var)` | Wrapping variables in JSON |

**⚠️ Important:** Avoid `$var::jsonb` casts on pg_durable variables. Variable results are stored internally with wrapper JSON. Instead:
- Use `jsonb_build_object('key', $var)` to build JSON objects
- Store values first, then read from database for complex JSON operations
- Use subqueries: `(SELECT col FROM t WHERE id = $var::int)` to fetch data

**Why?** Multi-column results require JSON parsing (`$var::jsonb->>'field'`), which can fail if the result isn't properly formatted. Single-column results with subqueries are more reliable.

---

## Table of Contents

- [Scenario 1: Data Ingestion — Chunking & Embedding](#scenario-1-data-ingestion--chunking--embedding)
- [Scenario 2: Query Processing — Pre/Post LLM Orchestration](#scenario-2-query-processing--prepost-llm-orchestration)
- [Scenario 3: Evaluation Loop with Human Review](#scenario-3-evaluation-loop-with-human-review)
- [Scenario 4: AI Output Governance — Versioned & Governed Results](#scenario-4-ai-output-governance--versioned--governed-results)

---

## Scenario 1: Data Ingestion — Chunking & Embedding

### Use This Pattern When...

> *"I'm building a RAG system and need fault-tolerant document ingestion. I want to chunk text, generate embeddings via API, and store vectors with metadata."*

**Business examples:**
- Document ingestion for semantic search
- Fetching files from Azure Blob Storage / S3 / GCS for processing
- Knowledge base population for chatbots
- Processing uploaded PDFs/documents for AI retrieval
- Building vector indexes from unstructured data

### The Problem

Traditional document ingestion fails silently:
- Embedding API calls timeout or rate-limit
- Partial ingestion leaves corrupted indexes
- No visibility into what succeeded vs failed
- Restarts mean re-processing everything

### The Solution

```sql
-- ============================================================================
-- Setup: Tables for document processing
-- ============================================================================

CREATE TABLE IF NOT EXISTS documents (
    id SERIAL PRIMARY KEY,
    content TEXT,
    status TEXT DEFAULT 'pending',
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    processed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS document_chunks (
    id SERIAL PRIMARY KEY,
    document_id INT REFERENCES documents(id),
    chunk_index INT,
    chunk_text TEXT,
    embedding JSONB,  -- In production: use pgvector's VECTOR type
    token_count INT,
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Insert sample documents
INSERT INTO documents (content) VALUES 
    ('pg_durable brings durable execution to PostgreSQL. It enables fault-tolerant SQL functions that survive crashes and restarts. The extension uses a background worker for reliable execution.'),
    ('Vector embeddings transform text into numerical representations. These vectors capture semantic meaning and enable similarity search across large document collections.');

-- ============================================================================
-- Document Ingestion Pipeline
-- ============================================================================

SELECT df.start(
    -- Step 1: Get next pending document ID
    -- Note: Use parentheses around |=> expressions for correct operator binding
    ('SELECT id FROM documents WHERE status = ''pending'' LIMIT 1' |=> 'doc_id')
    
    -- Step 2: Mark as processing (prevents duplicate processing)
    ~> 'UPDATE documents SET status = ''processing'' 
        WHERE id = $doc_id::int'
    
    -- Step 3: Chunk the document
    -- Use subquery to fetch content, return chunk ID for next step
    ~> ('INSERT INTO document_chunks (document_id, chunk_index, chunk_text, token_count, metadata)
        SELECT 
            $doc_id::int,
            1,
            content,
            array_length(string_to_array(content, '' ''), 1),
            jsonb_build_object(
                ''char_count'', length(content),
                ''source'', ''direct_insert''
            )
        FROM documents WHERE id = $doc_id::int
        RETURNING id' |=> 'chunk_id')
    
    -- Step 4: Generate embedding using Azure AI extension
    -- Requires: CREATE EXTENSION azure_ai;
    ~> 'UPDATE document_chunks 
        SET embedding = azure_openai.create_embeddings(
            ''text-embedding-3-small'',
            (SELECT chunk_text FROM document_chunks WHERE id = $chunk_id::int)
        )::vector
        WHERE id = $chunk_id::int'
    
    -- Step 5: Mark document complete
    ~> 'UPDATE documents 
        SET status = ''completed'', processed_at = now()
        WHERE id = $doc_id::int',
    
    'ai-document-ingestion'
);
```

### How It Works

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Get Pending │───►│ Mark        │───►│ Create      │───►│ Call        │
│ Document    │    │ Processing  │    │ Chunks      │    │ Embedding   │
└─────────────┘    └─────────────┘    └─────────────┘    │ API         │
                                                          └──────┬──────┘
                                                                 │
┌─────────────┐    ┌─────────────┐                               │
│ Mark        │◄───│ Store       │◄──────────────────────────────┘
│ Complete    │    │ Embedding   │
└─────────────┘    └─────────────┘
```

1. **Sequential pipeline** (`~>`) ensures each step completes before the next
2. **Variable capture** (`|=>`) passes document ID through all steps
3. **HTTP integration** (`df.http()`) calls external embedding service
4. **Fault tolerance**: API failure triggers retry, state is preserved
5. **Audit trail**: Every step logged in `df.nodes` table

### Production: Using pgvector

```sql
-- Install required extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS azure_ai;

-- Configure Azure OpenAI endpoint (one-time setup)
SELECT azure_ai.set_setting('azure_openai.endpoint', 'https://YOUR_RESOURCE.openai.azure.com');
SELECT azure_ai.set_setting('azure_openai.subscription_key', 'YOUR_API_KEY');

-- Create table with vector column
CREATE TABLE document_chunks_prod (
    id SERIAL PRIMARY KEY,
    document_id INT,
    chunk_text TEXT,
    embedding VECTOR(1536),  -- text-embedding-3-small dimension
    metadata JSONB
);

-- Generate embeddings using Azure AI extension (much simpler than HTTP!)
~> 'UPDATE document_chunks_prod 
    SET embedding = azure_openai.create_embeddings(
        ''text-embedding-3-small'',  -- deployment name in Azure OpenAI
        chunk_text
    )::vector
    WHERE id = $chunk_id'
```

### Why Azure AI Extension?

| Approach | Pros | Cons |
|----------|------|------|
| **Azure AI Extension** | Native SQL, no HTTP overhead, automatic retries, simpler syntax | Requires extension setup |
| **HTTP API** | Works anywhere, no extension needed | More complex, manual error handling |

### Batch Processing Multiple Documents

```sql
-- Process all pending documents in a loop
SELECT df.start(
    df.loop(
        -- Get and process one document (use parentheses for |=>)
        ('SELECT id FROM documents WHERE status = ''pending'' LIMIT 1' |=> 'doc_id')
        
        ~> (
            -- Check if we got a document (doc_id is a single value, not JSON)
            'SELECT $doc_id IS NOT NULL'
            ?> (
                -- Document exists: process it
                'UPDATE documents SET status = ''processing'' WHERE id = $doc_id::int'
                ~> df.http('https://api.example.com/embed', 'POST', '{"text": "..."}')
                ~> 'UPDATE documents SET status = ''completed'' WHERE id = $doc_id::int'
            )
            !> (
                -- No more documents: exit loop
                df.break('{"reason": "no_pending_documents"}')
            )
        )
        
        -- Rate limit: wait 1 second between documents
        ~> df.sleep(1),
        
        -- Continue while there might be documents
        'SELECT EXISTS(SELECT 1 FROM documents WHERE status = ''pending'')'
    ),
    'batch-document-ingestion'
);
```

### Ingesting from Azure Blob Storage

A common enterprise pattern is pulling documents from cloud storage (Azure Blob, S3, GCS) before processing. This pipeline fetches a document from Azure Blob Storage using a SAS URL, saves it to the database, then processes it.

```sql
-- ============================================================================
-- Setup: Tables for blob-sourced documents
-- ============================================================================

CREATE TABLE IF NOT EXISTS blob_documents (
    id SERIAL PRIMARY KEY,
    blob_url TEXT NOT NULL,           -- Azure Blob SAS URL
    blob_name TEXT,                   -- Original filename
    content TEXT,                     -- Fetched content
    content_type TEXT,                -- MIME type
    fetch_status TEXT DEFAULT 'pending',
    process_status TEXT DEFAULT 'pending',
    error_message TEXT,
    fetched_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Queue a blob for processing (SAS URL with read permissions)
INSERT INTO blob_documents (blob_url, blob_name) VALUES 
    ('https://myaccount.blob.core.windows.net/documents/report.txt?sp=r&st=2024-01-01...', 'report.txt'),
    ('https://myaccount.blob.core.windows.net/documents/manual.txt?sp=r&st=2024-01-01...', 'manual.txt');

-- ============================================================================
-- Blob Storage → Documents Pipeline
-- ============================================================================

SELECT df.start(
    -- Step 1: Get next pending blob ID
    ('SELECT id FROM blob_documents 
     WHERE fetch_status = ''pending'' LIMIT 1' |=> 'blob_id')
    
    -- Step 2: Mark as fetching
    ~> 'UPDATE blob_documents SET fetch_status = ''fetching'' 
        WHERE id = $blob_id::int'
    
    -- Step 3: Fetch content from Azure Blob Storage
    ~> (df.http(
        (SELECT blob_url FROM blob_documents WHERE id = $blob_id::int),
        'GET',
        NULL,
        '{"Accept": "text/plain, application/json, */*"}'::jsonb
    ) |=> 'blob_response')
    
    -- Step 4: Check if fetch succeeded and store content
    ~> (
        'SELECT ($blob_response::jsonb->>''ok'')::boolean'
        ?> (
            -- Success: store the content
            'UPDATE blob_documents 
             SET content = $blob_response::jsonb->>''body'',
                 content_type = $blob_response::jsonb->''headers''->>''content-type'',
                 fetch_status = ''fetched'',
                 fetched_at = now()
             WHERE id = $blob_id::int'
        )
        !> (
            -- Failed: record error
            'UPDATE blob_documents 
             SET fetch_status = ''failed'',
                 error_message = ''HTTP '' || ($blob_response::jsonb->>''status'') || '': '' || ($blob_response::jsonb->>''body'')
             WHERE id = $blob_id::int'
            ~> df.break('{"error": "blob_fetch_failed"}')
        )
    )
    
    -- Step 5: Now process the fetched content (chunk + embed)
    ~> 'UPDATE blob_documents SET process_status = ''processing'' 
        WHERE id = $blob_id::int'
    
    ~> ('INSERT INTO document_chunks (document_id, chunk_index, chunk_text, metadata)
        SELECT 
            $blob_id::int,
            1,
            content,
            jsonb_build_object(
                ''source'', ''azure_blob'',
                ''blob_name'', blob_name,
                ''fetched_at'', fetched_at
            )
        FROM blob_documents 
        WHERE id = $blob_id::int
        RETURNING id' |=> 'chunk_id')
    
    -- Step 6: Generate embedding using Azure AI extension
    ~> 'UPDATE document_chunks 
        SET embedding = azure_openai.create_embeddings(
            ''text-embedding-3-small'',
            (SELECT chunk_text FROM document_chunks WHERE id = $chunk_id::int)
        )::vector
        WHERE id = $chunk_id::int'
    
    -- Step 7: Mark complete
    ~> 'UPDATE blob_documents SET process_status = ''completed'', processed_at = now()
        WHERE id = $blob_id::int',
    
    'blob-to-embeddings'
);
```

### How the Blob Pipeline Works

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Get Pending │───►│ Fetch from  │───►│ Store       │───►│ Create      │
│ Blob URL    │    │ Azure Blob  │    │ Content     │    │ Chunks      │
└─────────────┘    └─────────────┘    └─────────────┘    └──────┬──────┘
                         │                                       │
                         │ (on failure)                          │
                         ▼                                       ▼
                   ┌─────────────┐                         ┌─────────────┐
                   │ Record      │                         │ Generate    │
                   │ Error       │                         │ Embeddings  │
                   └─────────────┘                         └──────┬──────┘
                                                                  │
                                                                  ▼
                                                           ┌─────────────┐
                                                           │ Mark        │
                                                           │ Complete    │
                                                           └─────────────┘
```

**Key features:**
1. **HTTP fetch** from Azure Blob using SAS URL
2. **Error handling** with conditional branching (`?>` / `!>`)
3. **Metadata preservation** (blob name, fetch time, source)
4. **Fault tolerance**: if embedding fails, retry picks up from last checkpoint

### Processing Multiple Blobs with Scheduling

```sql
-- Scheduled blob processor: check for new blobs every 5 minutes
SELECT df.start(
    @> (
        -- Process all pending blobs in this iteration
        df.loop(
            ('SELECT id FROM blob_documents WHERE fetch_status = ''pending'' LIMIT 1' |=> 'blob_id')
            ~> (
                'SELECT $blob_id IS NOT NULL'
                ?> (
                    -- Process this blob (simplified - full pipeline above)
                    df.http(
                        (SELECT blob_url FROM blob_documents WHERE id = $blob_id::int),
                        'GET'
                    )
                    ~> 'UPDATE blob_documents SET fetch_status = ''fetched'' WHERE id = $blob_id::int'
                )
                !> df.break('{"done": "no_more_pending"}')
            ),
            'SELECT EXISTS(SELECT 1 FROM blob_documents WHERE fetch_status = ''pending'')'
        )
        
        -- Wait for next check
        ~> df.wait_for_schedule('*/5 * * * *')
    ),
    'scheduled-blob-processor'
);
```

### Verify It Worked

```sql
-- Check pipeline status
SELECT status, started_at, completed_at 
FROM df.instances 
WHERE label IN ('ai-document-ingestion', 'blob-to-embeddings');

-- View processed documents
SELECT id, status, processed_at FROM documents;

-- View blob documents (if using blob storage pattern)
SELECT id, blob_name, fetch_status, process_status, fetched_at, processed_at 
FROM blob_documents;

-- View chunks with embeddings
SELECT 
    document_id, 
    chunk_index, 
    LEFT(chunk_text, 50) as preview,
    embedding IS NOT NULL as has_embedding,
    token_count,
    metadata->>'source' as source
FROM document_chunks;

-- View execution timeline
SELECT node_label, status, started_at, completed_at 
FROM df.nodes 
WHERE instance_id = (
    SELECT instance_id FROM df.instances WHERE label = 'ai-document-ingestion'
)
ORDER BY started_at;
```

---

## Scenario 2: Query Processing — Pre/Post LLM Orchestration

### Use This Pattern When...

> *"I need to validate input, route queries to different models, call an LLM, then extract and score the response. Complex AI queries need orchestration around the model call."*

**Business examples:**
- RAG pipeline: retrieve context → call LLM → extract citations
- Safety filtering: check input → call model → filter output
- Multi-model routing: classify query → route to specialist model
- Response scoring: generate → evaluate → refine if needed

### The Problem

AI queries aren't just "call the model":
- Input needs validation and safety checks
- Different queries need different models (cost/quality tradeoff)
- Responses need post-processing (extraction, scoring, formatting)
- Failures at any stage need proper handling

### The Solution

```sql
-- ============================================================================
-- Setup: Tables for query processing
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_queries (
    id SERIAL PRIMARY KEY,
    user_query TEXT NOT NULL,
    query_type TEXT,          -- 'simple', 'complex', 'unsafe'
    routed_model TEXT,        -- which model handled it
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ai_responses (
    id SERIAL PRIMARY KEY,
    query_id INT REFERENCES ai_queries(id),
    raw_response JSONB,
    extracted_answer TEXT,
    citations JSONB,
    confidence_score NUMERIC(3,2),
    processing_time_ms INT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Insert test queries
INSERT INTO ai_queries (user_query) VALUES 
    ('What is pg_durable?'),
    ('Explain the distributed consensus algorithm used in pg_durable and compare it to Raft and Paxos with examples');

-- ============================================================================
-- AI Query Processing Pipeline
-- ============================================================================

SELECT df.start(
    -- Step 1: Get pending query ID
    ('SELECT id FROM ai_queries WHERE status = ''pending'' LIMIT 1' |=> 'query_id')
    
    -- Step 2: Pre-processing - Classify query complexity
    -- Store classification in DB so it's accessible in conditional branches
    ~> 'UPDATE ai_queries 
        SET query_type = CASE 
            WHEN length(user_query) < 50 THEN ''simple''
            WHEN length(user_query) > 200 THEN ''complex''
            ELSE ''moderate''
        END,
        status = ''classifying''
        WHERE id = $query_id::int'
    
    -- Step 3: Route to appropriate model based on complexity
    ~> 'UPDATE ai_queries SET status = ''routing'' WHERE id = $query_id::int'
    
    ~> (
        -- Check if simple query (read from DB, not variable)
        'SELECT query_type = ''simple'' FROM ai_queries WHERE id = $query_id::int' 
        ?> (
            -- Simple query: fast, cheap model (gpt-5-mini)
            'UPDATE ai_queries SET routed_model = ''gpt-5-mini'' 
             WHERE id = $query_id::int'
            ~> ('SELECT azure_ai.generate(
                    (SELECT user_query FROM ai_queries WHERE id = $query_id::int),
                    ''gpt-5-mini''
                ) as response' |=> 'llm_response')
        )
        !> (
            -- Complex query: advanced model (gpt-5.2-codex)
            'UPDATE ai_queries SET routed_model = ''gpt-5.2-codex'' 
             WHERE id = $query_id::int'
            ~> ('SELECT azure_ai.generate(
                    (SELECT user_query FROM ai_queries WHERE id = $query_id::int),
                    ''gpt-5.2-codex''
                ) as response' |=> 'llm_response')
        )
    )
    
    -- Step 4: Post-processing - Store response
    -- IMPORTANT: Use jsonb_build_object() to wrap variables, NOT $var::jsonb casts
    ~> 'UPDATE ai_queries SET status = ''processing'' WHERE id = $query_id::int'
    
    ~> ('INSERT INTO ai_responses (query_id, raw_response, processing_time_ms)
        VALUES (
            $query_id::int, 
            jsonb_build_object(''response'', $llm_response),
            150
        )
        RETURNING id' |=> 'response_id')
    
    -- Step 5: Extract answer from stored response
    ~> 'UPDATE ai_responses 
        SET extracted_answer = (raw_response->>''response'')::text
        WHERE id = $response_id::int'
    
    -- Step 6: Generate confidence score using azure_ai.is_true
    -- Ask the AI: "How confident are you with this answer?"
    -- Uses azure_ai.is_true() to evaluate answer quality and return a confidence score
    ~> 'UPDATE ai_responses 
        SET confidence_score = CASE 
            WHEN azure_ai.is_true(
                ''How confident are you with this answer? Is this response accurate and complete? '' || 
                (SELECT extracted_answer FROM ai_responses WHERE id = $response_id::int)
            ) THEN 0.95
            ELSE 0.70
        END
        WHERE id = $response_id::int'
    
    -- Step 7: Mark complete
    ~> 'UPDATE ai_queries SET status = ''completed'' 
        WHERE id = $query_id::int',
        
        'ai-query-processing'
);
```

> **Note**: pg_durable wraps variable results in `{"rows": [...], "row_count": N}` format.
> Avoid using `$var::jsonb` casts as they may fail. Instead:
> - Use `jsonb_build_object('key', $var)` to wrap values when inserting
> - Read from stored database values for complex JSON operations
> - For azure_ai.extract(), call it in a separate step after storing the raw response

### How It Works

```
                                    ┌───────────────────────┐
                              ┌────►│ gpt-5-mini (fast)     │────┐
┌─────────┐    ┌───────────┐  │     └───────────────────────┘    │     ┌───────────┐    ┌──────────┐    ┌──────────┐
│ Get     │───►│ Classify  │──┤                                  ├────►│ Store &   │───►│ AI Score │───►│ Complete │
│ Query   │    │ Complexity│  │     ┌───────────────────────┐    │     │ Extract   │    │Confidence│    │          │
└─────────┘    └───────────┘  └────►│ gpt-5.2-codex (quality)│────┘     └───────────┘    └──────────┘    └──────────┘
                                    └───────────────────────┘
```

1. **Pre-processing**: Classify query before model call
2. **Conditional routing** (`?>` / `!>`): Different paths for different query types
3. **Model call**: Call azure_ai.generate() or HTTP to AI provider
4. **Store & Extract**: Save response, extract answer text
5. **AI Confidence**: Use `azure_ai.is_true()` to evaluate answer quality
6. **Full audit**: Track which model handled each query and confidence score

### AI-Generated Confidence Scoring

Use `azure_ai.is_true()` to ask the AI "How confident are you with this answer?" and generate a quality score:

```sql
-- Generate confidence score by prompting the AI
~> 'UPDATE ai_responses 
    SET confidence_score = CASE 
        WHEN azure_ai.is_true(
            ''How confident are you with this answer? Is this response accurate and complete? '' || 
            (SELECT extracted_answer FROM ai_responses WHERE id = $response_id::int)
        ) THEN 0.95  -- High confidence
        ELSE 0.70    -- Lower confidence
    END
    WHERE id = $response_id::int'
```

**How it works:**
- `azure_ai.is_true()` sends the prompt to the AI and returns `true` or `false`
- The prompt asks "How confident are you with this answer?" followed by the actual response
- If the AI determines the answer is accurate/complete, returns `0.95` (high confidence)
- Otherwise returns `0.70` (lower confidence requiring review)

**Alternative: Multi-level confidence scoring**

```sql
-- More granular confidence using multiple prompts
~> 'UPDATE ai_responses 
    SET confidence_score = (
        SELECT 
            (CASE WHEN azure_ai.is_true(''Is this answer factually accurate? '' || extracted_answer) THEN 0.4 ELSE 0.0 END) +
            (CASE WHEN azure_ai.is_true(''Is this answer complete? '' || extracted_answer) THEN 0.3 ELSE 0.0 END) +
            (CASE WHEN azure_ai.is_true(''Is this answer well-formatted? '' || extracted_answer) THEN 0.3 ELSE 0.0 END)
        FROM ai_responses WHERE id = $response_id::int
    )
    WHERE id = $response_id::int'
```

### Advanced: Using azure_ai.extract() for Structured Data

Due to pg_durable's variable wrapping, use azure_ai.extract() by reading from stored database values:

```sql
-- Step 1: Store the raw LLM response first
~> ('INSERT INTO ai_responses (query_id, raw_response)
    VALUES ($query_id::int, jsonb_build_object(''response'', $llm_response))
    RETURNING id' |=> 'response_id')

-- Step 2: Call azure_ai.extract() reading from the stored value
~> ('SELECT azure_ai.extract(
        (SELECT raw_response->>''response'' FROM ai_responses WHERE id = $response_id::int),
        ARRAY[''answer'', ''citations'', ''confidence'']
    ) as extracted' |=> 'extracted_data')

-- Step 3: Update with extracted values (read from DB, not from variable)
~> 'UPDATE ai_responses 
    SET extracted_answer = (
        SELECT (
            SELECT azure_ai.extract(raw_response->>''response'', ARRAY[''answer''])
        )->>''answer''
        FROM ai_responses WHERE id = $response_id::int
    )
    WHERE id = $response_id::int'
```

### Multi-Stage Post-Processing Pattern

For parallel post-processing, store the response first, then read from database:

```sql
-- Store response
~> ('INSERT INTO ai_responses (query_id, raw_response)
    VALUES ($query_id::int, jsonb_build_object(''response'', $llm_response))
    RETURNING id' |=> 'response_id')

-- Parallel post-processing reading from stored response
~> (
    -- Extract citations (parallel branch 1)
    ('SELECT azure_ai.extract(
        (SELECT raw_response->>''response'' FROM ai_responses WHERE id = $response_id::int),
        ARRAY[''citations'', ''sources'']
    )' |=> 'citations')
    
    &  -- parallel
    
    -- Score response quality (parallel branch 2)
    ('SELECT CASE 
        WHEN azure_ai.is_true(''Is this accurate? '' || 
            (SELECT raw_response->>''response'' FROM ai_responses WHERE id = $response_id::int))
        THEN 0.9 ELSE 0.5 END as score' |=> 'score')
)
```

### Production: Using Azure AI Extension

```sql
-- Simple query with fast model
SELECT azure_ai.generate(
    'What is pg_durable?',
    'gpt-5-mini'  -- Fast, cost-effective model
);

-- Complex query with quality model  
SELECT azure_ai.generate(
    'Explain the distributed consensus algorithm...',
    'gpt-5.2-codex'  -- Advanced model for complex tasks
);

-- With custom system prompt
SELECT azure_ai.generate(
    'Summarize this document...',
    'gpt-5.2-codex',
    'You are a technical documentation expert.'
);

-- Alternative: Using HTTP for non-Azure providers
df.http(
    'https://api.openai.com/v1/chat/completions',
    'POST',
    format('{
        "model": "gpt-4",
        "messages": [{"role": "user", "content": %s}],
        "max_tokens": 2000
    }', to_json($query::jsonb->>'user_query')),
    '{"Authorization": "Bearer sk-...", "Content-Type": "application/json"}'::jsonb
)
```

### Verify It Worked

```sql
-- Check processing status
SELECT id, user_query, query_type, routed_model, status 
FROM ai_queries 
ORDER BY created_at DESC;

-- View responses with scores
SELECT 
    q.user_query,
    q.routed_model,
    r.extracted_answer,
    r.confidence_score,
    r.processing_time_ms
FROM ai_queries q
JOIN ai_responses r ON r.query_id = q.id
WHERE q.status = 'completed';

-- View routing decisions
SELECT query_type, routed_model, COUNT(*) 
FROM ai_queries 
WHERE status = 'completed'
GROUP BY query_type, routed_model;
```

### Full Audit: Track Model + Confidence Score

Complete audit trail showing which model handled each query and its confidence score:

```sql
-- Full audit: Model routing + confidence score
SELECT 
    q.id AS query_id,
    q.user_query,
    q.routed_model AS model,
    r.confidence_score,
    r.processing_time_ms,
    q.status
FROM ai_queries q
LEFT JOIN ai_responses r ON r.query_id = q.id
ORDER BY q.created_at DESC;
```

**Example output:**
```
 query_id |          user_query           |   model    | confidence_score | status
----------+-------------------------------+------------+------------------+-----------
        1 | What is pg_durable?           |            |             0.95 | completed
        2 | What is pg_durable?           | gpt-5-mini |                  | routing
        3 | Explain distributed consensus |            |                  | pending
```

**Quick summary view:**
```sql
SELECT 
    q.id,
    LEFT(q.user_query, 40) AS query,
    q.routed_model AS model,
    r.confidence_score AS confidence,
    q.status
FROM ai_queries q
LEFT JOIN ai_responses r ON r.query_id = q.id
ORDER BY q.created_at DESC;
```

**Audit by model performance:**
```sql
SELECT 
    q.routed_model AS model,
    COUNT(*) AS total_queries,
    ROUND(AVG(r.confidence_score), 2) AS avg_confidence,
    ROUND(AVG(r.processing_time_ms)) AS avg_time_ms
FROM ai_queries q
LEFT JOIN ai_responses r ON r.query_id = q.id
WHERE q.status = 'completed'
GROUP BY q.routed_model;
```

**View durable function instances separately:**
```sql
-- Recent durable function executions for AI workflows
SELECT id, label, status, created_at, completed_at
FROM df.instances
WHERE label LIKE 'ai-%' OR label LIKE 'scenario-2%'
ORDER BY created_at DESC
LIMIT 10;
```

---

## Scenario 3: Evaluation Loop with Human Review

### Use This Pattern When...

> *"I want automated evaluation that continues until quality thresholds are met, or pauses for human approval when confidence is low. Essential for responsible AI workflows."*

**Business examples:**
- Content moderation: auto-approve high-confidence, flag low-confidence for review
- Document processing: auto-extract if confident, request validation if unsure
- Model evaluation: iterate refinement until passing score
- Compliance checks: auto-pass clear cases, escalate edge cases

### The Problem

Fully automated AI isn't always safe:
- Low-confidence outputs need human verification
- Compliance requires human-in-the-loop for certain decisions
- Edge cases should escalate rather than guess
- Need audit trail showing human involvement

### The Solution

```sql
-- ============================================================================
-- Setup: Tables for evaluation workflow
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_evaluations (
    id SERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    content_type TEXT,           -- 'text', 'image', 'code'
    auto_score NUMERIC(3,2),     -- 0.00 to 1.00
    human_approved BOOLEAN,
    human_reviewer TEXT,
    status TEXT DEFAULT 'pending',
    iteration INT DEFAULT 0,
    max_iterations INT DEFAULT 5,
    created_at TIMESTAMPTZ DEFAULT now(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS evaluation_log (
    id SERIAL PRIMARY KEY,
    evaluation_id INT REFERENCES ai_evaluations(id),
    iteration INT,
    action TEXT,                 -- 'auto_eval', 'human_requested', 'human_approved', 'human_rejected', 'timeout'
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Insert content to evaluate
INSERT INTO ai_evaluations (content, content_type) VALUES 
    ('This is safe, high-quality AI-generated content.', 'text'),
    ('This content might need review for accuracy.', 'text');

-- ============================================================================
-- Human-in-the-Loop Evaluation Pipeline
-- ============================================================================

SELECT df.start(
    -- Step 1: Get pending evaluation ID
    ('SELECT id FROM ai_evaluations 
     WHERE status = ''pending'' LIMIT 1' |=> 'eval_id')
    
    ~> 'UPDATE ai_evaluations SET status = ''evaluating'' 
        WHERE id = $eval_id::int'
    
    -- Step 2: Evaluation loop
    ~> df.loop(
        
        -- 2A: Run automated evaluation (store score in DB)
        'UPDATE ai_evaluations 
         SET auto_score = 0.7 + (random() * 0.3),  -- Simulated: 0.70 - 1.00
             iteration = iteration + 1
         WHERE id = $eval_id::int'
        
        -- 2B: Log this evaluation attempt (read values from DB)
        ~> 'INSERT INTO evaluation_log (evaluation_id, iteration, action, details)
            SELECT 
                $eval_id::int,
                iteration,
                ''auto_eval'',
                jsonb_build_object(''score'', auto_score)
            FROM ai_evaluations WHERE id = $eval_id::int'
        
        -- 2C: Decision based on score (read from DB, not variable)
        ~> (
            -- HIGH confidence (>= 0.90): Auto-approve
            'SELECT auto_score >= 0.90 FROM ai_evaluations WHERE id = $eval_id::int'
            ?> (
                'UPDATE ai_evaluations 
                 SET status = ''approved'', 
                     human_approved = false,
                     completed_at = now()
                 WHERE id = $eval_id::int'
                
                ~> 'INSERT INTO evaluation_log (evaluation_id, action, details)
                    VALUES ($eval_id::int, ''auto_approved'', 
                            ''{"reason": "score >= 0.90"}''::jsonb)'
                
                ~> df.break('{"exit": "auto_approved"}')
            )
            !> (
                -- LOW confidence: Request human review
                'INSERT INTO evaluation_log (evaluation_id, action, details)
                    SELECT $eval_id::int, ''human_requested'', 
                           jsonb_build_object(''score'', auto_score)
                    FROM ai_evaluations WHERE id = $eval_id::int'
                
                -- Wait for human signal (5 minute timeout)
                ~> (df.wait_for_signal('human_decision', 300) |=> 'human_signal')
                
                -- Process human decision
                ~> (
                    'SELECT COALESCE(($human_signal::jsonb->''data''->>''approved'')::boolean, false)'
                    ?> (
                        -- Human APPROVED
                        'UPDATE ai_evaluations 
                         SET status = ''approved'', 
                             human_approved = true,
                             human_reviewer = COALESCE($human_signal::jsonb->''data''->>''reviewer'', ''unknown''),
                             completed_at = now()
                         WHERE id = $eval_id::int'
                        
                        ~> 'INSERT INTO evaluation_log (evaluation_id, action, details)
                            VALUES ($eval_id::int, ''human_approved'', $human_signal::jsonb)'
                        
                        ~> df.break('{"exit": "human_approved"}')
                    )
                    !> (
                        -- Human REJECTED or TIMEOUT: check if should retry
                        'INSERT INTO evaluation_log (evaluation_id, action, details)
                         VALUES ($eval_id::int, 
                                 CASE WHEN ($human_signal::jsonb->>''timed_out'')::boolean 
                                      THEN ''timeout'' ELSE ''human_rejected'' END,
                                 $human_signal::jsonb)'
                        -- Loop will continue if condition still true
                    )
                )
            )
        ),
        
        -- Loop condition: continue while evaluating and under max iterations
        'SELECT status = ''evaluating'' AND iteration < max_iterations 
         FROM ai_evaluations WHERE id = $eval_id::int'
    )
    
    -- Step 3: Handle loop exhaustion (max iterations reached)
    ~> 'UPDATE ai_evaluations 
        SET status = CASE 
            WHEN status = ''evaluating'' THEN ''escalated''
            ELSE status 
        END,
        completed_at = COALESCE(completed_at, now())
        WHERE id = $eval_id::int',
    
    'ai-human-in-loop'
);
```

### How It Works

```
┌──────────────────────────────────────────────────────────────────┐
│                        EVALUATION LOOP                            │
│  ┌────────────┐    ┌─────────────────────────────────────────┐   │
│  │ Auto-Eval  │───►│ Score >= 0.90?                          │   │
│  │ (scoring)  │    │                                         │   │
│  └────────────┘    │  YES ──► Auto-Approve ──► EXIT LOOP     │   │
│                    │                                         │   │
│                    │  NO  ──► Request Human Review           │   │
│                    │          │                              │   │
│                    │          ▼                              │   │
│                    │     ┌─────────────┐                     │   │
│                    │     │ WAIT FOR    │◄── df.signal()      │   │
│                    │     │ SIGNAL      │    from human       │   │
│                    │     │ (5 min)     │                     │   │
│                    │     └──────┬──────┘                     │   │
│                    │            │                            │   │
│                    │    Approved? ──► YES ──► EXIT LOOP      │   │
│                    │            │                            │   │
│                    │            └─► NO/Timeout ──► RETRY     │   │
│                    └─────────────────────────────────────────┘   │
│                                    │                             │
│                    iteration < max? ──► NO ──► Escalate          │
└──────────────────────────────────────────────────────────────────┘
```

1. **Loop** (`df.loop()`): Iterates until approved or max iterations
2. **Automated scoring**: Each iteration runs evaluation model
3. **Conditional exit**: High scores auto-approve via `df.break()`
4. **Signal waiting** (`df.wait_for_signal()`): Pauses for human input
5. **Timeout handling**: 5-minute timeout prevents indefinite waits
6. **Escalation**: Exceeding max iterations flags for manual review

### Sending Human Signals

From your review application, send approval/rejection:

```sql
-- Get the instance waiting for review
SELECT instance_id, status 
FROM df.instances 
WHERE label = 'ai-human-in-loop' 
  AND status = 'Running';

-- Send APPROVAL
SELECT df.signal(
    'abc12345',  -- Replace with instance_id
    'human_decision',
    '{"approved": true, "reviewer": "alice@company.com", "notes": "Content looks good"}'
);

-- Send REJECTION  
SELECT df.signal(
    'abc12345',
    'human_decision',
    '{"approved": false, "reviewer": "bob@company.com", "reason": "Needs factual correction"}'
);
```

### Building a Review Dashboard

```sql
-- Items waiting for human review
SELECT 
    e.id,
    e.content,
    e.auto_score,
    e.iteration,
    i.instance_id
FROM ai_evaluations e
JOIN df.instances i ON i.label = 'ai-human-in-loop'
WHERE e.status = 'evaluating'
  AND i.status = 'Running';

-- Review history with human decisions
SELECT 
    e.id,
    e.content,
    e.status,
    e.auto_score,
    e.human_approved,
    e.human_reviewer,
    e.completed_at
FROM ai_evaluations e
WHERE e.completed_at IS NOT NULL
ORDER BY e.completed_at DESC;

-- Audit trail for compliance
SELECT 
    l.evaluation_id,
    l.iteration,
    l.action,
    l.details,
    l.created_at
FROM evaluation_log l
WHERE l.evaluation_id = 1
ORDER BY l.created_at;
```

### Verify It Worked

```sql
-- Check current status
SELECT id, content, auto_score, status, iteration, human_approved, human_reviewer
FROM ai_evaluations;

-- View complete audit trail
SELECT 
    e.id as eval_id,
    e.status,
    l.action,
    l.details,
    l.created_at
FROM ai_evaluations e
LEFT JOIN evaluation_log l ON l.evaluation_id = e.id
ORDER BY e.id, l.created_at;

-- Summary statistics
SELECT 
    status,
    COUNT(*) as count,
    AVG(auto_score) as avg_score,
    AVG(iteration) as avg_iterations
FROM ai_evaluations
GROUP BY status;
```

### Signal Pattern Reference

| Function | Purpose |
|----------|---------|
| `df.wait_for_signal('name')` | Pause indefinitely until signal |
| `df.wait_for_signal('name', 300)` | Pause with 5-minute timeout |
| `df.signal(inst_id, 'name', data)` | Send signal to waiting instance |

Signal data structure received by workflow:
```json
{
    "timed_out": false,
    "data": { "approved": true, "reviewer": "..." }
}
```

---

## Scenario 4: AI Output Governance — Versioned & Governed Results

### Use This Pattern When...

> *"I need AI results treated like first-class product data — versioned, governed, and auditable — not disposable one-shot responses."*

**Business examples:**
- AI-generated product descriptions that go through approval before publishing
- LLM-produced compliance summaries that must be versioned for regulatory audit
- AI recommendation outputs tracked with provenance, scoring, and rollback
- ML model predictions stored with lineage so you can reproduce or contest any decision
- Content moderation verdicts retained with full version history

### The Problem

When AI outputs live in the app layer, they're ephemeral:
- No version history — you can't see what the model said last week
- No governance — anyone can overwrite or discard results without audit
- No provenance — you can't trace which model, prompt, or input produced a result
- No rollback — a bad model upgrade silently corrupts all downstream data
- No trust — stakeholders can't verify, contest, or reproduce AI decisions

And for a lot of customers moving to using AI in their database only makes sense if it supports versioning, governance, and control — otherwise it's easier to keep AI in the app layer and built an app to support the needed tooling.

### The Solution

```sql
-- ============================================================================
-- Setup: Tables for governed AI outputs
-- ============================================================================

-- Stores every AI output as an immutable versioned record
CREATE TABLE IF NOT EXISTS ai_outputs (
    id SERIAL PRIMARY KEY,
    entity_type TEXT NOT NULL,         -- e.g. 'product', 'document', 'claim'
    entity_id INT NOT NULL,            -- FK to the source entity
    output_type TEXT NOT NULL,          -- e.g. 'description', 'summary', 'score'
    version INT NOT NULL DEFAULT 1,
    content TEXT NOT NULL,              -- the AI-generated result
    model_id TEXT,                      -- which model produced this
    prompt_hash TEXT,                   -- hash of the prompt used
    confidence NUMERIC(5,4),            -- model confidence score
    status TEXT NOT NULL DEFAULT 'draft',  -- draft | approved | rejected | superseded
    approved_by TEXT,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    metadata JSONB DEFAULT '{}',        -- extra provenance data
    UNIQUE (entity_type, entity_id, output_type, version)
);

-- Governance policy table: rules for auto-approve vs human review
CREATE TABLE IF NOT EXISTS ai_governance_policies (
    id SERIAL PRIMARY KEY,
    entity_type TEXT NOT NULL,
    output_type TEXT NOT NULL,
    auto_approve_threshold NUMERIC(5,4) DEFAULT 0.95,
    require_human_review BOOLEAN DEFAULT false,
    max_versions INT DEFAULT 10,
    retention_days INT DEFAULT 365,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE (entity_type, output_type)
);

-- Audit log for all governance actions
CREATE TABLE IF NOT EXISTS ai_output_audit (
    id SERIAL PRIMARY KEY,
    output_id INT REFERENCES ai_outputs(id),
    action TEXT NOT NULL,              -- generated | approved | rejected | rolled_back | superseded
    actor TEXT,                        -- 'system', 'model:gpt-4o', 'user:alice'
    reason TEXT,
    previous_version INT,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Sample source data
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    raw_specs TEXT,
    current_description_version INT,
    updated_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO products (name, raw_specs) VALUES
    ('Widget Pro', 'Titanium frame, 120g, waterproof IP68, 10hr battery'),
    ('Sensor Max', '0.01mm precision, -40C to 85C range, USB-C, NIST traceable');

INSERT INTO ai_governance_policies (entity_type, output_type, auto_approve_threshold, require_human_review)
VALUES
    ('product', 'description', 0.92, false),
    ('product', 'compliance_summary', 0.00, true);  -- always requires human review

-- ============================================================================
-- Pipeline: Generate, Version, and Govern AI Output
-- ============================================================================

SELECT df.start(
    -- Step 1: Pick a product that needs a description generated/refreshed
    ('SELECT id FROM products 
      WHERE id NOT IN (
          SELECT entity_id FROM ai_outputs 
          WHERE entity_type = ''product'' AND output_type = ''description'' AND status = ''approved''
      ) LIMIT 1' |=> 'product_id')

    -- Step 2: Determine the next version number
    ~> ('SELECT COALESCE(MAX(version), 0) + 1 
         FROM ai_outputs 
         WHERE entity_type = ''product'' AND entity_id = $product_id::int 
           AND output_type = ''description''' |=> 'next_version')

    -- Step 3: Generate AI description via LLM
    -- Uses Azure AI extension; swap for df.http() if using external API
    ~> ('INSERT INTO ai_outputs (entity_type, entity_id, output_type, version, content, model_id, prompt_hash, confidence, metadata)
        SELECT 
            ''product'',
            $product_id::int,
            ''description'',
            $next_version::int,
            azure_openai.create(
                ''gpt-4o'',
                jsonb_build_object(
                    ''messages'', jsonb_build_array(
                        jsonb_build_object(''role'', ''system'', ''content'', 
                            ''Write a concise product description from specs. One paragraph.''),
                        jsonb_build_object(''role'', ''user'', ''content'', p.raw_specs)
                    )
                )
            )::jsonb->>''content'',
            ''gpt-4o'',
            md5(''product-description-v1:'' || p.raw_specs),
            0.93,
            jsonb_build_object(''source_specs'', p.raw_specs, ''pipeline'', ''ai-output-governance'')
        FROM products p WHERE p.id = $product_id::int
        RETURNING id' |=> 'output_id')

    -- Step 4: Log the generation event
    ~> 'INSERT INTO ai_output_audit (output_id, action, actor, details)
        VALUES ($output_id::int, ''generated'', ''model:gpt-4o'', 
                jsonb_build_object(''version'', $next_version::int))'

    -- Step 5: Supersede any previous approved version
    ~> 'UPDATE ai_outputs 
        SET status = ''superseded'' 
        WHERE entity_type = ''product'' AND entity_id = $product_id::int 
          AND output_type = ''description'' AND status = ''approved'''

    -- Step 6: Apply governance policy
    ~> (
        -- Check: does policy allow auto-approve at this confidence?
        'SELECT ao.confidence >= gp.auto_approve_threshold AND NOT gp.require_human_review
         FROM ai_outputs ao
         JOIN ai_governance_policies gp 
           ON gp.entity_type = ao.entity_type AND gp.output_type = ao.output_type
         WHERE ao.id = $output_id::int'
        ?> (
            -- AUTO-APPROVE: confidence meets threshold
            'UPDATE ai_outputs SET status = ''approved'', approved_by = ''system:auto'', approved_at = now()
             WHERE id = $output_id::int'
            ~> 'INSERT INTO ai_output_audit (output_id, action, actor, reason)
                VALUES ($output_id::int, ''approved'', ''system:auto'', ''confidence >= threshold'')'
            ~> 'UPDATE products SET current_description_version = $next_version::int, updated_at = now()
                WHERE id = $product_id::int'
        )
        !> (
            -- NEEDS REVIEW: wait for human signal
            'INSERT INTO ai_output_audit (output_id, action, actor, reason)
             VALUES ($output_id::int, ''review_requested'', ''system'', 
                     ''confidence below threshold or human review required'')'
            ~> (df.wait_for_signal('output_review', 600) |=> 'review_signal')
            ~> (
                'SELECT COALESCE(($review_signal::jsonb->''data''->>''approved'')::boolean, false)'
                ?> (
                    'UPDATE ai_outputs SET status = ''approved'', 
                            approved_by = $review_signal::jsonb->''data''->>''reviewer'',
                            approved_at = now()
                     WHERE id = $output_id::int'
                    ~> 'INSERT INTO ai_output_audit (output_id, action, actor, details)
                        VALUES ($output_id::int, ''approved'', 
                                $review_signal::jsonb->''data''->>''reviewer'', 
                                $review_signal::jsonb)'
                    ~> 'UPDATE products SET current_description_version = $next_version::int, updated_at = now()
                        WHERE id = $product_id::int'
                )
                !> (
                    'UPDATE ai_outputs SET status = ''rejected'' WHERE id = $output_id::int'
                    ~> 'INSERT INTO ai_output_audit (output_id, action, actor, reason, details)
                        VALUES ($output_id::int, ''rejected'', 
                                COALESCE($review_signal::jsonb->''data''->>''reviewer'', ''unknown''),
                                COALESCE($review_signal::jsonb->''data''->>''reason'', ''no reason given''),
                                $review_signal::jsonb)'
                )
            )
        )
    ),

    'ai-output-governance'
);
```

### How It Works

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Pick Entity │───►│ Determine   │───►│ Generate    │───►│ Log &       │
│ Needing AI  │    │ Next        │    │ AI Output   │    │ Supersede   │
│ Output      │    │ Version     │    │ (versioned) │    │ Previous    │
└─────────────┘    └─────────────┘    └─────────────┘    └──────┬──────┘
                                                                │
                                                    ┌───────────▼──────────┐
                                                    │ Apply Governance     │
                                                    │ Policy               │
                                                    └───┬──────────────┬───┘
                                                        │              │
                                              Confidence ≥           Confidence <
                                              threshold              threshold
                                                        │              │
                                                        ▼              ▼
                                               ┌──────────┐   ┌──────────────┐
                                               │ Auto-    │   │ Wait for     │
                                               │ Approve  │   │ Human Review │
                                               └────┬─────┘   └──────┬───────┘
                                                    │                │
                                                    ▼          Approved / Rejected
                                               ┌──────────┐         │
                                               │ Publish  │◄────────┘
                                               │ Version  │   (or reject & stop)
                                               └──────────┘
```

1. **Immutable versioning**: Every AI output gets a version number; nothing is overwritten
2. **Provenance tracking**: Model ID, prompt hash, confidence, and metadata recorded at generation time
3. **Policy-driven governance**: Auto-approve or require human review based on configurable thresholds
4. **Supersession**: Previous approved versions are marked `superseded` — never deleted
5. **Full audit trail**: Every action (generate, approve, reject, rollback) logged with actor and timestamp

### Why DB-Layer Control Matters

| App-Layer AI | DB-Layer Controlled AI (pg_durable) |
|---|---|
| Results vanish after response | Every output immutably versioned |
| No audit trail | Full provenance: model, prompt, confidence, actor |
| Ad-hoc governance in code | Declarative policies in `ai_governance_policies` table |
| Rollback = re-generate & hope | Rollback = point to previous approved version |
| Scattered across services | Single source of truth in PostgreSQL |
| Hard to reproduce decisions | Reproduce any decision from stored inputs + model ID |

### Rolling Back to a Previous Version

```sql
-- View all versions for a product description
SELECT version, status, confidence, model_id, approved_by, created_at
FROM ai_outputs
WHERE entity_type = 'product' AND entity_id = 1 AND output_type = 'description'
ORDER BY version DESC;

-- Rollback: revert product to version 2
WITH rollback AS (
    UPDATE ai_outputs SET status = 'superseded'
    WHERE entity_type = 'product' AND entity_id = 1 
      AND output_type = 'description' AND status = 'approved'
    RETURNING id, version
)
UPDATE ai_outputs SET status = 'approved', approved_by = 'system:rollback', approved_at = now()
WHERE entity_type = 'product' AND entity_id = 1 
  AND output_type = 'description' AND version = 2
RETURNING id;

-- Log the rollback action
INSERT INTO ai_output_audit (output_id, action, actor, reason, previous_version)
SELECT id, 'rolled_back', 'user:admin', 'Model v3 regression detected', 
       (SELECT version FROM ai_outputs 
        WHERE entity_type = 'product' AND entity_id = 1 
          AND output_type = 'description' AND status = 'superseded'
        ORDER BY approved_at DESC LIMIT 1)
FROM ai_outputs
WHERE entity_type = 'product' AND entity_id = 1 
  AND output_type = 'description' AND version = 2;
```

### Enforcing Retention & Version Limits

```sql
-- Durable function to enforce governance policies
SELECT df.start(
    df.loop(
        -- Find outputs exceeding max version count
        ('SELECT ao.id FROM ai_outputs ao
          JOIN ai_governance_policies gp 
            ON gp.entity_type = ao.entity_type AND gp.output_type = ao.output_type
          WHERE ao.status = ''superseded''
            AND ao.version <= (
                SELECT MAX(version) - gp.max_versions 
                FROM ai_outputs a2 
                WHERE a2.entity_type = ao.entity_type 
                  AND a2.entity_id = ao.entity_id 
                  AND a2.output_type = ao.output_type
            )
          LIMIT 1' |=> 'old_id')
        ~> (
            'SELECT $old_id IS NOT NULL'
            ?> (
                'INSERT INTO ai_output_audit (output_id, action, actor, reason)
                 VALUES ($old_id::int, ''archived'', ''system:retention'', ''exceeded max_versions'')'
                ~> 'DELETE FROM ai_outputs WHERE id = $old_id::int'
            )
            !> df.break('{"reason": "retention_complete"}')
        ),
        'SELECT EXISTS(
            SELECT 1 FROM ai_outputs ao
            JOIN ai_governance_policies gp 
              ON gp.entity_type = ao.entity_type AND gp.output_type = ao.output_type
            WHERE ao.status = ''superseded''
              AND ao.version <= (
                  SELECT MAX(version) - gp.max_versions 
                  FROM ai_outputs a2 
                  WHERE a2.entity_type = ao.entity_type 
                    AND a2.entity_id = ao.entity_id 
                    AND a2.output_type = ao.output_type
              )
        )'
    ),
    'ai-retention-cleanup'
);
```

### Governance Dashboard Queries

```sql
-- Outputs pending review
SELECT ao.id, ao.entity_type, ao.entity_id, ao.output_type, ao.version, 
       ao.confidence, ao.created_at,
       i.instance_id
FROM ai_outputs ao
JOIN df.instances i ON i.label = 'ai-output-governance'
WHERE ao.status = 'draft'
  AND i.status = 'Running';

-- Approval rate by output type
SELECT output_type,
       COUNT(*) FILTER (WHERE status = 'approved') AS approved,
       COUNT(*) FILTER (WHERE status = 'rejected') AS rejected,
       ROUND(AVG(confidence), 4) AS avg_confidence,
       ROUND(COUNT(*) FILTER (WHERE approved_by = 'system:auto')::numeric / 
             NULLIF(COUNT(*) FILTER (WHERE status = 'approved'), 0), 2) AS auto_approve_rate
FROM ai_outputs
GROUP BY output_type;

-- Version history for a specific entity
SELECT ao.version, ao.status, ao.confidence, ao.model_id, 
       ao.approved_by, ao.created_at, ao.approved_at,
       a.action, a.actor, a.reason, a.created_at AS audit_time
FROM ai_outputs ao
LEFT JOIN ai_output_audit a ON a.output_id = ao.id
WHERE ao.entity_type = 'product' AND ao.entity_id = 1 AND ao.output_type = 'description'
ORDER BY ao.version DESC, a.created_at;
```

### Sending Review Decisions

```sql
-- Approve an AI output via signal
SELECT df.signal(
    'abc12345',  -- instance_id from governance dashboard
    'output_review',
    '{"approved": true, "reviewer": "alice@company.com", "notes": "Description is accurate"}'
);

-- Reject with reason
SELECT df.signal(
    'abc12345',
    'output_review',
    '{"approved": false, "reviewer": "bob@company.com", "reason": "Incorrect specs mentioned"}'
);
```

### Verify It Worked

```sql
-- Check output status and version history
SELECT entity_type, entity_id, output_type, version, status, 
       confidence, model_id, approved_by, created_at
FROM ai_outputs
ORDER BY entity_type, entity_id, output_type, version;

-- Check full audit trail
SELECT ao.entity_type, ao.entity_id, ao.output_type, ao.version,
       a.action, a.actor, a.reason, a.created_at
FROM ai_output_audit a
JOIN ai_outputs ao ON ao.id = a.output_id
ORDER BY a.created_at;

-- Verify governance policies are applied
SELECT gp.entity_type, gp.output_type, gp.auto_approve_threshold, gp.require_human_review,
       COUNT(ao.id) AS total_outputs,
       COUNT(ao.id) FILTER (WHERE ao.status = 'approved') AS approved
FROM ai_governance_policies gp
LEFT JOIN ai_outputs ao ON ao.entity_type = gp.entity_type AND ao.output_type = gp.output_type
GROUP BY gp.entity_type, gp.output_type, gp.auto_approve_threshold, gp.require_human_review;
```

---

## Next Steps

- **[Database Scenarios](../SCENARIOS.md)** — ETL, parallel processing, scheduling
- **[User Guide](../../USER_GUIDE.md)** — Complete DSL reference
- **[Architecture](../ARCHITECTURE.md)** — How pg_durable works

---

*These patterns are production-tested. For real deployments, add appropriate error handling, security measures, and monitoring.*
