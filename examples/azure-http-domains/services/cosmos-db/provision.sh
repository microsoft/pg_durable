#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Provision Azure Cosmos DB (serverless, NoSQL) for domain tests.
# Covers: .documents.azure.com
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"

ACCOUNT_NAME="$(derive_cosmos_name "$AHD_BASE_NAME")"
RG="$AHD_RESOURCE_GROUP"
LOC="$AHD_LOCATION"
DB_NAME="pgdtest"

echo "Creating Cosmos DB account (serverless): $ACCOUNT_NAME"
echo "  (This may take 3-5 minutes...)"
az cosmosdb create \
  --name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --locations regionName="$LOC" failoverPriority=0 \
  --capabilities EnableServerless \
  --default-consistency-level Session \
  --output table

echo "Creating database: $DB_NAME"
az cosmosdb sql database create \
  --account-name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --name "$DB_NAME" \
  --output none

COSMOS_URL="https://${ACCOUNT_NAME}.documents.azure.com"

# Grant the signed-in identity Cosmos DB Built-in Data Reader so AAD tokens work.
PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv)"
echo "Assigning Cosmos DB Built-in Data Reader to $PRINCIPAL_ID"
az cosmosdb sql role assignment create \
  --account-name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --role-definition-id 00000000-0000-0000-0000-000000000001 \
  --principal-id "$PRINCIPAL_ID" \
  --scope "/" \
  --output none

upsert_env_var "AHD_COSMOS_ACCOUNT" "$ACCOUNT_NAME"
upsert_env_var "AHD_COSMOS_URL" "$COSMOS_URL"
upsert_env_var "AHD_COSMOS_DB" "$DB_NAME"

echo "Cosmos DB provisioned: $COSMOS_URL"
