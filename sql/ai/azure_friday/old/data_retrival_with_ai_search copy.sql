
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- DATA RETRIEVAL: Real Queries for Roommate UI Demo
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

-- =============================================================================
-- SETUP: Full-Text Search Index (standard PostgreSQL)
-- =============================================================================

ALTER TABLE product_sample ADD COLUMN IF NOT EXISTS title_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(store, ''))) STORED;

CREATE INDEX IF NOT EXISTS idx_product_sample_fts ON public.product_sample
USING gin (title_tsv);

CREATE INDEX IF NOT EXISTS idx_product_sample_hnsw   ON public.product_sample 
USING hnsw (embedding vector_cosine_ops);

-- =============================================================================
-- SETUP: Add category calling for extra filtering. This could be done in the data ingestion step, but we don't have the carry_column in the future yet. 
-- =============================================================================
ALTER TABLE product_rag_pipeline_output ADD COLUMN IF NOT EXISTS category TEXT;

UPDATE product_rag_pipeline_output o
SET category = p.category
FROM product_sample p
WHERE p.id = o.doc_id;

-- =============================================================================
-- Room Analysis: azure_ai.generate() with image URL
-- Describes the room photo to identify style, furniture, colors, and gaps
-- =============================================================================

-- SELECT azure_ai.generate(
--   'Analyze this living room photo. https://i.ibb.co/p61fm20N/Designer-7.png
--   give a semantic description of the room'
-- );

-- =============================================================================
-- Product Search: ai.search() with semantic ranking and category filters
-- Searches for furniture and decor matching the room design query
-- =============================================================================

SET app.search_query = 
'mid-century modern furniture for Brooklyn loft living room with wood tones and dark vibe';

-- 1. Seating
SELECT product.title, product.price_num as price, search.score
FROM ai.search(current_setting('app.search_query'),
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    filter => 'category = ''Chairs''') search
JOIN product_rag_pipeline_output output ON output.id = search.id
JOIN product_sample product ON product.id = output.doc_id

-- 2. Tables
SELECT product.title, product.price_num as price, search.score
FROM ai.search(current_setting('app.search_query'),
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    filter => 'category = ''Coffee Tables''') search
JOIN product_rag_pipeline_output output ON output.id = search.id
JOIN product_sample product ON product.id = output.doc_id;

-- 3. Lighting
SELECT product.title, product.price_num as price, search.score
FROM ai.search(current_setting('app.search_query'),
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    filter => 'category = ''Lamps & Lighting''') search
JOIN product_rag_pipeline_output output ON output.id = search.id
JOIN product_sample product ON product.id = output.doc_id;

-- 4. Rugs
SELECT product.title, product.price_num as price, search.score
FROM ai.search(current_setting('app.search_query'),
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    filter => 'category = ''Area Rugs''') search
JOIN product_rag_pipeline_output output ON output.id = search.id
JOIN product_sample product ON product.id = output.doc_id;

-- 5. Storage
SELECT product.title, product.price_num as price, search.score
FROM ai.search(current_setting('app.search_query'),
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    filter => 'category = ''Bookcases''') search
JOIN product_rag_pipeline_output output ON output.id = search.id
JOIN product_sample product ON product.id = output.doc_id;

-- 6. Decor and art
SELECT product.title, product.price_num as price, search.score
FROM ai.search(current_setting('app.search_query'),
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    filter => 'category = ''Wall Art''') search
JOIN product_rag_pipeline_output output ON output.id = search.id
JOIN product_sample product ON product.id = output.doc_id;



-- =============================================================================
-- Manual Hybrid Search 
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS azure_ai;

SELECT azure_ai.set_setting('azure_openai.endpoint', 'https://abes-demo-ai-foundry.openai.azure.com/');
SELECT azure_ai.set_setting('azure_openai.subscription_key', '<YOUR_AZURE_OPENAI_KEY>');

WITH fulltext_results AS (
    SELECT id, ROW_NUMBER() OVER (
        ORDER BY ts_rank_cd(title_tsv, websearch_to_tsquery('english',
            'mid-century modern furniture for Brooklyn loft living room with wood tones and dark vibe')) DESC
    ) AS ft_rank
    FROM product_sample
    WHERE title_tsv @@ websearch_to_tsquery('english',
        'mid-century modern furniture for Brooklyn loft living room with wood tones and dark vibe')
    LIMIT 20
),
vector_results AS (
    SELECT id,
           ROW_NUMBER() OVER (
               ORDER BY embedding <=> azure_openai.create_embeddings(
        'text-embedding-3-small',
        'mid-century modern furniture for Brooklyn loft living room with wood tones and dark vibe')::vector
           ) AS vec_rank
    FROM product_sample
    ORDER BY embedding <=> azure_openai.create_embeddings(
        'text-embedding-3-small',
        'mid-century modern furniture for Brooklyn loft living room with wood tones and dark vibe')::vector
    LIMIT 20
)
SELECT COALESCE(f.id, v.id) AS id,
       (1.0 / (60 + COALESCE(f.ft_rank, 999))) +
       (1.0 / (60 + COALESCE(v.vec_rank, 999))) AS rrf_score
FROM fulltext_results f
FULL OUTER JOIN vector_results v ON f.id = v.id
ORDER BY rrf_score DESC
LIMIT 10;