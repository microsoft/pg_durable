#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
#
# Live probe against the provisioned Azure OpenAI deployments. Not CI-safe:
# needs real credentials and spends quota.
#
# This verifies the two facts the example depends on, both of which the
# published API reference gets wrong or leaves ambiguous:
#
#   1. /audio/speech takes a JSON body (the reference's request-body table says
#      multipart/form-data, but the worked example alongside it posts JSON).
#   2. /audio/speech returns audio/mpeg, so pg_durable must capture it as binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$EXAMPLE_DIR/.audio-roundtrip.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "error: $ENV_FILE not found. Run scripts/provision_azure.sh first." >&2
    exit 1
fi

# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

: "${AZURE_OPENAI_ENDPOINT:?not set}"
: "${AZURE_OPENAI_KEY:?not set}"
: "${AZURE_OPENAI_API_VERSION:?not set}"
: "${AZURE_TTS_DEPLOYMENT:?not set}"
: "${AZURE_WHISPER_DEPLOYMENT:?not set}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
AUDIO="$WORK_DIR/speech.mp3"

PHRASE="pg durable makes workflows durable"

echo "[live] Speech: POST /audio/speech with a JSON body"
SPEECH_META="$(curl -sS -X POST \
    "${AZURE_OPENAI_ENDPOINT}openai/deployments/${AZURE_TTS_DEPLOYMENT}/audio/speech?api-version=${AZURE_OPENAI_API_VERSION}" \
    -H "api-key: ${AZURE_OPENAI_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${AZURE_TTS_DEPLOYMENT}\",\"input\":\"${PHRASE}\",\"voice\":\"alloy\",\"response_format\":\"mp3\"}" \
    -o "$AUDIO" \
    -w '%{http_code} %{content_type} %{size_download}')"

read -r SPEECH_CODE SPEECH_TYPE SPEECH_BYTES <<< "$SPEECH_META"
echo "[live]   http=$SPEECH_CODE content_type=$SPEECH_TYPE bytes=$SPEECH_BYTES"

if [[ "$SPEECH_CODE" != "200" ]]; then
    echo "[live] FAILED: speech call returned $SPEECH_CODE" >&2
    head -c 500 "$AUDIO" >&2 || true
    exit 1
fi

if [[ "$SPEECH_TYPE" != audio/* ]]; then
    echo "[live] FAILED: expected an audio/* response, got $SPEECH_TYPE" >&2
    echo "[live] The example assumes a binary speech response; re-check the API version." >&2
    exit 1
fi

if [[ "$SPEECH_BYTES" -lt 1000 ]]; then
    echo "[live] FAILED: speech response was only $SPEECH_BYTES bytes" >&2
    exit 1
fi

echo "[live] Transcription: POST /audio/transcriptions as multipart/form-data"
TRANSCRIPT="$(curl -sS -X POST \
    "${AZURE_OPENAI_ENDPOINT}openai/deployments/${AZURE_WHISPER_DEPLOYMENT}/audio/transcriptions?api-version=${AZURE_OPENAI_API_VERSION}" \
    -H "api-key: ${AZURE_OPENAI_KEY}" \
    -F "file=@${AUDIO};filename=speech.mp3;type=audio/mpeg" \
    -F "model=${AZURE_WHISPER_DEPLOYMENT}")"

echo "[live]   $TRANSCRIPT"

TEXT="$(printf '%s' "$TRANSCRIPT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("text",""))' 2>/dev/null || true)"

if [[ -z "$TEXT" ]]; then
    echo "[live] FAILED: no text in the transcription response" >&2
    echo "[live] A 429 here means the whisper rate limit was hit; retry in a minute." >&2
    exit 1
fi

normalize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

if [[ "$(normalize "$TEXT")" != "$(normalize "$PHRASE")" ]]; then
    echo "[live] FAILED: transcript did not match after normalization" >&2
    echo "[live]   sent: $PHRASE" >&2
    echo "[live]   got:  $TEXT" >&2
    exit 1
fi

echo "[live] Live smoke checks passed: round trip returned '$TEXT'"
