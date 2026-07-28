-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Audio Round Trip — demo schema
-- Run once to create tables. Safe to re-run (uses IF NOT EXISTS + TRUNCATE).

CREATE EXTENSION IF NOT EXISTS pg_durable;

CREATE SCHEMA IF NOT EXISTS demo;

-- One row per phrase. The workflow walks pending rows one at a time.
CREATE TABLE IF NOT EXISTS demo.audio_roundtrip (
    id BIGSERIAL PRIMARY KEY,
    phrase TEXT NOT NULL,
    -- The phrase is substituted into a JSON request body by df.http, which
    -- performs raw (non-escaping) substitution. A double quote or backslash
    -- would break out of the JSON string, so reject them at insert time rather
    -- than letting the workflow fail with a confusing upstream 400.
    CONSTRAINT phrase_is_json_safe CHECK (phrase !~ '["\\]'),
    -- Status lifecycle: pending → transcribed | failed
    status TEXT NOT NULL DEFAULT 'pending',
    transcript TEXT,
    matched BOOLEAN,
    -- Recorded so a rate-limited run is visibly different from a clean one.
    speech_status INT,
    speech_encoding TEXT,
    transcribe_status INT,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ
);

-- Whisper does not return the phrase verbatim. It adds sentence casing and
-- trailing punctuation, and it reformats unusual terms: "pg durable makes
-- workflows durable" has come back as both "PgDurable makes workflows durable."
-- and "pg durable makes workflows durable." on different runs, depending on
-- whether the request carried a vocabulary prompt. Comparing raw strings would
-- report a correct transcription as a failure, so both sides are reduced to
-- letters and digits before comparison.
CREATE OR REPLACE FUNCTION demo.audio_normalize(t TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', '', 'g')
$$;

-- Reset for a clean demo run.
TRUNCATE TABLE demo.audio_roundtrip RESTART IDENTITY;

SELECT 'Schema ready.' AS result;
