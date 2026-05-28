-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Phase 2 example schema for Azure Functions + pg_durable

CREATE EXTENSION IF NOT EXISTS pg_durable;

CREATE SCHEMA IF NOT EXISTS demo;

CREATE TABLE IF NOT EXISTS demo.af_documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    total_tokens INT,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS demo.af_document_chunks (
    id BIGSERIAL PRIMARY KEY,
    document_id BIGINT NOT NULL REFERENCES demo.af_documents(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    chunk_text TEXT NOT NULL,
    token_count INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (document_id, chunk_index)
);

TRUNCATE TABLE demo.af_document_chunks, demo.af_documents RESTART IDENTITY;

INSERT INTO demo.af_documents (content)
VALUES (
    'pg_durable runs workflows durably inside PostgreSQL. This sample shows how to call an HTTP-triggered Azure Function for token-aware chunking and persist the returned chunks in SQL tables for downstream processing.'
);

SELECT id, status, left(content, 80) AS preview
FROM demo.af_documents
ORDER BY id;
