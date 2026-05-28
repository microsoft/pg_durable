-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Set per-session variables before running the workflow.
-- Preferred path: source .azure-functions.env then run this script with psql.
--
-- Example:
--   set -a && source .azure-functions.env && set +a
--   psql -d postgres -f sql/02_set_vars.sql

\getenv azure_function_base_url AZURE_FUNCTION_BASE_URL
\getenv azure_function_key AZURE_FUNCTION_KEY

DO $$
DECLARE
    v_base_url TEXT := :'azure_function_base_url';
    v_function_key TEXT := :'azure_function_key';
BEGIN
    IF COALESCE(length(trim(v_base_url)), 0) = 0 THEN
        RAISE EXCEPTION 'AZURE_FUNCTION_BASE_URL is not set. Source .azure-functions.env first.';
    END IF;

    IF COALESCE(length(trim(v_function_key)), 0) = 0 THEN
        RAISE EXCEPTION 'AZURE_FUNCTION_KEY is not set. Source .azure-functions.env first.';
    END IF;
END $$;

SELECT df.setvar('classify_url', :'azure_function_base_url');
SELECT df.setvar('function_key', :'azure_function_key');

SELECT df.getvar('classify_url') AS classify_url;
SELECT CASE
    WHEN df.getvar('function_key') IS NULL THEN 'missing'
    WHEN length(df.getvar('function_key')) > 0 THEN 'configured'
    ELSE 'empty'
END AS function_key_state;
