#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Provision Azure Key Vault for domain tests.
# Covers: .vault.azure.net
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"

VAULT_NAME="$(derive_keyvault_name "$AHD_BASE_NAME")"
RG="$AHD_RESOURCE_GROUP"
LOC="$AHD_LOCATION"
SECRET_NAME="pgdurable-test"
SECRET_VALUE="hello-from-azure-http-domains-test"

echo "Creating key vault: $VAULT_NAME"
az keyvault create \
  --name "$VAULT_NAME" \
  --resource-group "$RG" \
  --location "$LOC" \
  --enable-rbac-authorization false \
  --output table

echo "Setting test secret: $SECRET_NAME"
az keyvault secret set \
  --vault-name "$VAULT_NAME" \
  --name "$SECRET_NAME" \
  --value "$SECRET_VALUE" \
  --output none

VAULT_URL="https://${VAULT_NAME}.vault.azure.net"

upsert_env_var "AHD_KEYVAULT_NAME" "$VAULT_NAME"
upsert_env_var "AHD_KEYVAULT_URL" "$VAULT_URL"
upsert_env_var "AHD_KEYVAULT_SECRET_NAME" "$SECRET_NAME"

echo "Key vault provisioned: $VAULT_URL"
