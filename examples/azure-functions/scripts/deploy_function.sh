#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail

usage() {
  echo "Usage: $0"
  echo "  app/resource-group are read from .azure-functions.env"
  echo "  function name defaults to AZURE_FUNCTION_NAME, else chunk_text"
}

APP_NAME=""
RESOURCE_GROUP=""
FUNCTION_NAME="chunk_text"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  usage
  exit 1
fi

command -v func >/dev/null 2>&1 || { echo "Error: Azure Functions Core Tools (func) not found"; exit 1; }
command -v az >/dev/null 2>&1 || { echo "Error: az CLI not found"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FUNC_APP_DIR="$ROOT_DIR/function-app"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.azure-functions.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

APP_NAME="${AZURE_FUNCTION_APP_NAME:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

if [[ -z "$FUNCTION_NAME" && -n "${AZURE_FUNCTION_NAME:-}" ]]; then
  FUNCTION_NAME="$AZURE_FUNCTION_NAME"
fi

if [[ -z "$FUNCTION_NAME" ]]; then
  FUNCTION_NAME="chunk_text"
fi

if [[ -z "$APP_NAME" ]]; then
  echo "Error: AZURE_FUNCTION_APP_NAME not found in .azure-functions.env"
  usage
  exit 1
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Error: AZURE_RESOURCE_GROUP not found in .azure-functions.env"
  usage
  exit 1
fi

upsert_env_var() {
  local key="$1"
  local value="$2"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

unset_env_var() {
  local key="$1"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "/^${key}=/d" "$ENV_FILE"
  fi
}

run_status() {
  local status="$1"
  upsert_env_var "AZURE_LAST_DEPLOY_STATUS" "$status"
  upsert_env_var "AZURE_LAST_DEPLOY_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

run_status "started"
upsert_env_var "AZURE_FUNCTION_NAME" "$FUNCTION_NAME"
unset_env_var "AZURE_FUNCTION_KEY"

if [[ ! -d "$FUNC_APP_DIR" ]]; then
  echo "Error: function-app directory not found at $FUNC_APP_DIR"
  exit 1
fi

pushd "$FUNC_APP_DIR" >/dev/null

echo "Publishing function app code to: $APP_NAME"
func azure functionapp publish "$APP_NAME" --python
upsert_env_var "AZURE_FUNCTION_PUBLISHED" "true"

popd >/dev/null

echo
echo "Deployment completed."
echo "Function endpoint: https://${APP_NAME}.azurewebsites.net/api/${FUNCTION_NAME}"
echo
echo "Fetching function key..."
if ! az functionapp function show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --function-name "$FUNCTION_NAME" \
  --output none >/dev/null 2>&1; then
  echo "Error: Function '$FUNCTION_NAME' was not found in app '$APP_NAME' (resource group '$RESOURCE_GROUP')."
  echo "Tip: wait ~30-60s after publish and retry, or confirm function name."
  exit 1
fi

FUNCTION_KEY="$(az functionapp function keys list \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --function-name "$FUNCTION_NAME" \
  --query default \
  -o tsv)"

if [[ -z "$FUNCTION_KEY" ]]; then
  echo "Error: Function key retrieval returned empty for '$FUNCTION_NAME'."
  echo "Try again in 30-60s; key creation can lag immediately after deployment."
  exit 1
fi

BASE_URL="https://${APP_NAME}.azurewebsites.net"
upsert_env_var "AZURE_RESOURCE_GROUP" "$RESOURCE_GROUP"
upsert_env_var "AZURE_FUNCTION_APP_NAME" "$APP_NAME"
upsert_env_var "AZURE_FUNCTION_NAME" "$FUNCTION_NAME"
upsert_env_var "AZURE_FUNCTION_BASE_URL" "$BASE_URL"
upsert_env_var "AZURE_FUNCTION_KEY" "$FUNCTION_KEY"
run_status "completed"

echo "Function key retrieved."
echo "Use this in SQL vars setup:"
echo "  resource_group          = ${RESOURCE_GROUP}"
echo "  azure_function_base_url = ${BASE_URL}"
echo "  azure_function_key      = ${FUNCTION_KEY}"
echo
echo "Saved deployment settings to: $ENV_FILE"
