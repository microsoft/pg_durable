# Demo Script: AI Pipelines in PostgreSQL with pg_durable

> **Format:** Video walkthrough / live demo narration
> **Duration:** ~8 minutes
> **Audience:** Developers and data engineers familiar with PostgreSQL
> **Demo file:** `sql/ai/demo_rag_pipeline.sql`

---

## INTRO (30 seconds)

**[Screen: empty psql terminal]**

What if you could build a full RAG pipeline — chunking, embeddings, incremental processing — with nothing but SQL? No Airflow. No Kafka. No Python glue scripts. Just PostgreSQL.

Today I'm going to show you how, and more importantly, I'm going to show you *why it works* — because the architecture underneath is what makes this genuinely different from every other pipeline tool out there.

---

## ACT 1 — Three Statements to a Working Pipeline (2 minutes)

**[Screen: show the SQL file]**

Let's start with the end result. Here's the entire user experience.

**Statement 1** — we have a documents table. Normal PostgreSQL table, nothing special:

```sql
CREATE TABLE documents (
    id          SERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    content     TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

I'll insert a couple of docs about pgvector and durable execution.

```sql
INSERT INTO documents (title, content) VALUES
    ('Intro to pgvector',
     'pgvector is a PostgreSQL extension for vector similarity search. '
     'It supports exact and approximate nearest neighbor search using '
     'IVFFlat and HNSW indexes. Vectors can be stored alongside regular '
     'relational data, enabling hybrid queries that combine semantic '
     'similarity with traditional SQL filters.'),
    ('Durable Execution',
     'Durable execution ensures that long-running workflows survive '
     'crashes, restarts, and network failures. pg_durable brings this '
     'pattern into PostgreSQL by persisting function graphs and replaying '
     'them through a background worker powered by the duroxide runtime.');
```

**Statement 2** — create the pipeline:

```sql
SELECT ai.create_pipeline(
    name    => 'rag_pipeline',
    source  => ai.table_source('documents', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input_column => 'content'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text',
                 dimensions => 1536)
    ],
    trigger => 'on_change'
);
```

**[Run it — point out the NOTICE]**

> *"Notice: Auto-created sink table: public.rag_pipeline_output"*

We didn't define an output table. It figured out the schema from the steps we declared — chunks need `doc_id`, `chunk_index`, `chunk_text`, and a `vector(1536)` column for the embeddings — and created it for us.

**Statement 3** — run it:

```sql
SELECT ai.run('rag_pipeline');
```

That's it. Three statements. Our documents are now chunked, embedded, and queryable.

**Show Dashboard with Pipeline**


**[Run a quick semantic search query to show results]**

---

## ACT 2 — The Magic: JSONB Descriptors → Durable Execution Graph (3 minutes)

**[Screen: show the step functions side-by-side with their output]**

OK so that looked easy. But let me show you what's actually happening, because *this* is where the design gets interesting.

### Every step is a JSONB factory

Each function in the pipeline DSL — `ai.chunk()`, `ai.embed()`, `ai.extract()` — doesn't *do* anything. It returns a tiny JSON object describing *what it wants to do*:

```sql
SELECT ai.chunk(input_column => 'content');
```
```json
{"step": "chunk", "column": "content", "method": "recursive",
 "overlap": 64, "chunk_size": 512}
```

```sql
SELECT ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text',
                dimensions => 1536);
```
```json
{"step": "embed", "model": "text-embedding-3-small", "column": "chunk_text",
 "batch_size": 100, "dimensions": 1536}
```

These are just *specifications*. Inert data. No embeddings are generated, no text is chunked — we're just declaring our intent.

### create_pipeline stores the JSONB array

When you write `steps => ARRAY[ai.chunk(...), ai.embed(...)]`, PostgreSQL evaluates each function and produces a `JSONB[]` — an array of descriptors. That array, along with the source and sink descriptors, gets stored in a regular table:

**[Run the query against ai.pipelines]**

```sql
SELECT name, source_config, steps, sink_config FROM ai.pipelines
 WHERE name = 'rag_pipeline';
