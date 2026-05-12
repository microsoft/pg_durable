# Azure Friday Demo Script (3 min)

## ① Provision with AI

- **AIMM Checkbox**

First, we're going to provision the HorizonDB cluster — which is already provisioned here. All I need to do is check this box. Checking that box enables AI for my HorizonDB database, which lets me do things like vector search, create embeddings, and more.

- **Zava Designer Agent intro**

Yeah — there you have it: the app.

So what's happening is, I'm currently trying to design my apartment in Brooklyn. I press this button, and the agent goes ahead and designs the room. Under the hood, the agent is connected to a HorizonDB cluster and doing several things.

All right — wow, you can see the room is completely designed. Can you believe that was all done in one database called HorizonDB? Here's how it works.

*(Click the "Work It" button.)*

It takes the room description, embeds it, and searches the complete catalog to find furniture that fits the design. It uses hybrid search to find products that match the room description. It uses the SQL database to filter products based on what the user selected. And with `ai.rank`, I can re-rank the results to make sure I have the most relevant matches for designing the room.

Okay, let me show you what's happening under the hood. There are two parts:

1. **Data ingestion** — how we get all the data into the database
2. **Data retrieval** — how we use search to find and return the right results

---

## ② Data Ingestion

- **AI Pipeline** → `ai.run()` / `ai.pause()` / `ai.resume()`
- 8 lines of code
- Show pipeline & count increasing
- Pause it, show count
- Resume it, show count continuing

Here's the script for creating the pipeline — it's 8 lines of code.

```sql
SELECT ai.create_pipeline(
    name    => 'product_rag_pipeline',
    source  => ai.table_source('product_sample', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input_column => 'title'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text',
                 dimensions => 1536)
    ],
    trigger => 'on_change'
);
```

Three things to notice:

**Name** — you name your pipeline.

**Source** — you specify where your data lives and how to incrementally update. In this example, whenever `updated_at` changes, the pipeline automatically picks up the new data.

**Steps** — there are two steps: chunk the data based on the title column, then embed all those chunks and store them in the database.

And the **trigger** is `on_change` — the pipeline runs automatically whenever something new is added to the dataset.

Let me show you a quick demo.

```sql
SELECT ai.run('product_rag_pipeline');
SELECT count(*) FROM product_rag_pipeline_output;
```

We run, and the pipeline starts processing. Let's count how much has been processed... Wow, you can already see 10 rows processed.

Now let me pause the pipeline to show you fault tolerance — this runs on durable functions, so it can stop, start, and always resume.

```sql
SELECT ai.pause('product_rag_pipeline');
SELECT count(*) FROM product_rag_pipeline_output;
```

It's paused. You can see 30 rows have been added. Now let's resume:

```sql
SELECT ai.resume('product_rag_pipeline');
SELECT count(*) FROM product_rag_pipeline_output;
```

It's no longer 30 — now it's 40, and it'll keep going until every row is processed. That's data ingestion.

---

## ③ Data Retrieval

- **`ai.search()`** → show queries
- 1 line of setup, 1 search call

For data retrieval, it's equally simple.

First, one line to set up the indexes for search. This creates both the vector index and the full-text search index:

```sql
SELECT setup_index_for_search('product_rag_pipeline_output');
```

Now with `ai.search`, the user puts in a query — this is the room description — specifies the source table (the output of our pipeline), the column to search through, and a filter. Let's filter by chairs to see what comes back:

```sql
SELECT output.id, output.chunk_text AS product, search.score
FROM ai.search(
    query          => 'mid-century modern furniture for Brooklyn loft living room',
    source_table   => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    filter         => 'category = ''Chairs'''
) search
JOIN product_rag_pipeline_output output ON output.id = search.id;
```

This is all powered by what we set up. Because we created the indexes, `ai.search` auto-detects them, uses the built-in AI models from the AI model management we enabled earlier, and combines vector search with our new BM25 full-text search to give you the most accurate results.
