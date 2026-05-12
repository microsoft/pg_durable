-- =============================================================================
-- ai.search() — Unified Multi-Modal Search for PostgreSQL
-- Azure Database for PostgreSQL
-- =============================================================================
--
-- A single function that gives users vector search, full-text search,
-- and hybrid search (vector + fulltext fused via Reciprocal Rank Fusion).
--
-- Usage:
--   SELECT * FROM ai.search('how do I scale PostgreSQL?');
--   SELECT * FROM ai.search('replication lag', search_type => 'fulltext');
--   SELECT * FROM ai.search('backup strategy', search_type => 'vector');
--   SELECT * FROM ai.search('disaster recovery', top_k => 5);
--   SELECT * FROM ai.search('vector index', rerank => false);
--   SELECT * FROM ai.search('RAG pipeline',
--       embedding_model => 'text-embedding-3-large',
--       rerank_model    => 'gpt-4.1');
--
-- Prerequisites:
--   1. Azure Database for PostgreSQL (Flexible Server)
--   2. Extensions: vector, azure_ai
--   3. Azure AI model endpoints configured via azure_ai.set_setting()
--      (for embeddings and reranking)
-- =============================================================================

-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- SECTION 0: Extension Setup
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS azure_ai;

SELECT azure_ai.set_setting('azure_openai.endpoint', 'https://abes-demo-ai-foundry.openai.azure.com/');
SELECT azure_ai.set_setting('azure_openai.subscription_key', '<YOUR_AZURE_OPENAI_KEY>');

SET search_path = public, "$user";

CREATE SCHEMA IF NOT EXISTS ai;

-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- SECTION 1: Sample Knowledge Base for Testing
-- A docs table with content and embeddings
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

DROP TABLE IF EXISTS knowledge_base CASCADE;

CREATE TABLE knowledge_base (
    id        SERIAL PRIMARY KEY,
    title     TEXT NOT NULL,
    content   TEXT NOT NULL,
    category  TEXT,
    embedding vector(1536)   -- azure_ai / OpenAI embedding dimension
);

-- ---------------------------------------------------------------------------
-- Sample documents (embeddings would be generated via azure_openai.create_embeddings)
-- ---------------------------------------------------------------------------

INSERT INTO knowledge_base (title, content, category) VALUES
    ('PostgreSQL Replication Overview',
     'PostgreSQL supports streaming replication for high availability. Primary servers send WAL records to standby servers in real time. Synchronous replication guarantees zero data loss at the cost of higher latency.',
     'high-availability'),

    ('Replication Slot Management',
     'Replication slots ensure standby servers do not miss WAL segments. However, inactive slots can cause WAL accumulation and disk pressure. Monitor pg_replication_slots and drop unused slots promptly.',
     'high-availability'),

    ('Backup and Point-in-Time Recovery',
     'Use pg_basebackup for physical backups and continuous WAL archiving for point-in-time recovery (PITR). Combine with pg_dump for logical, schema-level backups. Test restores regularly.',
     'disaster-recovery'),

    ('Connection Pooling with PgBouncer',
     'PgBouncer reduces connection overhead by pooling database connections. Transaction-level pooling offers the best balance of concurrency and resource usage for most workloads.',
     'performance'),

    ('Scaling Read Workloads with Read Replicas',
     'Read replicas distribute SELECT queries across multiple standbys. Use connection routing at the application layer or with a proxy like PgBouncer to balance load across replicas.',
     'scalability'),

    ('Disaster Recovery Planning',
     'A complete DR plan combines streaming replication for failover, WAL archiving for PITR, and regular pg_dump exports for cross-region portability. Test failover runbooks quarterly.',
     'disaster-recovery'),

    ('Vector Search with pgvector',
     'The pgvector extension adds vector data types and similarity operators to PostgreSQL. Use cosine distance (<=>), inner product (<#>), and L2 distance (<->) for nearest-neighbor search. Create HNSW or IVFFlat indexes for fast approximate retrieval.',
     'ai-search'),

    ('Full-Text Search in PostgreSQL',
     'PostgreSQL provides built-in full-text search with tsvector and tsquery types. Create GIN indexes on tsvector columns for fast matching. Supports ranking with ts_rank, websearch_to_tsquery for natural language queries, and multiple language configurations.',
     'ai-search'),

    ('Hybrid Search: Combining Vector and Keyword',
     'Neither vector search nor keyword search is universally best. Vector search captures semantic similarity; keyword search captures exact term matches. Reciprocal Rank Fusion (RRF) merges ranked lists from both approaches into a single, superior ranking.',
     'ai-search');

