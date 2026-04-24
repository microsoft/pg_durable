-- =============================================================================
-- Demo Script 2 — AI Pipeline Highlights (short, ~2:30 walkthrough)
-- Companion to: docs/demo-rag-pipeline-script-short.md
--
-- Paste each section in psql as you narrate. Names match the script
-- exactly (table = documents, pipeline = rag_pipeline) so copy/paste works.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- ACT 1 — RAG Pipeline in Seconds
-- ---------------------------------------------------------------------------

-- 1a. The "most boring table in the world": a product catalog.
DROP TABLE IF EXISTS documents CASCADE;
CREATE TABLE documents (
    id          SERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    content     TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 1b. Drop in five real-looking products. `title` = product name,
--     `content` = marketing description that will get chunked + embedded.
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

-- 1c. Declare the pipeline. Read it like a sentence:
--     take `documents`, chunk the `content`, embed the chunks.
-- (Uncomment if you've created it before in this DB.)
-- SELECT ai.drop('rag_pipeline');

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
-- Auto-creates: public.rag_pipeline_output (doc_id, chunk_index, chunk_text, embedding, ...)

-- 1d. Run it once to backfill the existing rows.
SELECT ai.run('rag_pipeline');

-- 1e. semantic search against the catalog.
SELECT doc_id, title as product_name, content, chunk_index
     from documents
     order by embeddings <=> azure_openai.create_embeddings(
                                'text-embedding-3-small',
                                'wireless headphones for travel and focused work')::vector asc
     limit 5;

-- ---------------------------------------------------------------------------
-- ACT 2 — Auto-Embedding on New Rows
-- ---------------------------------------------------------------------------

-- 2a. The most mundane thing imaginable: just add a new product.
--     Because trigger => 'on_change' + incremental_column => 'updated_at',
--     ONLY this row gets chunked and embedded — not the whole table.
INSERT INTO documents (title, content)
VALUES (
    'Apple AirPods Pro (2nd Gen, USB-C)',
    'Active noise-cancelling wireless earbuds with adaptive transparency, '
    'personalized spatial audio, USB-C MagSafe charging case, and up to '
    '6 hours of listening time per charge. Tuned for music, calls, and '
    'all-day wear.'
);

-- 2b. Watch the new doc show up in the sink table within a few seconds.
--     Re-run this a couple of times during the narration.
SELECT doc_id, title, chunk_index, left(chunk_text, 80) AS chunk_preview
     from documents
     order by embeddings <=> azure_openai.create_embeddings(
                                'text-embedding-3-small',
                                'wireless headphones for travel and focused work')::vector asc
     WHERE title = 'Apple AirPods Pro (2nd Gen, USB-C)'
     ORDER BY chunk_index;

-- ---------------------------------------------------------------------------
-- ACT 3 — Production Reliability: Crash Recovery
-- ---------------------------------------------------------------------------

-- 3a. Every pipeline run is a durable function instance. Show the most
--     recent ones — this is what survives a Postgres restart.
SELECT instance_id, label, status, execution_count, output
FROM df.list_instances(NULL, 5);

-- 3b. Drill into the node-level state for the latest run. After a crash,
--     execution resumes from the last completed node (no re-chunking,
--     no re-embedding, no duplicate API calls).
WITH latest AS (
    SELECT instance_id
    FROM df.list_instances(NULL, 1)
    LIMIT 1
)
SELECT execution_id, node_id, node_type, status, updated_at
FROM df.instance_nodes((SELECT instance_id FROM latest), 1)
ORDER BY node_id;


-- ---------------------------------------------------------------------------
-- ACT 4 — What Else Can Pipelines Do?  (talking-point reference, not run)
-- ---------------------------------------------------------------------------
-- Same array. Same durable graph. Same crash safety. Just more steps:

SELECT ai.create_pipeline(
    name    => 'rag_pipeline_plus',
    source  => ai.table_source('documents', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input_column => 'content'),

        -- Enrichment: pull structured fields out of the chunk.
        ai.extract(
                model        => 'gpt-5-mini',
                input_column => 'chunk_text',
                data         => ARRAY[
                    'category: product category (audio, input, furniture, power, accessory)',
                    'audience: who this product is for',
                    'price_tier: budget/mid/premium'
                ]
        ),

        -- Human-in-the-loop: pipeline literally pauses here until approved.
        ai.request_approval(content => 'chunk_text', timeout => 3600),

        -- Embeddings for retrieval.
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text',
                     dimensions => 1536),

        -- Generation: e.g. SEO blurb or summary.
        ai.generate(
            model           => 'gpt-5-mini',
            input_column    => 'chunk_text',
            prompt_template => 'Write a one-sentence customer-friendly summary of: {chunk_text}'
            )
        ],
        trigger => 'on_change'
    );

    -- Parallel branches, schedules, and event triggers all compose the same way.

-- ---------------------------------------------------------------------------
-- (Optional) Cleanup
-- ---------------------------------------------------------------------------

-- SELECT ai.drop('rag_pipeline');
-- DROP TABLE IF EXISTS documents CASCADE;
