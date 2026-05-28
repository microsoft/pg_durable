#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail

usage() {
  echo "Usage: $0 [-u <base-url>] [-k <function-key>] [-e <env-file>] [-d <database>] [-h <host>] [-p <port>] [-U <user>]"
  echo "Example (auto-read .env): $0 -d postgres -h localhost -p 28817 -U postgres"
  echo "Example (manual override): $0 -u https://my-func.azurewebsites.net -k abc123 -d postgres"
  echo "Optional: set PSQL_BIN to a specific psql path (for example ~/.pgrx/.../bin/psql)"
}

BASE_URL=""
FUNCTION_KEY=""
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

BASE_URL="${AZURE_FUNCTION_BASE_URL:-$BASE_URL}"
FUNCTION_KEY="${AZURE_FUNCTION_KEY:-$FUNCTION_KEY}"

while getopts ":u:k:e:d:h:p:U:?" opt; do
  case "$opt" in
    u) BASE_URL="$OPTARG" ;;
    k) FUNCTION_KEY="$OPTARG" ;;
    e) ENV_FILE="$OPTARG"
       if [[ -f "$ENV_FILE" ]]; then
         # shellcheck disable=SC1090
         source "$ENV_FILE"
         BASE_URL="${AZURE_FUNCTION_BASE_URL:-$BASE_URL}"
         FUNCTION_KEY="${AZURE_FUNCTION_KEY:-$FUNCTION_KEY}"
       else
         echo "Error: env file not found: $ENV_FILE"
         exit 1
       fi
       ;;
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
  echo "Error: missing base URL or function key."
  if [[ -f "$ENV_FILE" ]]; then
    echo "Checked env file: $ENV_FILE"
  else
    echo "Env file not found: $ENV_FILE"
  fi
  echo "Run deploy_function.sh first, or pass -u and -k explicitly."
  usage
  exit 1
fi

resolve_psql() {
  if [[ -n "${PSQL_BIN:-}" ]]; then
    if [[ -x "$PSQL_BIN" ]]; then
      echo "$PSQL_BIN"
      return 0
    fi
    echo "Error: PSQL_BIN is set but not executable: $PSQL_BIN" >&2
    return 1
  fi

  if command -v psql >/dev/null 2>&1; then
    command -v psql
    return 0
  fi

  local pgrx_psql=""
  pgrx_psql="$(ls -1d "$HOME"/.pgrx/*/pgrx-install/bin/psql 2>/dev/null | head -n 1 || true)"
  if [[ -n "$pgrx_psql" && -x "$pgrx_psql" ]]; then
    echo "$pgrx_psql"
    return 0
  fi

  echo "Error: psql not found on PATH and no pgrx psql discovered." >&2
  echo "Set PSQL_BIN=/home/vscode/.pgrx/<version>/pgrx-install/bin/psql and retry." >&2
  return 1
}

PSQL_CMD="$(resolve_psql)"

export PGHOST="$PGHOST_VAL"
export PGPORT="$PGPORT_VAL"
export PGUSER="$PGUSER_VAL"

export AZURE_FUNCTION_BASE_URL="$BASE_URL"
export AZURE_FUNCTION_KEY="$FUNCTION_KEY"

"$PSQL_CMD" -d "$DB_NAME" -f "$ROOT_DIR/sql/02_set_vars.sql"

echo "pg_durable variables configured for the current SQL session context (psql: $PSQL_CMD)."