-- ---------------------------------------------------------------------------
-- Generate embeddings for every document (requires azure_ai endpoint config)
-- ---------------------------------------------------------------------------
UPDATE knowledge_base
SET embedding = azure_openai.create_embeddings(
    'text-embedding-3-small', content
)::vector
WHERE embedding IS NULL;


-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- SECTION 2: Indexes
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

-- GIN full-text index (standard PostgreSQL tsvector)
ALTER TABLE knowledge_base ADD COLUMN IF NOT EXISTS content_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;
CREATE INDEX kb_content_gin_idx ON knowledge_base USING gin (content_tsv);

-- HNSW vector index (pgvector) — cosine distance
CREATE INDEX kb_embedding_hnsw_idx ON knowledge_base
    USING hnsw (embedding vector_cosine_ops);

-- Reciprocal Rank Fusion (RRF) is applied inline inside ai.search.
-- RRF formula:  score(d) = Σ  1 / (k + rank_i(d))
-- where k = 60 (standard constant), and i iterates over each ranker.


-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- SECTION 3: ai.search()  — The Main Entry Point
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
--
-- Parameters:
--   query            text   — natural-language search query
--   source_table     text   — table to search (default 'knowledge_base')
--   search_type      text   — 'hybrid' | 'vector' | 'fulltext'
--   top_k            int    — number of results to return (default 10)
--   rrf_k            int    — RRF constant (default 60)
--   content_column   text   — column for fulltext search (auto-detected from GIN index)
--   embedding_column text   — column for vector search (auto-detected from vector index)
--   id_column        text   — primary key column (auto-detected)
--   title_column     text   — display label column (defaults to content_column)
--   embedding_model  text   — model for embeddings (default 'text-embedding-3-small')
--   rerank_model     text   — model for reranking (default 'gpt-4.1')
--   rerank           bool   — apply cross-encoder reranking (default false)
--   filter           text   — optional SQL WHERE clause fragment for pre-filtering
--
-- Column Auto-Detection:
--   Columns are discovered automatically from the indexes on source_table:
--     • Primary key         → id_column
--     • GIN index (tsvector) → content_column  (for fulltext/hybrid)
--     • Vector index         → embedding_column (for vector/hybrid)
--   Customers only need to create the right indexes. Override with explicit
--   parameters if the table has multiple indexes of the same type.
--
-- Returns:
--   id, title, content, score, match_type
--
-- Pipeline:
--   1. Auto-detect columns from indexes
--   2. Retrieve candidates via the chosen search strategy
--   3. (Optional) Rerank with azure_ai.rank() cross-encoder
--   4. Return top_k results
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

DROP FUNCTION IF EXISTS ai.search(text, text, int, int, int, text, text, boolean);
DROP FUNCTION IF EXISTS ai.search(text, text, text, int, int, int, text, text, text, text, text, text, boolean);
DROP FUNCTION IF EXISTS ai.search(text, text, text, int, int, text, text, text, text, text, text, boolean);
DROP FUNCTION IF EXISTS ai.search(text, text, text, int, int, text, text, text, text, text, text, boolean, text);
CREATE OR REPLACE FUNCTION ai.search(
    query            text,
    source_table     text    DEFAULT 'knowledge_base',
    search_type      text    DEFAULT 'hybrid',
    top_k            int     DEFAULT 10,
    rrf_k            int     DEFAULT 60,
    content_column   text    DEFAULT NULL,  -- auto-detected from GIN index
    embedding_column text    DEFAULT NULL,  -- auto-detected from vector index
    id_column        text    DEFAULT NULL,  -- auto-detected from primary key
    title_column     text    DEFAULT NULL,  -- defaults to content_column
    embedding_model  text    DEFAULT 'text-embedding-3-small',
    rerank_model     text    DEFAULT 'gpt-4.1',
    rerank           boolean DEFAULT false,
    filter           text    DEFAULT NULL   -- optional WHERE clause fragment for pre-filtering
)
RETURNS TABLE (
    id          int,
    title       text,
    content     text,
    score       real,
    match_type  text
)
LANGUAGE plpgsql
VOLATILE   -- calls external AI endpoints (embeddings, reranker)
SET search_path = public, "$user"
AS $$
DECLARE
    query_embedding  vector(1536);
    fetch_limit      int := CASE WHEN rerank THEN top_k * 3 ELSE top_k END;
    _start_ts        timestamptz;
    _phase_ts        timestamptz;
    _candidate_cnt   int;
    -- Resolved column names (from params or auto-detection)
    _tbl             text;
    _id_col          text;
    _title_col       text;
    _content_col     text;
    _emb_col         text;
    _filter_clause   text;
