#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Provision Azure Cognitive Services (Language) for domain tests.
# Covers: .cognitiveservices.azure.com
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"

ACCOUNT_NAME="$(derive_cognitive_name "$AHD_BASE_NAME")"
RG="$AHD_RESOURCE_GROUP"
LOC="$AHD_LOCATION"

echo "Creating Cognitive Services account (TextAnalytics): $ACCOUNT_NAME"
az cognitiveservices account create \
  --name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --location "$LOC" \
  --kind TextAnalytics \
  --sku F0 \
  --yes \
  --output table

# Get API key
API_KEY="$(az cognitiveservices account keys list \
  --name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --query 'key1' -o tsv)"

# Read the actual endpoint assigned by Azure (may include a randomised suffix)
ENDPOINT="$(az cognitiveservices account show \
  --name "$ACCOUNT_NAME" \
  --resource-group "$RG" \
  --query 'properties.endpoint' -o tsv | sed 's|/$||')"

upsert_env_var "AHD_COGNITIVE_ACCOUNT" "$ACCOUNT_NAME"
upsert_env_var "AHD_COGNITIVE_ENDPOINT" "$ENDPOINT"
upsert_env_var "AHD_COGNITIVE_KEY" "$API_KEY"

echo "Cognitive Services provisioned: $ENDPOINT"
