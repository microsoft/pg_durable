import json
from typing import Any

import azure.functions as func


def _json_error(status_code: int, code: str, message: str) -> func.HttpResponse:
    body = {"error": code, "message": message}
    return func.HttpResponse(
        json.dumps(body),
        status_code=status_code,
        mimetype="application/json",
    )


def _validate_payload(payload: dict[str, Any]) -> tuple[int, str, int, int, str | None] | None:
    document_id = payload.get("document_id")
    text = payload.get("text")
    max_tokens = payload.get("max_tokens", 400)
    overlap_tokens = payload.get("overlap_tokens", 40)
    language = payload.get("language")

    if not isinstance(document_id, int):
        return None
    if not isinstance(text, str) or not text.strip():
        return None
    if not isinstance(max_tokens, int) or max_tokens <= 0:
        return None
    if not isinstance(overlap_tokens, int) or overlap_tokens < 0:
        return None
    if overlap_tokens >= max_tokens:
        return None
    if language is not None and not isinstance(language, str):
        return None

    return document_id, text, max_tokens, overlap_tokens, language


def _token_ops():
    """
    Return (encode_fn, decode_fn, model_hint).

    Uses tiktoken when available, otherwise falls back to word-based tokenization.
    The fallback is approximate but keeps the function usable in minimal environments.
    """
    try:
        import tiktoken  # type: ignore

        enc = tiktoken.get_encoding("cl100k_base")
        return enc.encode, enc.decode, "cl100k_base"
    except Exception:

        def encode_fallback(text: str) -> list[str]:
            return text.split()

        def decode_fallback(tokens: list[str]) -> str:
            return " ".join(tokens)

        return encode_fallback, decode_fallback, "whitespace_fallback"


def _chunk_tokens(tokens: list[Any], max_tokens: int, overlap_tokens: int) -> list[tuple[int, int]]:
    windows: list[tuple[int, int]] = []
    step = max_tokens - overlap_tokens
    start = 0

    while start < len(tokens):
        end = min(start + max_tokens, len(tokens))
        windows.append((start, end))
        if end >= len(tokens):
            break
        start += step

    return windows


def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        payload = req.get_json()
    except ValueError:
        return _json_error(400, "validation_error", "request body must be valid JSON")

    if not isinstance(payload, dict):
        return _json_error(400, "validation_error", "request body must be a JSON object")

    validated = _validate_payload(payload)
    if validated is None:
        return _json_error(
            400,
            "validation_error",
            "payload must include valid document_id, text, max_tokens, and overlap_tokens",
        )

    document_id, text, max_tokens, overlap_tokens, _language = validated

    try:
        encode, decode, model_hint = _token_ops()
        tokens = encode(text)
        windows = _chunk_tokens(tokens, max_tokens, overlap_tokens)

        chunks = []
        for i, (start, end) in enumerate(windows):
            chunk_tokens = tokens[start:end]
            chunks.append(
                {
                    "chunk_index": i,
                    "text": decode(chunk_tokens),
                    "token_count": len(chunk_tokens),
                }
            )

        result = {
            "document_id": document_id,
            "model_hint": model_hint,
            "total_tokens": len(tokens),
            "chunks": chunks,
        }

        return func.HttpResponse(
            json.dumps(result),
            status_code=200,
            mimetype="application/json",
        )
    except Exception as exc:
        return _json_error(500, "internal_error", f"unexpected processing failure: {exc}")