BEGIN
    _start_ts := clock_timestamp();
    _phase_ts := _start_ts;
    _tbl := source_table;

    -- Build filter clause
    IF filter IS NOT NULL THEN
        _filter_clause := ' AND (' || filter || ')';
    ELSE
        _filter_clause := '';
    END IF;

    -- =================================================================
    -- Column Auto-Detection from Indexes
    -- =================================================================
    -- Customers create their table with the right indexes and ai.search()
    -- figures out which columns to use. No configuration needed.
    --
    --   CREATE TABLE my_docs (
    --       doc_id   serial PRIMARY KEY,
    --       body     text,
    --       body_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', body)) STORED,
    --       vec      vector(1536)
    --   );
    --   CREATE INDEX ON my_docs USING gin (body_tsv);                  -- → content
    --   CREATE INDEX ON my_docs USING hnsw (vec vector_cosine_ops); -- → embedding
    --
    --   SELECT * FROM ai.search('query', source_table => 'my_docs');
    -- =================================================================

    -- Primary key → id_column
    _id_col := id_column;
    IF _id_col IS NULL THEN
        SELECT a.attname INTO _id_col
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = _tbl::regclass AND i.indisprimary
        LIMIT 1;
    END IF;

    -- GIN (tsvector) index → content_column
    _content_col := content_column;
    IF _content_col IS NULL THEN
        -- Look for a GIN index on a tsvector column; use the source column name
        SELECT a.attname INTO _content_col
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am am ON am.oid = c.relam
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = _tbl::regclass AND am.amname = 'gin'
              AND EXISTS (SELECT 1 FROM pg_type t WHERE t.oid = a.atttypid AND t.typname = 'tsvector')
        LIMIT 1;
        -- Strip _tsv suffix to get the real content column
        IF _content_col IS NOT NULL AND _content_col LIKE '%_tsv' THEN
            _content_col := left(_content_col, length(_content_col) - 4);
        END IF;
    END IF;

    -- Vector index (diskann/hnsw/ivfflat) → embedding_column
    _emb_col := embedding_column;
    IF _emb_col IS NULL THEN
        SELECT a.attname INTO _emb_col
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am am ON am.oid = c.relam
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = _tbl::regclass AND am.amname IN ('diskann', 'hnsw', 'ivfflat')
        LIMIT 1;
    END IF;

    -- Title defaults to content column if not specified
    _title_col := COALESCE(title_column, _content_col);

    RAISE NOTICE '[ai.search] START  query=% type=% top_k=% rerank=%',
        left(query, 80), search_type, top_k, rerank;
    RAISE NOTICE '[ai.search] AUTO-DETECT  table=% id=% title=% content=% embedding=%',
        _tbl, _id_col, _title_col, _content_col, _emb_col;

    -- Validate we found what we need
    IF _id_col IS NULL THEN
        RAISE EXCEPTION 'No primary key on "%" — specify id_column.', _tbl;
    END IF;
    IF _content_col IS NULL AND search_type IN ('fulltext', 'hybrid') THEN
        RAISE EXCEPTION 'No full-text (GIN) index on "%" — create one or specify content_column.', _tbl;
    END IF;
    IF _emb_col IS NULL AND search_type IN ('vector', 'hybrid') THEN
        RAISE EXCEPTION 'No vector index on "%" — create one or specify embedding_column.', _tbl;
    END IF;

    -- =================================================================
    -- Phase 1: RETRIEVE candidates
    -- =================================================================

    -- Reset temp tablespace to use default data directory
    SET LOCAL temp_tablespaces = '';

    DROP TABLE IF EXISTS _search_candidates;
    CREATE TEMP TABLE _search_candidates (
        _id int, _title text, _content text, _score real, _match_type text
    ) ON COMMIT DROP;

    -- Generate query embedding when needed
    IF search_type IN ('vector', 'hybrid') THEN
        RAISE NOTICE '[ai.search] Generating embedding via % ...', embedding_model;
        query_embedding := azure_openai.create_embeddings(embedding_model, query)::vector;
        RAISE NOTICE '[ai.search] Embedding done  (+% ms)',
            extract(milliseconds from clock_timestamp() - _phase_ts)::int;
        _phase_ts := clock_timestamp();
    END IF;

    -- -----------------------------------------------------------------
    -- Route to the requested search strategy
    -- -----------------------------------------------------------------

    IF search_type = 'vector' THEN
        -- ============================================================
        -- VECTOR SEARCH: cosine similarity via pgvector
        -- ============================================================
        EXECUTE format(
            'INSERT INTO _search_candidates
             SELECT %I, %I, %I,
                    (1 - (%I <=> $1))::real,
                    ''vector''::text
             FROM %I
             WHERE %I IS NOT NULL' || _filter_clause || '
             ORDER BY %I <=> $1
             LIMIT $2',
            _id_col, _title_col, _content_col,
            _emb_col,
            _tbl,
            _emb_col,
            _emb_col
        ) USING query_embedding, fetch_limit;
        GET DIAGNOSTICS _candidate_cnt = ROW_COUNT;
        RAISE NOTICE '[ai.search] Vector search found % candidates  (+% ms)',
            _candidate_cnt, extract(milliseconds from clock_timestamp() - _phase_ts)::int;
        _phase_ts := clock_timestamp();

    ELSIF search_type = 'fulltext' THEN
        -- ============================================================
        -- FULL-TEXT SEARCH: standard PostgreSQL tsvector/tsquery
        -- ============================================================
        EXECUTE format(
            'INSERT INTO _search_candidates
             SELECT sub._id, sub._title, sub._content,
                    sub.rank_score::real, ''fulltext''::text
             FROM (
                 SELECT %I AS _id, %I AS _title, %I AS _content,
                        ts_rank_cd(to_tsvector(''english'', %I), websearch_to_tsquery(''english'', $2)) AS rank_score
                 FROM %I
                 WHERE to_tsvector(''english'', %I) @@ websearch_to_tsquery(''english'', $2)' || _filter_clause || '
                 ORDER BY rank_score DESC
                 LIMIT $1
             ) sub',
            _id_col, _title_col, _content_col,
            _content_col,
            _tbl,
            _content_col
        ) USING fetch_limit, query;
        GET DIAGNOSTICS _candidate_cnt = ROW_COUNT;
        RAISE NOTICE '[ai.search] Fulltext search found % candidates  (+% ms)',
            _candidate_cnt, extract(milliseconds from clock_timestamp() - _phase_ts)::int;
        _phase_ts := clock_timestamp();

    ELSIF search_type = 'hybrid' THEN
        -- ============================================================
        -- HYBRID SEARCH: Vector + FullText, fused with RRF
        -- ============================================================

        DROP TABLE IF EXISTS _fulltext_ranked;
        CREATE TEMP TABLE _fulltext_ranked (doc_id int, rank int) ON COMMIT DROP;

        -- Fulltext ranker (standard PostgreSQL FTS)
        EXECUTE format(
            'INSERT INTO _fulltext_ranked (doc_id, rank)
             SELECT %I, ROW_NUMBER() OVER (ORDER BY ts_rank_cd(to_tsvector(''english'', %I), websearch_to_tsquery(''english'', $2)) DESC)::int
             FROM %I
             WHERE to_tsvector(''english'', %I) @@ websearch_to_tsquery(''english'', $2)' || _filter_clause || '
             LIMIT $1',
            _id_col, _content_col, _tbl, _content_col
        ) USING fetch_limit, query;
        GET DIAGNOSTICS _candidate_cnt = ROW_COUNT;
        RAISE NOTICE '[ai.search] Hybrid: fulltext ranker found % docs  (+% ms)',
            _candidate_cnt, extract(milliseconds from clock_timestamp() - _phase_ts)::int;
        _phase_ts := clock_timestamp();

        -- RRF fusion: vector + fulltext
        EXECUTE format($dyn$
            INSERT INTO _search_candidates
            WITH
            vector_ranked AS (
                SELECT %I AS doc_id,
                       ROW_NUMBER() OVER (ORDER BY %I <=> $1)::int AS rank
                FROM %I
                WHERE %I IS NOT NULL %s
                ORDER BY %I <=> $1
                LIMIT $2
            ),
            all_docs AS (
                SELECT doc_id FROM vector_ranked
                UNION
                SELECT doc_id FROM _fulltext_ranked
            ),
            rrf_scores AS (
                SELECT ad.doc_id,
                       (COALESCE(1.0 / ($3 + vr.rank), 0) +
                        COALESCE(1.0 / ($3 + fr.rank), 0))::real AS fused_score
                FROM all_docs ad
                LEFT JOIN vector_ranked        vr ON vr.doc_id = ad.doc_id
                LEFT JOIN _fulltext_ranked     fr ON fr.doc_id = ad.doc_id
            )
            SELECT %I, %I, %I, rrf.fused_score, 'hybrid'::text
            FROM rrf_scores rrf
            JOIN %I ON %I = rrf.doc_id
            ORDER BY rrf.fused_score DESC
            LIMIT $2
        $dyn$,
            -- vector_ranked references
            _id_col, _emb_col, _tbl, _emb_col, _filter_clause, _emb_col,
            -- final SELECT + JOIN references
            _id_col, _title_col, _content_col, _tbl, _id_col
        ) USING query_embedding, fetch_limit, rrf_k;
        GET DIAGNOSTICS _candidate_cnt = ROW_COUNT;
        RAISE NOTICE '[ai.search] Hybrid: RRF fusion produced % candidates  (+% ms)',
            _candidate_cnt, extract(milliseconds from clock_timestamp() - _phase_ts)::int;
        _phase_ts := clock_timestamp();

    ELSE
        RAISE EXCEPTION 'Unknown search_type: %. Use hybrid, vector, or fulltext.', search_type;
    END IF;

    -- =================================================================
    -- Phase 2: RERANK (optional)
    -- =================================================================

    IF rerank THEN
        RAISE NOTICE '[ai.search] Reranking % candidates via % ...',
            (SELECT count(*) FROM _search_candidates), rerank_model;
        _phase_ts := clock_timestamp();
        RETURN QUERY
        SELECT
            c._id,
            c._title,
            c._content,
            (rr.score)::real    AS score,
            c._match_type
        FROM _search_candidates c
        JOIN (
            SELECT *
            FROM azure_ai.rank(
                query              => search.query,
                document_contents  => (SELECT array_agg(sc._content ORDER BY sc._score DESC)
                                       FROM _search_candidates sc),
                document_ids       => (SELECT array_agg(sc._id::text ORDER BY sc._score DESC)
                                       FROM _search_candidates sc),
                model              => rerank_model
            )
        ) rr ON rr.id = c._id::text
        ORDER BY rr.score DESC
        LIMIT top_k;
        RAISE NOTICE '[ai.search] Rerank done  (+% ms)',
            extract(milliseconds from clock_timestamp() - _phase_ts)::int;
    ELSE
        RETURN QUERY
        SELECT c._id, c._title, c._content, c._score, c._match_type
        FROM _search_candidates c
        ORDER BY c._score DESC
        LIMIT top_k;
    END IF;

    RAISE NOTICE '[ai.search] DONE  total=% ms',
        extract(milliseconds from clock_timestamp() - _start_ts)::int;
