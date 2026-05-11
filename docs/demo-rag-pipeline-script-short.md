# Demo Script 2: AI Pipeline Highlights in PostgreSQL with pg_durable

> **Format:** Video walkthrough / live demo narration
> **Duration:** ~2 minutes 30 seconds
> **Audience:** Developers and data engineers familiar with PostgreSQL
> **Demo file:** `sql/ai/demo_rag_pipeline.sql`

---

## INTRO (20 seconds)

**[Screen: psql terminal + docs table]**


Hey folks, I'm Abe, a PM on the Postgres AI team. 

Today i'll be using AI Pipelines in HorizonDB to show you how little SQL it takes to stand up a real AI pipeline — directly inside PostgreSQL. No external orchseration. No glue code. just Postgres.

---

## ACT 1 — RAG Pipeline in Seconds (90 seconds)

**[Screen: show pipeline definition]**

So here’s our starting point — a table with a few real-looking products in a store catalog.

Now watch how easy is it to make this table ready for vector search?:

The AI pipelines is fairly simple, take data from the source `documents` table, chunk the `content`, embed the chunks. That’s the whole pipeline — literally an array of steps.

And then run the pipeline!

That’s it. 

Behind the scenes, our docs just got chunked, embedded, and dropped into a vector-ready sink table.

To make it easier to see, I created the custom dashboard to visualize the pipelines and the steps. Let's check it out. 

As you can see here, a pipeline was kicked off to do several steps, Behind the scenes, to chunk and embed. Most notably, the embedding took the longest time. Let's look into it. 

We can also see all the chunks that are created and embedded. 


Let's go back into VS Code and do a vector search.  

I'm going to search for wireless headphones for travel and focus work. Let's see what gets returned. 

As you can see, it returns the chunked text that matched this similarity, so we know it all worked. 
---

## ACT 2 — Auto-Embedding on New Rows (30 seconds)

**[Screen: insert new row, then query sink/checkpoint]**

Now here’s the part I really want to show you. 

I'm going to go ahead and add a new row about Apple AirPods, and let's see what happens with the pipeline. 

Pretty boring INSERT, right? Except… that row is already on its way to being chunked and embedded. Because we said `trigger => 'on_change'` with an incremental column, the pipeline notices the new row and processes only that one. Not the whole table. Just the delta.

So think about what we’ve actually built here: a self-maintaining vector index. You write to your table the way you always have, and your embeddings just stay current. That’s it. That’s the loop.

---

## ACT 3 — What Else Can Pipelines Do? (45 seconds)

**[Screen: quick list of step options]**

And RAG is honestly just the opening move. Because each step is just an entry in an array, you can compose much richer workflows:

- Drop in an **approval** step and the pipeline literally pauses, waiting for a human to sign off.
- Mix in **extraction** and **generation** to enrich, summarize, or classify on the way through.
- Add **parallel branches** to fan out across models or sources, then fan back in.
- Wire it to a **schedule** or an **event** so it just runs itself.

Same SQL. Same durable graph. Same crash safety. You’re just adding lines to an array.

---

## OUTRO (15 seconds)

And there you have it. AI pipelines that read like SQL, update incrementally as your data changes all running inside the database you already have. These pipelines also support other complex actions such as data enrichment, approvals, parallel branching, job scheduling, and more. Everything you need to run a production-grade AI pipeline. 
