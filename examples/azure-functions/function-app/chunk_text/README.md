# Function Design: chunk_text (Python)

This document defines the function behavior contract and matches the implementation in this directory.

## Purpose

Accept one document payload, split text into token-aware chunks, and return chunk metadata in a deterministic JSON format consumable by pg_durable SQL.

## Trigger

- Azure Functions HTTP trigger
- Method: `POST`
- Auth level: Function

## Input

```json
{
  "document_id": 123,
  "text": "<string>",
  "max_tokens": 400,
  "overlap_tokens": 40,
  "language": "en"
}
```

Validation rules:

- `document_id`: required integer
- `text`: required non-empty string
- `max_tokens`: optional positive integer (default to agreed value)
- `overlap_tokens`: optional integer >= 0 and < `max_tokens`
- `language`: optional string

## Output

Success (`200`):

```json
{
  "document_id": 123,
  "model_hint": "cl100k_base",
  "total_tokens": 1842,
  "chunks": [
    {
      "chunk_index": 0,
      "text": "...",
      "token_count": 395
    }
  ]
}
```

Client error (`400`):

```json
{
  "error": "validation_error",
  "message": "overlap_tokens must be less than max_tokens"
}
```

Server error (`500`):

```json
{
  "error": "internal_error",
  "message": "unexpected processing failure"
}
```

## Behavior expectations

- Preserve chunk ordering via `chunk_index`.
- Never return overlapping chunk indexes.
- Return stable JSON keys to simplify SQL parsing.
- Include token counts for downstream storage/analytics.

## Non-goals

- Embedding generation
- classification
- summarization
- any outbound calls to other AI services