END;
$$;

COMMENT ON FUNCTION ai.search(text, text, text, int, int, text, text, text, text, text, text, boolean, text) IS
'Unified search over any table. Auto-detects columns from indexes: '
'primary key → id, GIN (tsvector) index → content, vector index → embedding. '
'Supports vector, fulltext, and hybrid (RRF) search with optional pre-filtering. '
'Optionally reranks with azure_ai.rank(). Just point it at your table: '
'SELECT * FROM ai.search(''query'', source_table => ''my_docs'');';


-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- SECTION 4: Example Queries
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

-- 4a. Default: searches 'knowledge_base' — columns auto-detected from indexes
SELECT * FROM ai.search(
    'how do I set up disaster recovery for PostgreSQL?',
    rerank => false
);

-- 4b. Vector-only search (auto-detects embedding column from vector index)
SELECT * FROM ai.search(
    'scaling read-heavy workloads',
    search_type => 'vector',
    rerank => false
);

-- 4c. Full-text only (auto-detects content column from GIN tsvector index)
SELECT * FROM ai.search(
    'replication slots WAL',
    search_type => 'fulltext',
    rerank => false
);

-- 4d. Point at a different table — columns auto-detected from its indexes
--     (Requires: my_articles table with GIN + vector indexes)
-- SELECT * FROM ai.search(
--     'machine learning pipelines',
--     source_table => 'my_articles'
-- );

