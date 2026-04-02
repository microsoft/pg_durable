#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [-d <database>] [-h <host>] [-p <port>] [-U <user>]"
  echo "Runs a quick smoke-check against the deployed Azure Function."
}

DB_NAME="postgres"
PGHOST_VAL="${PGHOST:-localhost}"
PGPORT_VAL="${PGPORT:-28817}"
PGUSER_VAL="${PGUSER:-postgres}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.azure-functions.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

BASE_URL="${AZURE_FUNCTION_BASE_URL:-}"
FUNCTION_KEY="${AZURE_FUNCTION_KEY:-}"

while getopts ":d:h:p:U:?" opt; do
  case "$opt" in
    d) DB_NAME="$OPTARG" ;;
    h) PGHOST_VAL="$OPTARG" ;;
    p) PGPORT_VAL="$OPTARG" ;;
    U) PGUSER_VAL="$OPTARG" ;;
    ?) usage; exit 0 ;;
    :) echo "Missing argument for -$OPTARG"; usage; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG"; usage; exit 1 ;;
  esac
done

if [[ -z "$BASE_URL" || -z "$FUNCTION_KEY" ]]; then
  echo "Error: missing AZURE_FUNCTION_BASE_URL or AZURE_FUNCTION_KEY."
  echo "Run deploy_function.sh first."
  exit 1
fi

echo "Smoke-checking: ${BASE_URL}/api/classify_invoice"
RESPONSE=$(curl -s -X POST \
  "${BASE_URL}/api/classify_invoice" \
  -H "Content-Type: application/json" \
  -H "x-functions-key: ${FUNCTION_KEY}" \
  -d '{"invoice_id": 1, "description": "Acme Corp - Office supplies order", "raw_amount": "$3,420.00"}')

echo "Response: $RESPONSE"

if echo "$RESPONSE" | grep -q '"amount"'; then
  echo "Smoke check PASSED."
else
  echo "Smoke check FAILED — expected 'amount' in response."
  exit 1
fi
