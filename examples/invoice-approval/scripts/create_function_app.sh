#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail

usage() {
  echo "Usage: $0 [-l <location>]"
  echo "  -l (optional):   Azure location (default: eastus)"
  echo ""
  echo "Creates a resource group, storage account, and Function App."
  echo "Writes settings to .azure-functions.env."
}

LOCATION="eastus"

while getopts ":l:h" opt; do
  case "$opt" in
    l) LOCATION="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "Missing argument for -$OPTARG"; usage; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG"; usage; exit 1 ;;
  esac
done

shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
  usage
  exit 1
fi

RAND5="$(openssl rand -hex 3 | cut -c1-5)"
BASE_NAME="pgd_ex_ia_${RAND5}"

RG="$BASE_NAME"
APP_NAME="$(echo "$RG" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/_+/-/g' \
  | sed -E 's/[^a-z0-9-]//g' \
  | sed -E 's/^-+//; s/-+$//; s/-{2,}/-/g')"

if [[ ${#APP_NAME} -gt 60 ]]; then
  APP_NAME="${APP_NAME:0:60}"
  APP_NAME="$(echo "$APP_NAME" | sed -E 's/-+$//')"
fi
if [[ -z "$APP_NAME" ]]; then
  echo "Error: derived Function App name is empty after sanitization."
  exit 1
fi

command -v az >/dev/null 2>&1 || { echo "Error: az CLI not found"; exit 1; }

STORAGE_NAME="$(echo "$RG" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
if [[ ${#STORAGE_NAME} -lt 3 ]]; then
  STORAGE_NAME="${STORAGE_NAME}ia0"
fi
if [[ ${#STORAGE_NAME} -gt 24 ]]; then
  STORAGE_NAME="${STORAGE_NAME:0:24}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.azure-functions.env}"

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
  upsert_env_var "AZURE_LAST_CREATE_STATUS" "$status"
  upsert_env_var "AZURE_LAST_CREATE_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

run_status "started"
upsert_env_var "AZURE_REQUESTED_BASE_NAME" "$BASE_NAME"

unset_env_var "AZURE_RESOURCE_GROUP"
unset_env_var "AZURE_LOCATION"
unset_env_var "AZURE_FUNCTION_APP_NAME"
unset_env_var "AZURE_STORAGE_ACCOUNT_NAME"
unset_env_var "AZURE_FUNCTION_BASE_URL"
unset_env_var "AZURE_FUNCTION_NAME"
unset_env_var "AZURE_FUNCTION_KEY"

upsert_env_var "AZURE_RESOURCE_GROUP" "$RG"
upsert_env_var "AZURE_LOCATION" "$LOCATION"
upsert_env_var "AZURE_FUNCTION_APP_NAME" "$APP_NAME"
upsert_env_var "AZURE_STORAGE_ACCOUNT_NAME" "$STORAGE_NAME"

echo "Creating/ensuring resource group: $RG"
az group create --name "$RG" --location "$LOCATION" --output table >/dev/null
upsert_env_var "AZURE_RESOURCE_GROUP_CREATED" "true"

echo "Creating storage account: $STORAGE_NAME"
az storage account create \
  --name "$STORAGE_NAME" \
  --location "$LOCATION" \
  --resource-group "$RG" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --https-only true \
  --allow-blob-public-access false \
  --output table >/dev/null
upsert_env_var "AZURE_STORAGE_ACCOUNT_CREATED" "true"

echo "Creating Function App: $APP_NAME"
az functionapp create \
  --name "$APP_NAME" \
  --resource-group "$RG" \
  --storage-account "$STORAGE_NAME" \
  --consumption-plan-location "$LOCATION" \
  --runtime python \
  --runtime-version 3.11 \
  --functions-version 4 \
  --os-type Linux \
  --output table >/dev/null
upsert_env_var "AZURE_FUNCTION_APP_CREATED" "true"

APP_URL="https://${APP_NAME}.azurewebsites.net"

upsert_env_var "AZURE_RESOURCE_GROUP" "$RG"
upsert_env_var "AZURE_LOCATION" "$LOCATION"
upsert_env_var "AZURE_FUNCTION_APP_NAME" "$APP_NAME"
upsert_env_var "AZURE_STORAGE_ACCOUNT_NAME" "$STORAGE_NAME"
upsert_env_var "AZURE_FUNCTION_BASE_URL" "$APP_URL"
run_status "completed"

echo
echo "Function App created."
echo "App URL: $APP_URL"
echo "Resource group: $RG"
echo "Function app:   $APP_NAME"
echo "Storage acct:   $STORAGE_NAME"
echo "Wrote settings to: $ENV_FILE"
echo "Next: run deploy_function.sh to publish code."