-- 4e. Override specific columns (when auto-detection picks wrong one)
-- SELECT * FROM ai.search(
--     'machine learning pipelines',
--     source_table     => 'articles',
--     content_column   => 'body',
--     embedding_column => 'body_vec',
--     title_column     => 'headline'
-- );


-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- SECTION 5: How It Works — Quick Reference
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │                  ai.search(query)                           │
-- │                                                             │
-- │  ┌──────────────────┐  ┌──────────────────┐                │
-- │  │     Vector        │  │    Full-Text     │                │
-- │  │    (pgvector)     │  │   (tsvector)     │                │
-- │  │                   │  │                  │                │
-- │  │  cosine            │  │  ts_rank         │                │
-- │  │  similarity        │  │  scoring         │                │
-- │  └────────┬──────────┘  └────────┬─────────┘                │
-- │           │                      │                          │
-- │           ▼                      ▼                          │
-- │  ┌───────────────────────────────────────────────────┐     │
-- │  │         Reciprocal Rank Fusion (RRF)              │     │
-- │  │                                                   │     │
-- │  │   score(d) = Σ  1 / (60 + rank_i(d))            │     │
-- │  └───────────────────────┬───────────────────────────┘     │
-- │                          │                                 │
-- │                          ▼                                 │
-- │  ┌───────────────────────────────────────────────────┐     │
-- │  │         Cross-Encoder Reranker                    │     │
-- │  │         (azure_ai.rank)                           │     │
-- │  │                                                   │     │
-- │  │   • Cohere Rerank v3.5 (default) or GPT-based    │     │
-- │  │   • Fine-grained query–document scoring           │     │
-- │  │   • Catches subtleties keyword/vector miss        │     │
-- │  └───────────────────────┬───────────────────────────┘     │
-- │                          │                                 │
-- │                          ▼                                 │
-- │                   Top-K results                            │
-- │              (id, title, content, score)                   │
-- └─────────────────────────────────────────────────────────────┘
--
-- Search types:
--   'hybrid'          → vector + fulltext RRF + rerank (default)
--   'vector'          → cosine similarity + rerank (requires embeddings)
--   'fulltext'        → keyword ranking + rerank
--
-- Reranking (default on):
--   After initial retrieval, azure_ai.rank() re-scores each candidate
--   with a cross-encoder model for fine-grained relevance.
--   Disable with: rerank => false
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░


-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- SECTION 6: setup_index_for_search()
-- Enrich a pipeline output table so it works with ai.search().
-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

CREATE OR REPLACE FUNCTION public.setup_index_for_search(tbl TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- 1. Add category and populate from source
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS category TEXT', tbl);
    EXECUTE format('UPDATE %I o SET category = p.category FROM product_sample p WHERE p.id = o.doc_id', tbl);

    -- 2. Add id PK and set id = doc_id
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = tbl AND column_name = 'id'
    ) THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN id SERIAL PRIMARY KEY', tbl);
    END IF;
    EXECUTE format('UPDATE %I SET id = doc_id', tbl);

    -- 3. Add indexes for ai.search()
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS title_tsv tsvector GENERATED ALWAYS AS (to_tsvector(''english'', coalesce(chunk_text, ''''))) STORED', tbl);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_fts ON public.%I USING gin (title_tsv)', tbl, tbl);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_hnsw ON public.%I USING hnsw (embedding vector_cosine_ops)', tbl, tbl);
END;
$$;