```

The entire pipeline definition is just *data in a table*. You can query it, inspect it, diff it, back it up with `pg_dump`. The pipeline definition *is* the database.

### ai.run() interprets the definition into a durable execution graph

**[This is the key slide — slow down here]**

Here's where pg_durable enters the picture. When you call `ai.run('rag_pipeline')`, it:

1. **Reads** the JSONB definition from `ai.pipelines`
2. **Generates real SQL** for each step descriptor — a chunk step becomes a call to `ai._chunk_text()`, an embed step becomes a call to `azure_openai.create_embeddings()`
3. **Chains them with the `~>` operator** into a durable execution graph:

```
'CREATE TABLE ai._batch_abc AS SELECT * FROM documents WHERE ...'
  ~> 'CREATE TABLE ai._batch_abc_chunks (...)'
  ~> 'INSERT INTO ai._batch_abc_chunks SELECT ... ai._chunk_text(...)'
  ~> 'UPDATE ai._batch_abc_chunks SET embedding = create_embeddings(...)'
  ~> 'INSERT INTO rag_pipeline_output SELECT * FROM ai._batch_abc_chunks'
  ~> 'UPDATE ai.pipeline_checkpoints SET ...'
  ~> 'DROP TABLE ai._batch_abc_chunks'
  ~> 'DROP TABLE ai._batch_abc'
```

4. **Calls `df.start()`** — and pg_durable's background worker takes over.

Each `~>` creates a *durable sequencing node*. That means if PostgreSQL crashes between the embedding step and the sink step, the background worker picks up exactly where it left off. It won't re-chunk. It won't re-embed. It replays from the last completed node.

**[Show `ai.explain('rag_pipeline')` output]**

This is the execution plan — you can see the graph visually:

```
Pipeline: rag_pipeline
Trigger:  on_change
──────────────────────────────
  [SOURCE] public.documents (incremental: updated_at)
     │
     ▼
  [STEP 1] CHUNK (column=content, method=recursive, size=512, overlap=64)
     │
     ▼
  [STEP 2] EMBED (model=text-embedding-3-small, column=chunk_text, batch=100)
     │
     ▼
  [SINK] public.rag_pipeline_output
```

---

## ACT 3 — Extensible by Composition (1.5 minutes)

**[Screen: show a more complex pipeline definition]**

Because each step is just a JSONB object in an array, the pipeline is *composable*. You want to add sentiment extraction and a human approval gate? Just add more items:

```sql
steps => ARRAY[
    ai.chunk(input_column => 'content'),
    ai.extract(model => 'gpt-5-mini', input_column => 'chunk_text',
               data => ARRAY['sentiment: customer sentiment',
                              'urgency: low/medium/high/critical',
                              'next_action: recommended action']),
    ai.request_approval(content => 'chunk_text', timeout => 3600),
    ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text'),
    ai.generate(model => 'gpt-5-mini', prompt_template => '...',
                input_column => 'chunk_text')
]
```

Each new step becomes another node in the durable execution graph. The approval step maps to `df.wait_for_signal()` — the pipeline *literally pauses* and survives server restarts until a human sends the approval signal. Then it picks up right where it left off.

You're not writing orchestration code. You're declaring a specification, and pg_durable turns it into a crash-safe workflow.

---

## ACT 4 — Why This Matters (1 minute)

**[Screen: bullet points or just narration over the terminal]**

Let me leave you with why I think this design matters:

**Durable by default.** Every pipeline run is crash-safe. This isn't a cron job that retries from scratch — pg_durable persists the execution graph and each node's completion status. Partial progress is never lost.

**No external infrastructure.** There's no Airflow scheduler, no Kafka broker, no Redis queue, no Lambda function. The pipeline runs inside PostgreSQL itself via a background worker. Your data never leaves the database boundary until it calls an external API like the embedding model.

**It's just SQL.** The pipeline definition is a function call. The pipeline state is a table. Monitoring is a query. It composes with everything developers already know — psql, pg_dump, GRANT, row-level security. You can inspect your pipeline with a SELECT statement.

**It's just an array.** Want to add a step? Add an element to the array. Want to remove one? Delete it. Want to reorder? Move it. The JSONB-array-of-descriptors design means pipelines are data you can reason about, not code you have to deploy.

---

## OUTRO (30 seconds)

**[Screen: back to the three-statement demo]**

So that's AI pipelines on pg_durable. Three SQL statements to a working RAG pipeline. Declarative JSONB descriptors that get interpreted into crash-safe durable execution graphs at runtime. Extensible by just adding steps to an array.

Everything runs inside your database. Nothing else required.

**[End]**
