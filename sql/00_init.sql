-- Initialize pg_durable extension
-- This must run first before any other tests
CREATE EXTENSION IF NOT EXISTS pg_durable;

-- Verify the extension was created
SELECT extname FROM pg_extension WHERE extname = 'pg_durable';

-- Verify the df schema exists
SELECT nspname FROM pg_namespace WHERE nspname = 'df';
