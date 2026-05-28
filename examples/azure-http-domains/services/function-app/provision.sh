#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Provision Azure Function App for domain tests.
# Covers: .azurewebsites.net
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"

APP_NAME="$(derive_funcapp_name "$AHD_BASE_NAME")"
STORAGE="$(derive_funcapp_storage "$AHD_BASE_NAME")"
RG="$AHD_RESOURCE_GROUP"
LOC="$AHD_LOCATION"

echo "Creating storage account for function app: $STORAGE"
az storage account create \
  --name "$STORAGE" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --https-only true \
  --allow-blob-public-access false \
  --output table

echo "Creating function app: $APP_NAME"
az functionapp create \
  --name "$APP_NAME" \
  --resource-group "$RG" \
  --storage-account "$STORAGE" \
  --consumption-plan-location "$LOC" \
  --runtime python \
  --runtime-version 3.11 \
  --functions-version 4 \
  --os-type Linux \
  --output table

APP_URL="https://${APP_NAME}.azurewebsites.net"

upsert_env_var "AHD_FUNCAPP_NAME" "$APP_NAME"
upsert_env_var "AHD_FUNCAPP_URL" "$APP_URL"

echo "Function app provisioned: $APP_URL"
