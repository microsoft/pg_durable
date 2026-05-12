-- =============================================================================
-- AI Pipeline Functions for pg_durable
-- =============================================================================
--
-- Declarative AI pipeline layer built on top of pg_durable's durable execution
-- runtime. Translates high-level AI pipeline definitions (chunk, embed, extract,
-- generate) into pg_durable orchestration graphs (df.start, df.sql, ~>, &, |=>).
--
-- Usage:
--   SELECT ai.create_pipeline(
--       name   => 'rag_pipeline',
--       source => ai.table_source('documents', incremental_column => 'updated_at'),
--       steps  => ARRAY[
--           ai.chunk(input_column => 'content'),
--           ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text')
--       ],
--       sink   => ai.table_sink('document_vectors'),
--       trigger => 'on_change'
--   );
--
--   SELECT * FROM ai.status('rag_pipeline');
--
-- Requires: pg_durable extension, azure_ai extension (for embedding/LLM calls),
--           dblink extension (for autonomous transactions in incremental embed)
-- =============================================================================

-- Schema
CREATE SCHEMA IF NOT EXISTS ai;

-- dblink is used by ai._embed_and_flush() for autonomous transactions
CREATE EXTENSION IF NOT EXISTS dblink;

-- Drop azure_ai extension functions whose signatures conflict with pg_durable
-- pipeline functions (same arg types but different param names or return types).
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.chunk(text,text,integer,integer);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.embed(text,text,integer,integer);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.list_pipelines();
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.drop_pipeline(text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.result(text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.status(text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.run(text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.pause(text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.resume(text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.backfill(text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.explain(text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.table_source(text,text,text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
    ALTER EXTENSION azure_ai DROP FUNCTION ai.table_sink(text,text,text[],text);
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DROP FUNCTION IF EXISTS ai.chunk(text,text,integer,integer);
DROP FUNCTION IF EXISTS ai.embed(text,text,integer,integer);
DROP FUNCTION IF EXISTS ai.list_pipelines();
DROP FUNCTION IF EXISTS ai.drop_pipeline(text);
DROP FUNCTION IF EXISTS ai.result(text);
DROP FUNCTION IF EXISTS ai.status(text);
DROP FUNCTION IF EXISTS ai.run(text);
DROP FUNCTION IF EXISTS ai.pause(text);
DROP FUNCTION IF EXISTS ai.resume(text);
DROP FUNCTION IF EXISTS ai.backfill(text);
DROP FUNCTION IF EXISTS ai.explain(text);
DROP FUNCTION IF EXISTS ai.table_source(text,text,text);
DROP FUNCTION IF EXISTS ai.table_sink(text,text,text[],text);

-- =============================================================================
-- 1. Pipeline registry table
-- =============================================================================

CREATE TABLE IF NOT EXISTS ai.pipelines (
    name            TEXT PRIMARY KEY,
    source_config   JSONB NOT NULL,
    steps           JSONB[] NOT NULL,
    sink_config     JSONB NOT NULL,
    trigger_type    TEXT NOT NULL DEFAULT 'manual',  -- manual | on_change | schedule
    options         JSONB NOT NULL DEFAULT '{}',
    created_by      TEXT NOT NULL DEFAULT current_user,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    paused          BOOLEAN NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS ai.pipeline_runs (
    id              BIGSERIAL PRIMARY KEY,
    pipeline_name   TEXT NOT NULL REFERENCES ai.pipelines(name) ON DELETE CASCADE,
    instance_id     TEXT,                -- df instance id from df.start()
    batch_start     TIMESTAMPTZ,
    batch_end       TIMESTAMPTZ,
    rows_processed  INT DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'pending',  -- pending | running | completed | failed
    error           TEXT,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ
);
-- Ensure columns exist when table was pre-created by azure_ai extension
ALTER TABLE ai.pipeline_runs ADD COLUMN IF NOT EXISTS instance_id TEXT;
ALTER TABLE ai.pipeline_runs ADD COLUMN IF NOT EXISTS batch_start TIMESTAMPTZ;
ALTER TABLE ai.pipeline_runs ADD COLUMN IF NOT EXISTS batch_end TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS ai.pipeline_checkpoints (
    pipeline_name   TEXT PRIMARY KEY REFERENCES ai.pipelines(name) ON DELETE CASCADE,
    last_value      TEXT,               -- last incremental column value processed
    last_run_at     TIMESTAMPTZ,
    total_processed BIGINT DEFAULT 0
);

CREATE TABLE IF NOT EXISTS ai.cost_log (
    id              BIGSERIAL PRIMARY KEY,
    pipeline_name   TEXT NOT NULL REFERENCES ai.pipelines(name) ON DELETE CASCADE,
    run_id          BIGINT REFERENCES ai.pipeline_runs(id) ON DELETE SET NULL,
    step_name       TEXT NOT NULL,
    model           TEXT,
    input_tokens    INT DEFAULT 0,
    output_tokens   INT DEFAULT 0,
    estimated_cost  NUMERIC(12,6) DEFAULT 0,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- 2. Source constructors — return JSONB descriptors
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.table_source(
    table_name          TEXT,
    incremental_column  TEXT DEFAULT NULL,
    schema_name         TEXT DEFAULT 'public',
    filter              TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'type',                 'table',
        'table_name',           table_name,
        'schema_name',          schema_name,
        'incremental_column',   incremental_column,
        'filter',               filter
    );
$$;


CREATE OR REPLACE FUNCTION ai.file_source(
    uri     TEXT,
    formats TEXT[] DEFAULT ARRAY['pdf', 'txt', 'md']
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'type',     'file',
        'uri',      uri,
        'formats',  to_jsonb(formats)
    );
$$;


-- =============================================================================
-- 3. Step constructors — return JSONB step descriptors
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.chunk(
    input        TEXT,
    method       TEXT DEFAULT 'recursive',
    chunk_size   INT DEFAULT 512,
    overlap      INT DEFAULT 64
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'step',         'chunk',
        'column',       input,
        'method',       method,
        'chunk_size',   chunk_size,
        'overlap',      overlap
    );
$$;


CREATE OR REPLACE FUNCTION ai.embed(
    model        TEXT,
    input_column TEXT,
    batch_size   INT DEFAULT 100,
    dimensions   INT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'step',         'embed',
        'model',        model,
        'column',       input_column,
        'batch_size',   batch_size,
        'dimensions',   dimensions
    );
$$;


CREATE OR REPLACE FUNCTION ai.extract(
    model        TEXT,
    input_column TEXT,
    data         TEXT[] DEFAULT NULL,
    fields       JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'step',     'extract',
        'model',    model,
        'column',   input_column,
        'data',     to_jsonb(data),
        'fields',   fields
    );
$$;


CREATE OR REPLACE FUNCTION ai.generate(
    model           TEXT,
    prompt_template TEXT,
    input_column    TEXT DEFAULT NULL,
    max_tokens      INT DEFAULT 1024
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'step',             'generate',
        'model',            model,
        'prompt_template',  prompt_template,
        'column',           input_column,
        'max_tokens',       max_tokens
    );
$$;


CREATE OR REPLACE FUNCTION ai.rank(
    model           TEXT,
    query_column    TEXT,
    doc_column      TEXT,
    top_k           INT DEFAULT 10
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'step',             'rank',
        'model',            model,
        'query_column',     query_column,
        'doc_column',       doc_column,
        'top_k',            top_k
    );
$$;


CREATE OR REPLACE FUNCTION ai.request_approval(
    content TEXT,
    notify  TEXT DEFAULT NULL,
    timeout INT DEFAULT 3600
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'step',     'approval',
        'content',  content,
        'notify',   notify,
        'timeout',  timeout
    );
$$;


CREATE OR REPLACE FUNCTION ai.parse_document(
    source  TEXT,
    format  TEXT DEFAULT 'auto',
    options JSONB DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'step',     'parse_document',
        'source',   source,
        'format',   format,
        'options',  options
    );
$$;


-- =============================================================================
-- 4. Sink constructors
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.table_sink(
    table_name          TEXT,
    schema_name         TEXT DEFAULT 'public',
    columns             TEXT[] DEFAULT NULL,
    on_conflict         TEXT[] DEFAULT NULL,
    on_conflict_action  TEXT DEFAULT 'update'
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'type',                 'table',
        'table_name',           table_name,
        'schema_name',          schema_name,
        'columns',              to_jsonb(columns),
        'on_conflict',          to_jsonb(on_conflict),
        'on_conflict_action',   on_conflict_action
    );
$$;


-- =============================================================================
-- 5. Internal: build df execution SQL for each step type
-- =============================================================================

-- Build the SQL that processes one batch through a single step.
-- Each step reads from a staging table (_ai_batch) and writes results back.
CREATE OR REPLACE FUNCTION ai._step_sql(
    step_config JSONB,
    pipeline_name TEXT,
    batch_table TEXT DEFAULT '_ai_batch',
    has_chunks BOOLEAN DEFAULT TRUE
)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    step_type    TEXT;
    col          TEXT;
    model        TEXT;
    result       TEXT;
    target_table TEXT;
BEGIN
    step_type := step_config->>'step';
    col       := step_config->>'column';
    model     := step_config->>'model';
    -- When there are chunks, embed/extract/generate/rank operate on _chunks table;
    -- otherwise they operate on the batch table directly.
    target_table := CASE WHEN has_chunks THEN batch_table || '_chunks' ELSE batch_table END;

    CASE step_type
    -- ----------------------------------------------------------------
    -- CHUNK: expand rows 1→N using a recursive text splitter
    -- ----------------------------------------------------------------
    WHEN 'chunk' THEN
        result := format(
            $SQL$
            WITH source AS (SELECT * FROM %s)
            INSERT INTO %s (doc_id, chunk_index, chunk_text, metadata)
            SELECT
                s.id AS doc_id,
                c.chunk_index,
                c.chunk_text,
                jsonb_build_object('source_column', %L, 'method', %L,
                                   'chunk_size', %s, 'overlap', %s)
            FROM source s,
            LATERAL ai._chunk_text(
                s.%I,
                %L,
                %s::int,
                %s::int
            ) AS c
            $SQL$,
            batch_table,
            batch_table || '_chunks',
            col,
            step_config->>'method',
            COALESCE(step_config->>'chunk_size', '512'),
            COALESCE(step_config->>'overlap', '64'),
            col,
            step_config->>'method',
            COALESCE(step_config->>'chunk_size', '512'),
            COALESCE(step_config->>'overlap', '64')
        );

    -- ----------------------------------------------------------------
    -- EMBED: call azure_ai embedding endpoint per batch
    -- ----------------------------------------------------------------
    WHEN 'embed' THEN
        result := format(
            $SQL$
            UPDATE %s SET embedding = azure_openai.create_embeddings(
                %L,
                %I,
                dimensions => %s
            )::vector
            $SQL$,
            target_table,
            model,
            col,
            COALESCE(step_config->>'dimensions', 'NULL')
        );

    -- ----------------------------------------------------------------
    -- EXTRACT: call azure_ai.extract for structured data extraction
    -- ----------------------------------------------------------------
    WHEN 'extract' THEN
        result := format(
            $SQL$
            UPDATE %s SET extracted = azure_ai.extract(
                %I,
                ARRAY(SELECT jsonb_array_elements_text(%L::jsonb)),
                %L
            )
            $SQL$,
            target_table,
            col,
            COALESCE(step_config->'data', step_config->'fields')::text,
            model
        );

    -- ----------------------------------------------------------------
    -- GENERATE: call azure_ai.generate for LLM generation
    -- ----------------------------------------------------------------
    WHEN 'generate' THEN
        result := format(
            $SQL$
            UPDATE %s SET generated = azure_ai.generate(
                %I,
                %L
            )
            $SQL$,
            target_table,
            col,
            model
        );

    -- ----------------------------------------------------------------
    -- RANK: call azure_ai.rank for re-ranking
    -- ----------------------------------------------------------------
    WHEN 'rank' THEN
        result := format(
            $SQL$
            UPDATE %s SET rank_score = azure_ai.rank(
                %L,
                %I,
                %I,
                %s
            )
            $SQL$,
            target_table,
            model,
            step_config->>'query_column',
            step_config->>'doc_column',
            COALESCE(step_config->>'top_k', '10')
        );

    -- ----------------------------------------------------------------
    -- APPROVAL: wait for a human signal via df.wait_for_signal()
    -- ----------------------------------------------------------------
    WHEN 'approval' THEN
        -- This step is handled specially in the df graph builder
        -- as it uses df.wait_for_signal() rather than raw SQL
        result := format(
            $SQL$SELECT 'awaiting_approval'$SQL$
        );

    ELSE
        RAISE EXCEPTION 'Unknown AI pipeline step type: %', step_type;
    END CASE;

    RETURN result;
END;
$$;


-- =============================================================================
-- 6. Internal: text chunking (recursive character splitter)
-- =============================================================================

CREATE OR REPLACE FUNCTION ai._chunk_text(
    input_text  TEXT,
    method      TEXT DEFAULT 'recursive',
    chunk_size  INT DEFAULT 512,
    overlap     INT DEFAULT 64
)
RETURNS TABLE(chunk_index INT, chunk_text TEXT)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    text_len    INT;
    pos         INT := 1;
    idx         INT := 0;
    end_pos     INT;
    chunk       TEXT;
    break_pos   INT;
BEGIN
    IF input_text IS NULL OR length(input_text) = 0 THEN
        RETURN;
    END IF;

    text_len := length(input_text);

    -- Simple recursive character splitting with overlap
    WHILE pos <= text_len LOOP
        end_pos := least(pos + chunk_size - 1, text_len);

        -- Try to break at sentence/paragraph boundary if not at end
        IF end_pos < text_len THEN
            -- Look for paragraph break
            break_pos := greatest(
                -- paragraph break
                COALESCE(
                    length(substring(input_text FROM pos FOR chunk_size))
                    - length(regexp_replace(
                        reverse(substring(input_text FROM pos FOR chunk_size)),
                        '^[^\n]*\n\n', '', 'n'
                    )),
                    0
                ),
                -- sentence break (. ! ?)
                COALESCE(
                    length(substring(input_text FROM pos FOR chunk_size))
                    - length(regexp_replace(
                        reverse(substring(input_text FROM pos FOR chunk_size)),
                        '^[^.!?]*[.!?]', '', 'n'
                    )),
                    0
                )
            );

            IF break_pos > chunk_size / 4 THEN
                end_pos := pos + break_pos - 1;
            END IF;
        END IF;

        chunk := substring(input_text FROM pos FOR (end_pos - pos + 1));
        chunk_index := idx;
        chunk_text := trim(chunk);

        IF length(chunk_text) > 0 THEN
            RETURN NEXT;
        END IF;

        idx := idx + 1;
        -- Advance with overlap, ensuring we always move forward
        IF end_pos >= text_len THEN
            EXIT;  -- processed the last chunk
        END IF;
        pos := greatest(pos + 1, end_pos + 1 - overlap);
    END LOOP;
END;
$$;


-- =============================================================================
-- 6b. Internal: incremental embed + sink (processes one row at a time)
-- Uses dblink for autonomous transactions so each row is immediately visible
-- =============================================================================

CREATE OR REPLACE FUNCTION ai._embed_and_flush(
    source_table  TEXT,
    sink_table    TEXT,
    model         TEXT,
    col           TEXT,
    dimensions    INT,
    pipeline_name TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    row_count INT := 0;
    conn_str TEXT;
BEGIN
    -- Build connection string for dblink (connect to same database via TCP)
    conn_str := format('dbname=%s host=localhost port=%s',
        current_database(),
        current_setting('port')
    );

    FOR r IN EXECUTE format(
        'SELECT s.ctid FROM %s s WHERE s.embedding IS NULL AND NOT EXISTS (SELECT 1 FROM %s o WHERE o.doc_id = s.doc_id AND o.chunk_index = s.chunk_index)',
        source_table, sink_table
    ) LOOP
        -- Check if pipeline was paused — use dblink to see latest committed state
        -- (the current transaction's snapshot won't see changes from other sessions)
        IF pipeline_name IS NOT NULL THEN
            IF EXISTS (
                SELECT 1 FROM dblink(conn_str,
                    format('SELECT 1 FROM ai.pipelines WHERE name = %L AND paused = true', pipeline_name)
                ) AS t(x int)
            ) THEN
                RETURN format('Pipeline paused after %s rows', row_count);
            END IF;
        END IF;

        -- Embed + flush in a single dblink call (autonomous transaction):
        -- UPDATE computes the embedding, RETURNING * feeds into INSERT so the
        -- sink row gets the embedding value (dblink can't see uncommitted changes
        -- from the main transaction, so both must happen inside dblink).
        PERFORM dblink_exec(conn_str, format(
            'WITH updated AS (
                UPDATE %s SET embedding = azure_openai.create_embeddings(%L, %I, dimensions => %s)::vector
                WHERE ctid = %L
                RETURNING *
            )
            INSERT INTO %s SELECT * FROM updated',
            source_table, model, col, dimensions, r.ctid,
            sink_table
        ));

        row_count := row_count + 1;

        -- Update total_processed so ai.status() reflects incremental progress
        IF pipeline_name IS NOT NULL THEN
            PERFORM dblink_exec(conn_str, format(
                'UPDATE ai.pipeline_checkpoints SET total_processed = %s WHERE pipeline_name = %L',
                row_count, pipeline_name
            ));
        END IF;
    END LOOP;

    RETURN format('Embedded and flushed %s rows incrementally', row_count);
END;
$$;

-- =============================================================================
-- 7. Core: ai.create_pipeline() — register pipeline and build df graph
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.create_pipeline(
    name    TEXT,
    source  JSONB,
    steps   JSONB[],
    sink    JSONB DEFAULT NULL,
    trigger TEXT DEFAULT 'manual',
    options JSONB DEFAULT '{}'
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    existing BOOLEAN;
BEGIN
    -- Validate pipeline name
    IF name IS NULL OR length(trim(name)) = 0 THEN
        RAISE EXCEPTION 'Pipeline name cannot be empty';
    END IF;
    IF name !~ '^[a-zA-Z_][a-zA-Z0-9_-]*$' THEN
        RAISE EXCEPTION 'Pipeline name must be alphanumeric (got: %)', name;
    END IF;

    -- Check for duplicates
    SELECT EXISTS(SELECT 1 FROM ai.pipelines p WHERE p.name = create_pipeline.name) INTO existing;
    IF existing THEN
        RAISE EXCEPTION 'Pipeline "%" already exists. Use ai.drop() first.', name;
    END IF;

    -- Validate source
    IF source->>'type' IS NULL THEN
        RAISE EXCEPTION 'Source must have a type (use ai.table_source or ai.file_source)';
    END IF;

    -- Validate steps
    IF array_length(steps, 1) IS NULL OR array_length(steps, 1) = 0 THEN
        RAISE EXCEPTION 'Pipeline must have at least one step';
    END IF;

    -- Validate trigger
    IF trigger NOT IN ('manual', 'on_change', 'schedule') THEN
        RAISE EXCEPTION 'Invalid trigger type: %. Use manual, on_change, or schedule.', trigger;
    END IF;

    -- Auto-create default sink table when none provided
    IF sink IS NULL THEN
        DECLARE
            output_table TEXT;
            has_chunk    BOOLEAN := false;
            has_embed    BOOLEAN := false;
            has_extract  BOOLEAN := false;
            has_generate BOOLEAN := false;
            embed_dims   INT;
            step         JSONB;
            ddl          TEXT;
            src_schema   TEXT;
            src_table    TEXT;
        BEGIN
            output_table := replace(name, '-', '_') || '_output';
            src_schema   := COALESCE(source->>'schema_name', 'public');
            src_table    := source->>'table_name';

            -- Inspect steps to determine needed columns
            FOREACH step IN ARRAY steps LOOP
                CASE step->>'step'
                    WHEN 'chunk'   THEN has_chunk := true;
                    WHEN 'embed'   THEN
                        has_embed := true;
                        IF step->>'dimensions' IS NOT NULL THEN
                            embed_dims := (step->>'dimensions')::int;
                        END IF;
                    WHEN 'extract'  THEN has_extract  := true;
                    WHEN 'generate' THEN has_generate := true;
                    ELSE NULL;
                END CASE;
            END LOOP;

            IF has_chunk THEN
                -- Chunk pipelines: fixed schema matching the staging chunk table
                ddl := format(
                    'CREATE TABLE IF NOT EXISTS public.%I ('
                    'doc_id INT, chunk_index INT, chunk_text TEXT, '
                    'embedding vector%s, extracted JSONB, generated TEXT, '
                    'rank_score NUMERIC, metadata JSONB)',
                    output_table,
                    CASE WHEN embed_dims IS NOT NULL
                         THEN format('(%s)', embed_dims) ELSE '' END
                );
            ELSE
                -- Non-chunk: start from source structure
                ddl := format(
                    'CREATE TABLE IF NOT EXISTS public.%I (LIKE %I.%I INCLUDING DEFAULTS)',
                    output_table, src_schema, src_table
                );
            END IF;

            EXECUTE ddl;

            -- For non-chunk pipelines, add enrichment columns
            IF NOT has_chunk THEN
                IF has_embed THEN
                    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS embedding vector%s',
                        output_table,
                        CASE WHEN embed_dims IS NOT NULL
                             THEN format('(%s)', embed_dims) ELSE '' END);
                END IF;
                IF has_extract THEN
                    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS extracted JSONB', output_table);
                END IF;
                IF has_generate THEN
                    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS generated TEXT', output_table);
                END IF;
            END IF;

            sink := ai.table_sink(output_table);
            RAISE NOTICE 'Auto-created sink table: public.%', output_table;
        END;
    END IF;

    -- Register pipeline
    INSERT INTO ai.pipelines (name, source_config, steps, sink_config, trigger_type, options)
    VALUES (name, source, steps, sink, trigger, options);

    -- Initialize checkpoint
    INSERT INTO ai.pipeline_checkpoints (pipeline_name, last_value, last_run_at)
    VALUES (name, NULL, NULL)
    ON CONFLICT (pipeline_name) DO NOTHING;

    -- Set up trigger if on_change
    IF trigger = 'on_change' AND source->>'type' = 'table' THEN
        PERFORM ai._setup_change_trigger(name, source);
    END IF;

    RETURN format('Pipeline "%s" created successfully', name);
END;
$$;


-- =============================================================================
-- 8. ai.run() — execute a pipeline using pg_durable
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.run(
    pipeline_name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    p               RECORD;
    source_sql      TEXT;
    step_sqls       TEXT[];
    sink_sql        TEXT;
    df_graph        TEXT;
    instance_id     TEXT;
    run_id          BIGINT;
    step_config     JSONB;
    i               INT;
    src_table       TEXT;
    src_schema      TEXT;
    src_incr        TEXT;
    last_checkpoint TEXT;
    sink_table      TEXT;
    sink_schema     TEXT;
    conflict_cols   TEXT;
    has_chunks      BOOLEAN := false;
    has_embed       BOOLEAN := false;
    has_extract     BOOLEAN := false;
    has_generate    BOOLEAN := false;
    embed_dims      INT;
    src_config      JSONB;
    snk_config      JSONB;
    batch_table     TEXT;
    batch_suffix    TEXT;
    step_labels     TEXT[] := ARRAY[]::TEXT[];  -- parallel to step_sqls: 'infra','chunk','embed','extract','generate','rank','approval'
    target_table    TEXT;  -- where AI steps read/write (batch or chunks table)
    sink_flushed    BOOLEAN := false;  -- whether sink was already written inline (after embed)
BEGIN
    -- Load pipeline definition
    SELECT * INTO p FROM ai.pipelines WHERE name = pipeline_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pipeline "%" not found', pipeline_name;
    END IF;
    IF p.paused THEN
        RAISE EXCEPTION 'Pipeline "%" is paused. Use ai.resume() first.', pipeline_name;
    END IF;

    src_config := p.source_config::jsonb;
    snk_config := p.sink_config::jsonb;

    -- Generate unique batch table names for this run (visible across connections)
    batch_suffix := replace(gen_random_uuid()::text, '-', '');
    batch_table  := format('ai._batch_%s', left(batch_suffix, 12));

    -- Get checkpoint
    SELECT cp.last_value INTO last_checkpoint
    FROM ai.pipeline_checkpoints cp WHERE cp.pipeline_name = run.pipeline_name;

    -- ----------------------------------------------------------------
    -- Build source query: fetch new/changed rows into staging table
    -- Uses a regular table (not temp) so it's visible across bg worker connections
    -- ----------------------------------------------------------------
    src_table  := src_config->>'table_name';
    src_schema := COALESCE(src_config->>'schema_name', 'public');
    src_incr   := src_config->>'incremental_column';

    IF src_config->>'type' = 'table' THEN
        source_sql := format(
            'CREATE TABLE %s AS SELECT * FROM %I.%I',
            batch_table, src_schema, src_table
        );
        -- Add incremental filter
        IF src_incr IS NOT NULL AND last_checkpoint IS NOT NULL THEN
            source_sql := source_sql || format(
                ' WHERE %I > %L',
                src_incr,
                last_checkpoint
            );
        END IF;
        -- Apply user filter
        IF src_config->>'filter' IS NOT NULL THEN
            IF last_checkpoint IS NOT NULL AND src_incr IS NOT NULL THEN
                source_sql := source_sql || ' AND ' || (src_config->>'filter');
            ELSE
                source_sql := source_sql || ' WHERE ' || (src_config->>'filter');
            END IF;
        END IF;
    ELSE
        RAISE EXCEPTION 'File sources not yet implemented';
    END IF;

    -- ----------------------------------------------------------------
    -- Build step queries: chain as df sequential graph
    -- ----------------------------------------------------------------

    -- First pass: detect chunk/embed/extract to determine staging table shape
    FOR i IN 1..array_length(p.steps, 1) LOOP
        step_config := p.steps[i];
        IF step_config->>'step' = 'chunk' THEN
            has_chunks := true;
        END IF;
        IF step_config->>'step' = 'embed' THEN
            has_embed := true;
            IF step_config->>'dimensions' IS NOT NULL THEN
                embed_dims := (step_config->>'dimensions')::int;
            END IF;
        END IF;
        IF step_config->>'step' = 'extract' THEN
            has_extract := true;
        END IF;
        IF step_config->>'step' = 'generate' THEN
            has_generate := true;
        END IF;
    END LOOP;

    -- Create staging table for chunks with the correct vector dimension
    step_sqls := ARRAY[]::TEXT[];
    step_labels := ARRAY[]::TEXT[];
    IF has_chunks THEN
        IF embed_dims IS NOT NULL THEN
            step_sqls := step_sqls || format(
                'CREATE TABLE %s_chunks (
                    doc_id INT, chunk_index INT, chunk_text TEXT,
                    embedding vector(%s), extracted JSONB, generated TEXT,
                    rank_score NUMERIC, metadata JSONB
                )',
                batch_table, embed_dims
            );
        ELSE
            step_sqls := step_sqls || format(
                'CREATE TABLE %s_chunks (
                    doc_id INT, chunk_index INT, chunk_text TEXT,
                    embedding vector, extracted JSONB, generated TEXT,
                    rank_score NUMERIC, metadata JSONB
                )',
                batch_table
            );
        END IF;
        step_labels := array_append(step_labels, 'infra');
    END IF;

    -- When there are no chunks but embed/extract steps exist, add needed columns
    -- to the batch table directly so those steps can UPDATE them.
    IF NOT has_chunks THEN
        IF has_embed THEN
            IF embed_dims IS NOT NULL THEN
                step_sqls := step_sqls || format(
                    'ALTER TABLE %s ADD COLUMN embedding vector(%s)',
                    batch_table, embed_dims
                );
            ELSE
                step_sqls := step_sqls || format(
                    'ALTER TABLE %s ADD COLUMN embedding vector',
                    batch_table
                );
            END IF;
            step_labels := array_append(step_labels, 'infra');
        END IF;
        IF has_extract THEN
            step_sqls := step_sqls || format(
                'ALTER TABLE %s ADD COLUMN extracted JSONB',
                batch_table
            );
            step_labels := array_append(step_labels, 'infra');
        END IF;
        IF has_generate THEN
            step_sqls := step_sqls || format(
                'ALTER TABLE %s ADD COLUMN generated TEXT',
                batch_table
            );
            step_labels := array_append(step_labels, 'infra');
        END IF;
    END IF;

    -- Determine the target table for AI steps (chunks table or batch table)
    target_table := CASE WHEN has_chunks THEN batch_table || '_chunks' ELSE batch_table END;

    -- Resolve sink table early so embed can use it for incremental flush
    sink_table  := snk_config->>'table_name';
    sink_schema := COALESCE(snk_config->>'schema_name', 'public');

    -- Second pass: build step SQL with labels
    FOR i IN 1..array_length(p.steps, 1) LOOP
        step_config := p.steps[i];

        -- Handle approval steps through df.wait_for_signal
        IF step_config->>'step' = 'approval' THEN
            -- This will be handled as a df.wait_for_signal in the graph
            step_sqls := array_append(step_sqls, 'APPROVAL_SIGNAL_PLACEHOLDER');
            step_labels := array_append(step_labels, 'approval');
        -- Embed step: use incremental embed+flush function
        ELSIF step_config->>'step' = 'embed' THEN
            step_sqls := step_sqls || format(
                'SELECT ai._embed_and_flush(%L, %L, %L, %L, %s, %L)',
                target_table,
                format('%I.%I', sink_schema, sink_table),
                step_config->>'model',
                step_config->>'column',
                COALESCE(step_config->>'dimensions', '1536'),
                pipeline_name
            );
            step_labels := array_append(step_labels, 'embed');
            sink_flushed := true;
        ELSE
            step_sqls := step_sqls || ai._step_sql(step_config, pipeline_name, batch_table, has_chunks);
            step_labels := array_append(step_labels, step_config->>'step');
        END IF;
    END LOOP;

    -- ----------------------------------------------------------------
    -- Build sink query: write results to destination table
    -- For no-chunk pipelines, we must explicitly list sink columns
    -- because batch table column order may differ from sink table.
    -- ----------------------------------------------------------------

    IF has_chunks THEN
        sink_sql := format(
            'INSERT INTO %I.%I SELECT * FROM %s_chunks',
            sink_schema, sink_table, batch_table
        );
    ELSE
        -- Build explicit column list from the sink table to ensure correct mapping
        DECLARE
            sink_cols TEXT;
        BEGIN
            SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
            INTO sink_cols
            FROM information_schema.columns
            WHERE table_schema = sink_schema
              AND table_name = sink_table
              AND column_name NOT IN ('created_at');  -- skip auto-generated columns

            IF sink_cols IS NOT NULL THEN
                sink_sql := format(
                    'INSERT INTO %I.%I (%s) SELECT %s FROM %s',
                    sink_schema, sink_table, sink_cols, sink_cols, batch_table
                );
            ELSE
                sink_sql := format(
                    'INSERT INTO %I.%I SELECT * FROM %s',
                    sink_schema, sink_table, batch_table
                );
            END IF;
        END;
    END IF;

    -- Handle conflict resolution
    IF snk_config->'on_conflict' IS NOT NULL
       AND snk_config->'on_conflict' != 'null'::jsonb THEN
        conflict_cols := '';
        FOR i IN 0..(jsonb_array_length(snk_config->'on_conflict') - 1) LOOP
            IF i > 0 THEN conflict_cols := conflict_cols || ', '; END IF;
            conflict_cols := conflict_cols || (snk_config->'on_conflict'->>i);
        END LOOP;

        IF snk_config->>'on_conflict_action' = 'update' THEN
            sink_sql := sink_sql || format(
                ' ON CONFLICT (%s) DO UPDATE SET updated_at = now()',
                conflict_cols
            );
        ELSE
            sink_sql := sink_sql || format(
                ' ON CONFLICT (%s) DO NOTHING',
                conflict_cols
            );
        END IF;
    END IF;

    -- ----------------------------------------------------------------
    -- Build cleanup SQL: update checkpoint, drop temp tables
    -- ----------------------------------------------------------------

    -- ----------------------------------------------------------------
    -- Compose full df graph: source ~> step1 ~> step2 ~> ... ~> sink ~> cleanup
    -- Each piece is a quoted SQL literal; the ~> operator chains them into
    -- a Durofut JSON tree at evaluation time inside EXECUTE.
    --
    -- Preview queries are injected after source and each AI step so that
    -- the intermediate data flowing through the pipeline is captured in
    -- df.nodes.result and visible in the dashboard.
    -- ----------------------------------------------------------------
    df_graph := quote_literal(source_sql);

    -- Source preview: show what was fetched from the source table
    df_graph := df_graph || ' ~> ' || quote_literal(format(
        'SELECT * FROM %s ORDER BY 1 LIMIT 10', batch_table
    ));

    FOR i IN 1..array_length(step_sqls, 1) LOOP
        IF step_sqls[i] = 'APPROVAL_SIGNAL_PLACEHOLDER' THEN
            df_graph := format(
                $DF$%s ~> (df.wait_for_signal('pipeline_%s_approval') |=> 'approval')$DF$,
                df_graph,
                pipeline_name
            );
        ELSE
            df_graph := df_graph || ' ~> ' || quote_literal(step_sqls[i]);
        END IF;

        -- After each AI step (not infra), inject a preview SELECT
        IF step_labels[i] IS NOT NULL AND step_labels[i] != 'infra' AND step_labels[i] != 'approval' THEN
            CASE step_labels[i]
                WHEN 'chunk' THEN
                    df_graph := df_graph || ' ~> ' || quote_literal(format(
                        'SELECT doc_id, chunk_index, left(chunk_text, 120) AS chunk_text FROM %s_chunks ORDER BY doc_id, chunk_index LIMIT 10',
                        batch_table
                    ));
                WHEN 'embed' THEN
                    -- Preview: show what's in the output table after incremental embed+flush
                    df_graph := df_graph || ' ~> ' || quote_literal(format(
                        'SELECT * FROM %I.%I ORDER BY 1 DESC LIMIT 10',
                        sink_schema, sink_table
                    ));
                WHEN 'extract' THEN
                    df_graph := df_graph || ' ~> ' || quote_literal(format(
                        'SELECT doc_id, chunk_index, extracted FROM %s ORDER BY 1, 2 LIMIT 10',
                        target_table
                    ));
                WHEN 'generate' THEN
                    df_graph := df_graph || ' ~> ' || quote_literal(format(
                        'SELECT doc_id, chunk_index, left(generated, 200) AS generated FROM %s ORDER BY 1, 2 LIMIT 10',
                        target_table
                    ));
                WHEN 'rank' THEN
                    df_graph := df_graph || ' ~> ' || quote_literal(format(
                        'SELECT doc_id, chunk_index, rank_score FROM %s ORDER BY rank_score DESC LIMIT 10',
                        target_table
                    ));
                ELSE
                    -- Generic preview for unknown step types
                    df_graph := df_graph || ' ~> ' || quote_literal(format(
                        'SELECT * FROM %s ORDER BY 1 LIMIT 10',
                        target_table
                    ));
            END CASE;
        END IF;
    END LOOP;

    -- Add sink (skip if already flushed inline after embed)
    IF NOT sink_flushed THEN
        df_graph := df_graph || ' ~> ' || quote_literal(sink_sql);

        -- Sink preview: show what was written to the destination
        df_graph := df_graph || ' ~> ' || quote_literal(format(
            'SELECT * FROM %I.%I ORDER BY 1 DESC LIMIT 10',
            sink_schema, sink_table
        ));
    END IF;

    -- Add checkpoint update
    IF src_incr IS NOT NULL THEN
        IF sink_flushed THEN
            -- Embed step already updates total_processed incrementally via dblink.
            -- Only advance last_value if the pipeline is NOT paused (i.e. full batch completed).
            -- If paused, leave last_value unchanged so resume re-fetches remaining rows.
            df_graph := df_graph || ' ~> ' || quote_literal(format(
                'UPDATE ai.pipeline_checkpoints SET last_run_at = now(), last_value = CASE WHEN (SELECT paused FROM ai.pipelines WHERE name = %L) THEN last_value ELSE (SELECT max(%I)::text FROM %I.%I) END WHERE pipeline_name = %L',
                pipeline_name,
                src_incr,
                src_schema, src_table,
                pipeline_name
            ));
        ELSE
            df_graph := df_graph || ' ~> ' || quote_literal(format(
                'UPDATE ai.pipeline_checkpoints SET last_value = (SELECT max(%I)::text FROM %I.%I), last_run_at = now(), total_processed = total_processed + (SELECT count(*) FROM %s) WHERE pipeline_name = %L',
                src_incr,
                src_schema, src_table,
                batch_table,
                pipeline_name
            ));
        END IF;
    END IF;

    -- Add staging table cleanup
    IF has_chunks THEN
        df_graph := df_graph || ' ~> ' || quote_literal(format('DROP TABLE IF EXISTS %s_chunks', batch_table));
    END IF;
    df_graph := df_graph || ' ~> ' || quote_literal(format('DROP TABLE IF EXISTS %s', batch_table));

    -- ----------------------------------------------------------------
    -- Start the durable function
    -- The ~> operators are evaluated as SQL operators producing Durofut JSON
    -- ----------------------------------------------------------------
    EXECUTE format(
        'SELECT df.start(%s, %L)',
        df_graph,
        format('ai-pipeline:%s', pipeline_name)
    ) INTO instance_id;

    -- Record the run
    INSERT INTO ai.pipeline_runs (pipeline_name, instance_id, status)
    VALUES (pipeline_name, instance_id, 'running')
    RETURNING id INTO run_id;

    RETURN instance_id;
END;
$$;


-- =============================================================================
-- 9. ai.status() — pipeline monitoring
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.status(
    pipeline_name TEXT DEFAULT NULL
)
RETURNS TABLE(
    name            TEXT,
    trigger_type    TEXT,
    paused          BOOLEAN,
    last_run_status TEXT,
    last_run_at     TIMESTAMPTZ,
    total_runs      BIGINT,
    total_processed BIGINT,
    last_instance   TEXT,
    df_status       TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.name,
        p.trigger_type,
        p.paused,
        lr.status           AS last_run_status,
        lr.started_at       AS last_run_at,
        COALESCE(rc.cnt, 0) AS total_runs,
        COALESCE(cp.total_processed, 0) AS total_processed,
        lr.instance_id      AS last_instance,
        (SELECT s FROM df.status(lr.instance_id) s) AS df_status
    FROM ai.pipelines p
    LEFT JOIN LATERAL (
        SELECT pr.status, pr.started_at, pr.instance_id
        FROM ai.pipeline_runs pr
        WHERE pr.pipeline_name = p.name
        ORDER BY pr.started_at DESC
        LIMIT 1
    ) lr ON true
    LEFT JOIN LATERAL (
        SELECT count(*) AS cnt
        FROM ai.pipeline_runs pr2
        WHERE pr2.pipeline_name = p.name
    ) rc ON true
    LEFT JOIN ai.pipeline_checkpoints cp ON cp.pipeline_name = p.name
    WHERE (status.pipeline_name IS NULL OR p.name = status.pipeline_name);
END;
$$;


-- =============================================================================
-- 10. ai.list_pipelines() — list all registered pipelines
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.list_pipelines()
RETURNS TABLE(
    name            TEXT,
    source_type     TEXT,
    step_count      INT,
    trigger_type    TEXT,
    paused          BOOLEAN,
    created_at      TIMESTAMPTZ,
    created_by      TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        p.name,
        p.source_config->>'type',
        array_length(p.steps, 1),
        p.trigger_type,
        p.paused,
        p.created_at,
        p.created_by
    FROM ai.pipelines p
    ORDER BY p.created_at;
$$;


-- =============================================================================
-- 11. ai.drop() — remove a pipeline
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.drop(
    pipeline_name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    p RECORD;
BEGIN
    SELECT * INTO p FROM ai.pipelines WHERE name = pipeline_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pipeline "%" not found', pipeline_name;
    END IF;

    -- Remove change trigger if any
    IF p.trigger_type = 'on_change' AND p.source_config->>'type' = 'table' THEN
        PERFORM ai._remove_change_trigger(pipeline_name, p.source_config);
    END IF;

    DELETE FROM ai.pipelines WHERE name = pipeline_name;
    RETURN format('Pipeline "%s" dropped', pipeline_name);
END;
$$;


-- =============================================================================
-- 12. ai.pause() / ai.resume()
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.pause(pipeline_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    _instance_id TEXT;
    _df_status   TEXT;
BEGIN
    UPDATE ai.pipelines SET paused = true, updated_at = now()
    WHERE name = pipeline_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pipeline "%" not found', pipeline_name;
    END IF;

    -- Cancel the currently running instance (if any)
    SELECT pr.instance_id INTO _instance_id
    FROM ai.pipeline_runs pr
    WHERE pr.pipeline_name = pause.pipeline_name
    ORDER BY pr.started_at DESC LIMIT 1;

    IF _instance_id IS NOT NULL THEN
        SELECT s INTO _df_status FROM df.status(_instance_id) s;
        IF lower(_df_status) = 'running' THEN
            PERFORM df.cancel(_instance_id, 'Paused by ai.pause()');
        END IF;
    END IF;

    RETURN format('Pipeline "%s" paused', pipeline_name);
END;
$$;


CREATE OR REPLACE FUNCTION ai.resume(pipeline_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    _instance_id TEXT;
BEGIN
    UPDATE ai.pipelines SET paused = false, updated_at = now()
    WHERE name = pipeline_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pipeline "%" not found', pipeline_name;
    END IF;

    -- Kick off a new run to continue processing remaining rows
    _instance_id := ai.run(pipeline_name);

    RETURN format('Pipeline "%s" resumed (instance %s)', pipeline_name, _instance_id);
END;
$$;


-- =============================================================================
-- 13. ai.backfill() — reprocess all data (reset checkpoint)
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.backfill(
    pipeline_name TEXT,
    batch_size    INT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    instance_id TEXT;
BEGIN
    -- Verify pipeline exists
    IF NOT EXISTS(SELECT 1 FROM ai.pipelines WHERE name = pipeline_name) THEN
        RAISE EXCEPTION 'Pipeline "%" not found', pipeline_name;
    END IF;

    -- Reset checkpoint to reprocess everything
    UPDATE ai.pipeline_checkpoints
    SET last_value = NULL, last_run_at = NULL
    WHERE pipeline_checkpoints.pipeline_name = backfill.pipeline_name;

    -- If batch_size specified, set it in pipeline options temporarily
    IF batch_size IS NOT NULL THEN
        UPDATE ai.pipelines
        SET options = options || jsonb_build_object('batch_size', batch_size),
            updated_at = now()
        WHERE name = pipeline_name;
    END IF;

    -- Run the pipeline
    SELECT ai.run(pipeline_name) INTO instance_id;

    RETURN instance_id;
END;
$$;


-- =============================================================================
-- 14. ai.explain() — show pipeline execution plan
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.explain(
    pipeline_name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    p           RECORD;
    step_config JSONB;
    i           INT;
    result      TEXT := '';
    src_table   TEXT;
    sink_table  TEXT;
    src_config  JSONB;
    snk_config  JSONB;
BEGIN
    SELECT * INTO p FROM ai.pipelines WHERE name = pipeline_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pipeline "%" not found', pipeline_name;
    END IF;

    src_config := p.source_config::jsonb;
    snk_config := p.sink_config::jsonb;

    src_table  := COALESCE(src_config->>'schema_name', 'public')
                  || '.' || (src_config->>'table_name');
    sink_table := COALESCE(snk_config->>'schema_name', 'public')
                  || '.' || (snk_config->>'table_name');

    result := format(E'Pipeline: %s\n', p.name);
    result := result || format(E'Trigger:  %s\n', p.trigger_type);
    result := result || E'──────────────────────────────\n';
    result := result || format(E'  [SOURCE] %s', src_table);

    IF src_config->>'incremental_column' IS NOT NULL THEN
        result := result || format(' (incremental: %s)', src_config->>'incremental_column');
    END IF;
    result := result || E'\n';

    FOR i IN 1..array_length(p.steps, 1) LOOP
        step_config := p.steps[i];
        result := result || format(E'     │\n     ▼\n');
        result := result || format(E'  [STEP %s] %s', i, upper(step_config->>'step'));

        CASE step_config->>'step'
            WHEN 'chunk' THEN
                result := result || format(
                    ' (column=%s, method=%s, size=%s, overlap=%s)',
                    step_config->>'column',
                    step_config->>'method',
                    step_config->>'chunk_size',
                    step_config->>'overlap'
                );
            WHEN 'embed' THEN
                result := result || format(
                    ' (model=%s, column=%s, batch=%s)',
                    step_config->>'model',
                    step_config->>'column',
                    step_config->>'batch_size'
                );
            WHEN 'extract' THEN
                result := result || format(
                    ' (model=%s, column=%s)',
                    step_config->>'model',
                    step_config->>'column'
                );
            WHEN 'generate' THEN
                result := result || format(
                    ' (model=%s, max_tokens=%s)',
                    step_config->>'model',
                    step_config->>'max_tokens'
                );
            WHEN 'rank' THEN
                result := result || format(
                    ' (model=%s, top_k=%s)',
                    step_config->>'model',
                    step_config->>'top_k'
                );
            WHEN 'approval' THEN
                result := result || format(
                    ' (timeout=%ss)',
                    step_config->>'timeout'
                );
            ELSE
                NULL;
        END CASE;

        result := result || E'\n';
    END LOOP;

    result := result || format(E'     │\n     ▼\n');
    result := result || format(E'  [SINK] %s', sink_table);
    IF snk_config->'on_conflict' IS NOT NULL
       AND snk_config->'on_conflict' != 'null'::jsonb THEN
        result := result || format(' (on_conflict: %s)', snk_config->>'on_conflict_action');
    END IF;
    result := result || E'\n';

    RETURN result;
END;
$$;


-- =============================================================================
-- 15. ai.cost_summary() — cost reporting
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.cost_summary(
    pipeline_name TEXT DEFAULT NULL
)
RETURNS TABLE(
    name            TEXT,
    step_name       TEXT,
    model           TEXT,
    total_input     BIGINT,
    total_output    BIGINT,
    total_cost      NUMERIC,
    call_count      BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT
        cl.pipeline_name,
        cl.step_name,
        cl.model,
        sum(cl.input_tokens),
        sum(cl.output_tokens),
        sum(cl.estimated_cost),
        count(*)
    FROM ai.cost_log cl
    WHERE (cost_summary.pipeline_name IS NULL OR cl.pipeline_name = cost_summary.pipeline_name)
    GROUP BY cl.pipeline_name, cl.step_name, cl.model
    ORDER BY cl.pipeline_name, cl.step_name;
$$;


-- =============================================================================
-- 16. ai.wait_for_completion() — poll a pipeline run until done
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.wait_for_completion(
    pipeline_name TEXT,
    timeout_secs  INT DEFAULT 300
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    inst_id     TEXT;
    run_status  TEXT;
BEGIN
    -- Get latest instance
    SELECT pr.instance_id INTO inst_id
    FROM ai.pipeline_runs pr
    WHERE pr.pipeline_name = wait_for_completion.pipeline_name
    ORDER BY pr.started_at DESC
    LIMIT 1;

    IF inst_id IS NULL THEN
        RAISE EXCEPTION 'No runs found for pipeline "%"', pipeline_name;
    END IF;

    -- Delegate to df.wait_for_completion
    SELECT df.wait_for_completion(inst_id, timeout_secs) INTO run_status;

    -- Update run record
    UPDATE ai.pipeline_runs
    SET status = CASE
            WHEN lower(run_status) = 'completed' THEN 'completed'
            WHEN lower(run_status) = 'failed' THEN 'failed'
            ELSE run_status
        END,
        completed_at = now()
    WHERE instance_id = inst_id;

    RETURN run_status;
END;
$$;


-- =============================================================================
-- 17. Change-trigger infrastructure
-- =============================================================================

CREATE OR REPLACE FUNCTION ai._on_change_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    pipe_name TEXT;
BEGIN
    pipe_name := TG_ARGV[0];

    -- Sync stale pipeline_runs: if df.instances shows completed/failed/canceled
    -- but pipeline_runs still says 'running', update it so the debounce works.
    UPDATE ai.pipeline_runs pr
    SET status = lower(i.status),
        completed_at = COALESCE(i.completed_at, now())
    FROM df.instances i
    WHERE pr.pipeline_name = pipe_name
      AND pr.status = 'running'
      AND pr.instance_id = i.id
      AND lower(i.status) IN ('completed', 'failed', 'canceled');

    -- Queue a pipeline run (debounced: only if not already running)
    IF NOT EXISTS (
        SELECT 1 FROM ai.pipeline_runs pr
        WHERE pr.pipeline_name = pipe_name
          AND pr.status = 'running'
    ) THEN
        PERFORM ai.run(pipe_name);
    END IF;

    RETURN NEW;
END;
$$;


CREATE OR REPLACE FUNCTION ai._setup_change_trigger(
    pipeline_name TEXT,
    source_config JSONB
)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    trig_name   TEXT;
    src_schema  TEXT;
    src_table   TEXT;
BEGIN
    src_schema := COALESCE(source_config->>'schema_name', 'public');
    src_table  := source_config->>'table_name';
    trig_name  := format('_ai_pipeline_%s_trigger', pipeline_name);

    EXECUTE format(
        'CREATE OR REPLACE TRIGGER %I
         AFTER INSERT OR UPDATE ON %I.%I
         FOR EACH STATEMENT
         EXECUTE FUNCTION ai._on_change_trigger(%L)',
        trig_name,
        src_schema, src_table,
        pipeline_name
    );
END;
$$;


CREATE OR REPLACE FUNCTION ai._remove_change_trigger(
    pipeline_name TEXT,
    source_config JSONB
)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    trig_name   TEXT;
    src_schema  TEXT;
    src_table   TEXT;
BEGIN
    src_schema := COALESCE(source_config->>'schema_name', 'public');
    src_table  := source_config->>'table_name';
    trig_name  := format('_ai_pipeline_%s_trigger', pipeline_name);

    EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %I.%I',
        trig_name,
        src_schema, src_table
    );
END;
$$;


-- =============================================================================
-- 18. Convenience: ai.result() — get pipeline run result
-- =============================================================================

CREATE OR REPLACE FUNCTION ai.result(
    pipeline_name TEXT,
    run_number    INT DEFAULT NULL  -- NULL = latest
)
RETURNS TABLE(
    run_id          BIGINT,
    instance_id     TEXT,
    status          TEXT,
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    rows_processed  INT,
    error           TEXT,
    df_result       TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    inst_id TEXT;
BEGIN
    RETURN QUERY
    SELECT
        pr.id,
        pr.instance_id,
        pr.status,
        pr.started_at,
        pr.completed_at,
        pr.rows_processed,
        pr.error,
        (SELECT r FROM df.result(pr.instance_id) r)
    FROM ai.pipeline_runs pr
    WHERE pr.pipeline_name = result.pipeline_name
    ORDER BY pr.started_at DESC
    LIMIT COALESCE(run_number, 1);
END;
$$;


-- =============================================================================
-- Done. Usage examples below.
-- =============================================================================

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ EXAMPLE 1: RAG Pipeline                                                │
-- │                                                                        │
-- │   SELECT ai.create_pipeline(                                            │
-- │       name   => 'rag_pipeline',                                        │
-- │       source => ai.table_source('documents',                           │
-- │                     incremental_column => 'updated_at'),               │
-- │       steps  => ARRAY[                                                 │
-- │           ai.chunk(input_column => 'content'),                         │
-- │           ai.embed(model => 'text-embedding-3-small',                  │
-- │                    input_column => 'chunk_text')                        │
-- │       ],                                                               │
-- │       sink   => ai.table_sink('document_vectors'),                     │
-- │       trigger => 'on_change'                                           │
-- │   );                                                                   │
-- │                                                                        │
-- │   -- Check status                                                      │
-- │   SELECT * FROM ai.status('rag_pipeline');                             │
-- │                                                                        │
-- │   -- Manual run                                                        │
-- │   SELECT ai.run('rag_pipeline');                                       │
-- │                                                                        │
-- │   -- Reprocess all data                                                │
-- │   SELECT ai.backfill('rag_pipeline');                                  │
-- │                                                                        │
-- │   -- View execution plan                                               │
-- │   SELECT ai.explain('rag_pipeline');                                   │
-- │                                                                        │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ EXAMPLE 2: Product Enrichment with Extraction                          │
-- │                                                                        │
-- │   SELECT ai.create_pipeline(                                            │
-- │       name   => 'product_enrichment',                                  │
-- │       source => ai.table_source('products',                            │
-- │                     incremental_column => 'updated_at'),               │
-- │       steps  => ARRAY[                                                 │
-- │           ai.embed(model => 'text-embedding-3-small',                  │
-- │                    input_column => 'description',                       │
-- │                    batch_size => 200),                                  │
-- │           ai.extract(model => 'gpt-4o',                                │
-- │                      input_column => 'description',                     │
-- │                      data => ARRAY[                                     │
-- │                          'category: Product category',                  │
-- │                          'brand: Brand name',                           │
-- │                          'key_features: Top 3 features as JSON array'   │
-- │                      ])                                                 │
-- │       ],                                                               │
-- │       sink   => ai.table_sink('product_vectors',                       │
-- │                     on_conflict => ARRAY['product_id'],                 │
-- │                     on_conflict_action => 'update'),                    │
-- │       trigger => 'on_change'                                           │
-- │   );                                                                   │
-- │                                                                        │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ EXAMPLE 3: Pipeline with Human Approval Gate                           │
-- │                                                                        │
-- │   SELECT ai.create_pipeline(                                            │
-- │       name   => 'reviewed_embeddings',                                 │
-- │       source => ai.table_source('legal_documents'),                    │
-- │       steps  => ARRAY[                                                 │
-- │           ai.chunk(input_column => 'content', method => 'paragraph'),  │
-- │           ai.request_approval(content => 'chunk_text',                 │
-- │                               timeout => 7200),                        │
-- │           ai.embed(model => 'text-embedding-3-small',                  │
-- │                    input_column => 'chunk_text')                        │
-- │       ],                                                               │
-- │       sink   => ai.table_sink('legal_vectors'),                        │
-- │       trigger => 'manual'                                              │
-- │   );                                                                   │
-- │                                                                        │
-- │   -- Run and wait for approval                                         │
-- │   SELECT ai.run('reviewed_embeddings');                                │
-- │   -- ... pipeline pauses at approval step ...                          │
-- │   -- Approve externally: SELECT df.signal(inst, 'pipeline_X', ...);   │
-- │                                                                        │
-- └─────────────────────────────────────────────────────────────────────────┘
