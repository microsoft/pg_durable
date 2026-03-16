# SQL Files for Azure Functions Scenario

This directory contains runnable SQL scripts for calling Azure Functions from pg_durable.

## Tables used

- `demo.af_documents`: source rows waiting to be chunked
- `demo.af_document_chunks`: output rows, one per chunk

## Workflow shape

1. Select pending document rows.
2. Build JSON request payload for one document.
3. Call Azure Function via `df.http()`.
4. Validate HTTP envelope (`ok`, `status`).
5. Parse response body JSON and insert chunk rows.
6. Mark source document as processed.

## Variable usage

Set before `df.start()`:

- `azure_function_base_url`
- `azure_function_key`

Use variable substitution in workflow SQL where applicable.

## Error handling

- Handle 4xx in SQL branch logic (bad payload, auth issues).
- Allow 5xx/network failures to fail activity and rely on durable retry behavior.
- Persist concise diagnostics in an audit/log table if needed.

## SQL files

- `01_schema.sql`: demo schema and test data
- `02_set_vars.sql`: endpoint and key setup
- `03_start_workflow.sql`: workflow definition and kickoff
- `04_verify.sql`: result inspection queries

## Notes

The implementation should explicitly parse `df.http()` response envelope fields before reading response body content.
