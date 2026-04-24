# Demo Script 2: AI Pipeline Highlights in PostgreSQL with pg_durable

> **Format:** Video walkthrough / live demo narration
> **Duration:** ~2 minutes 30 seconds
> **Audience:** Developers and data engineers familiar with PostgreSQL
> **Demo file:** `sql/ai/demo_rag_pipeline.sql`

---

## INTRO (20 seconds)

**[Screen: psql terminal + docs table]**


Hey folks, my name is Abe Omorogbe, and I'm a PM on the Azure Postgres AI team. 

Today i'll be using AI Pipelines in HorizonDB to show you how little SQL it takes to stand up a real RAG pipeline — this includes chunking, embeddings, the whole thing — directly inside PostgreSQL. 

No external orchseration. No glue code. just Postgres.

---

## ACT 1 — RAG Pipeline in Seconds (60 seconds)

**[Screen: show pipeline definition]**

So here’s our starting point — the most boring table in the world. Some documents:

```sql
CREATE TABLE documents (
    id          SERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    content     TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

And let's drop in a few real-looking products so this feels like an actual store catalog. Think of `title` as the product name and `content` as the marketing description:

```sql
INSERT INTO documents (title, content) VALUES
    ('Sony WH-1000XM5 Wireless Headphones',
     'Premium over-ear headphones with industry-leading active noise '
     'cancellation, 30-hour battery life, multipoint Bluetooth, and '
     'crystal-clear hands-free calling. Lightweight design ideal for '
     'travel, daily commutes, and focused work sessions.'),
    ('Keychron Q1 Pro Mechanical Keyboard',
     'Wireless 75% mechanical keyboard with hot-swappable switches, '
     'aluminum CNC body, double-shot PBT keycaps, QMK/VIA support, and '
     'per-key RGB. A favorite of developers who want a tactile, '
     'customizable typing experience for long coding sessions.'),
    ('Uplift V2 Standing Desk',
     'Electric height-adjustable standing desk with a 355 lb lift '
     'capacity, whisper-quiet dual motors, programmable height presets, '
     'and a solid bamboo top. Built for ergonomic home offices and '
     'long workdays at the keyboard.'),
    ('Logitech MX Master 3S Mouse',
     'Ergonomic wireless productivity mouse with an 8K DPI sensor, '
     'silent clicks, MagSpeed electromagnetic scrolling, and seamless '
     'multi-device switching across laptops and desktops. A staple for '
     'developers, designers, and power users.'),
    ('Anker 737 GaNPrime 120W Charger',
     'Compact three-port USB-C and USB-A wall charger using GaN tech to '
     'deliver up to 120W total. Charges a MacBook Pro, phone, and '
     'headphones at the same time, making it perfect for travel and '
     'small desk setups.');
```

Now watch what happens when I declare a pipeline on top of it:

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

Read that like a sentence: take `documents`, chunk the `content`, embed the chunks. That’s the whole pipeline — literally an array of steps.

And one more:

```sql
SELECT ai.run('rag_pipeline');
```

That’s it. Behind the scenes, our docs just got chunked, embedded, and dropped into a vector-ready sink table. Using the Durable Functions from pg_durable to ensure these pipeline as fault tolerant and long running.

To make it easier to see, I created a custom dashboard to visualize the pipelines and the steps. Let's check it out. 

As you can see here, a pipeline was kicked off to do several steps. Let me just click into one of the boxes here. You can see it has a chunk in and where it got chunked to and everything got processed. Let's go back into VS Code and do a vector search. 

Already now let see if it worked

```sql
-- Semantic search: embed the user's question, then find the closest chunks

SELECT doc_id, title, content, chunk_index
     from documents
     order by embeddings <=> azure_openai.create_embeddings(
                                'text-embedding-3-small',
                                'wireless headphones for travel and focused work')::vector asc
     limit 5;
```

---

## ACT 2 — Auto-Embedding on New Rows (30 seconds)

**[Screen: insert new row, then query sink/checkpoint]**

Now here’s the part I really want you to see. I’m going to do the most mundane thing imaginable — just add a new product to the catalog:

```sql
INSERT INTO documents (title, content)
VALUES (
    'Apple AirPods Pro (2nd Gen, USB-C)',
    'Active noise-cancelling wireless earbuds with adaptive transparency, '
    'personalized spatial audio, USB-C MagSafe charging case, and up to '
    '6 hours of listening time per charge. Tuned for music, calls, and '
    'all-day wear.'
);
```

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

Let me quickly show you. 

---

## OUTRO (15 seconds)

So that’s the whole pitch in two and a half minutes: AI pipelines that read like SQL, update incrementally as your data changes, and survive whatever production throws at them — all running inside the database you already have.

If you can write a `SELECT`, you can ship a RAG pipeline. Try it.
