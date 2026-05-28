#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Provision Azure Storage Account for domain tests.
#
# Covers: .blob.core.windows.net, .blob.storage.azure.net,
#         .queue.core.windows.net, .table.core.windows.net,
#         .file.core.windows.net
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"

ACCOUNT="$(derive_storage_name "$AHD_BASE_NAME")"
RG="$AHD_RESOURCE_GROUP"
LOC="$AHD_LOCATION"

CONTAINER_NAME="pgdtest"
QUEUE_NAME="pgdtest"
TABLE_NAME="pgdtest"
SHARE_NAME="pgdtest"
BLOB_NAME="hello.txt"
BLOB_CONTENT="Hello from pg_durable azure-http-domains test"

echo "Creating storage account: $ACCOUNT"
az storage account create \
  --name "$ACCOUNT" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --https-only true \
  --allow-blob-public-access false \
  --output table

# Get account key for setup operations
ACCOUNT_KEY="$(az storage account keys list \
  --resource-group "$RG" \
  --account-name "$ACCOUNT" \
  --query '[0].value' -o tsv)"

# Create test fixtures
echo "Creating blob container: $CONTAINER_NAME"
az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --output none

echo "Uploading test blob: $BLOB_NAME"
UPLOAD_FILE="$(mktemp)"
trap 'rm -f "$UPLOAD_FILE"' EXIT
printf '%s\n' "$BLOB_CONTENT" > "$UPLOAD_FILE"
az storage blob upload \
  --container-name "$CONTAINER_NAME" \
  --name "$BLOB_NAME" \
  --account-name "$ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --type block \
  --overwrite \
  --file "$UPLOAD_FILE" \
  --output none

echo "Creating queue: $QUEUE_NAME"
az storage queue create \
  --name "$QUEUE_NAME" \
  --account-name "$ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --output none

echo "Creating table: $TABLE_NAME"
az storage table create \
  --name "$TABLE_NAME" \
  --account-name "$ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --output none

echo "Creating file share: $SHARE_NAME"
az storage share create \
  --name "$SHARE_NAME" \
  --account-name "$ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --output none

# Generate account SAS valid for 24 hours, covering all services
EXPIRY="$(date -u -d '+24 hours' +%Y-%m-%dT%H:%MZ)"
SAS="$(az storage account generate-sas \
  --account-name "$ACCOUNT" \
  --account-key "$ACCOUNT_KEY" \
  --services bqtf \
  --resource-types sco \
  --permissions rwdlacup \
  --expiry "$EXPIRY" \
  --https-only \
  -o tsv)"

# Write to env
upsert_env_var "AHD_STORAGE_ACCOUNT" "$ACCOUNT"
upsert_env_var "AHD_STORAGE_SAS" "$SAS"
upsert_env_var "AHD_STORAGE_CONTAINER" "$CONTAINER_NAME"
upsert_env_var "AHD_STORAGE_BLOB" "$BLOB_NAME"
upsert_env_var "AHD_STORAGE_QUEUE" "$QUEUE_NAME"
upsert_env_var "AHD_STORAGE_TABLE" "$TABLE_NAME"
upsert_env_var "AHD_STORAGE_SHARE" "$SHARE_NAME"

echo "Storage account provisioned: $ACCOUNT"
echo "SAS valid until: $EXPIRY"
