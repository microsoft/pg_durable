-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Set per-session variables before running the workflow.
-- Preferred path: source .audio-roundtrip.env then run this script with psql.
--
-- Example:
--   set -a && source .audio-roundtrip.env && set +a
--   psql -d postgres -f sql/02_set_vars.sql

-- \getenv leaves a psql variable undefined when the environment variable is
-- absent, and interpolating an undefined :'var' is a *parse* error. That would
-- abort this file with "syntax error at or near :" before the friendly checks
-- below ever run. Seed each variable to empty first so the block always parses
-- and reports which variable is actually missing.
\set azure_openai_endpoint ''
\set azure_openai_key ''
\set azure_openai_api_version ''
\set azure_tts_deployment ''
\set azure_whisper_deployment ''

\getenv azure_openai_endpoint AZURE_OPENAI_ENDPOINT
\getenv azure_openai_key AZURE_OPENAI_KEY
\getenv azure_openai_api_version AZURE_OPENAI_API_VERSION
\getenv azure_tts_deployment AZURE_TTS_DEPLOYMENT
\getenv azure_whisper_deployment AZURE_WHISPER_DEPLOYMENT

-- psql does not interpolate :'var' inside a dollar-quoted body, so the settings
-- are staged in a temp table and the checks below read them from there. Writing
-- the validation as DO $$ ... :'var' ... $$ looks correct but never runs: the
-- interpolation is left as literal text and the block dies with "syntax error
-- at or near :" before any check executes.
CREATE TEMP TABLE _audio_cfg AS
SELECT
    trim(:'azure_openai_endpoint')    AS endpoint,
    trim(:'azure_openai_key')         AS api_key,
    trim(:'azure_openai_api_version') AS api_version,
    trim(:'azure_tts_deployment')     AS tts,
    trim(:'azure_whisper_deployment') AS whisper;

DO $$
DECLARE
    c RECORD;
BEGIN
    SELECT * INTO c FROM _audio_cfg;

    IF COALESCE(length(c.endpoint), 0) = 0 THEN
        RAISE EXCEPTION 'AZURE_OPENAI_ENDPOINT is not set. Source .audio-roundtrip.env first.';
    END IF;

    IF COALESCE(length(c.api_key), 0) = 0 THEN
        RAISE EXCEPTION 'AZURE_OPENAI_KEY is not set. Source .audio-roundtrip.env first.';
    END IF;

    IF COALESCE(length(c.api_version), 0) = 0 THEN
        RAISE EXCEPTION 'AZURE_OPENAI_API_VERSION is not set. Source .audio-roundtrip.env first.';
    END IF;

    IF COALESCE(length(c.tts), 0) = 0 THEN
        RAISE EXCEPTION 'AZURE_TTS_DEPLOYMENT is not set. Source .audio-roundtrip.env first.';
    END IF;

    IF COALESCE(length(c.whisper), 0) = 0 THEN
        RAISE EXCEPTION 'AZURE_WHISPER_DEPLOYMENT is not set. Source .audio-roundtrip.env first.';
    END IF;

    -- The endpoint is concatenated with a path below, so a missing trailing
    -- slash silently produces a malformed URL. Fail here instead.
    IF right(c.endpoint, 1) <> '/' THEN
        RAISE EXCEPTION 'AZURE_OPENAI_ENDPOINT must end with a trailing slash, got: %', c.endpoint;
    END IF;
END $$;

-- Full request URLs are assembled once here so the workflow DSL stays readable
-- and no secret ever appears in df.nodes.
SELECT df.setvar(
    'speech_url',
    :'azure_openai_endpoint' || 'openai/deployments/' || :'azure_tts_deployment'
        || '/audio/speech?api-version=' || :'azure_openai_api_version'
);

SELECT df.setvar(
    'transcribe_url',
    :'azure_openai_endpoint' || 'openai/deployments/' || :'azure_whisper_deployment'
        || '/audio/transcriptions?api-version=' || :'azure_openai_api_version'
);

SELECT df.setvar('api_key', :'azure_openai_key');
SELECT df.setvar('tts_deployment', :'azure_tts_deployment');
SELECT df.setvar('whisper_deployment', :'azure_whisper_deployment');

-- Echo back everything except the key.
SELECT df.getvar('speech_url') AS speech_url;
SELECT df.getvar('transcribe_url') AS transcribe_url;
SELECT CASE
    WHEN df.getvar('api_key') IS NULL THEN 'missing'
    WHEN length(df.getvar('api_key')) > 0 THEN 'configured'
    ELSE 'empty'
END AS api_key_state;

DROP TABLE _audio_cfg;
