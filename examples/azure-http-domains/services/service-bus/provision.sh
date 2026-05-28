#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Provision Azure Service Bus namespace + queue for domain tests.
# Covers: .servicebus.windows.net
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"

NAMESPACE="$(derive_servicebus_name "$AHD_BASE_NAME")"
RG="$AHD_RESOURCE_GROUP"
LOC="$AHD_LOCATION"
QUEUE_NAME="pgdtest"

echo "Creating Service Bus namespace: $NAMESPACE (Basic tier)"
az servicebus namespace create \
  --name "$NAMESPACE" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Basic \
  --output table

echo "Creating queue: $QUEUE_NAME"
az servicebus queue create \
  --resource-group "$RG" \
  --namespace-name "$NAMESPACE" \
  --name "$QUEUE_NAME" \
  --output none

upsert_env_var "AHD_SERVICEBUS_NAMESPACE" "$NAMESPACE"
upsert_env_var "AHD_SERVICEBUS_QUEUE" "$QUEUE_NAME"

echo "Service Bus provisioned: $NAMESPACE"
