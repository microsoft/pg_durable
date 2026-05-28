#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Delete the shared resource group (and all contained Azure resources).
#
# Usage:
#   ./scripts/cleanup.sh        # interactive confirmation
#   ./scripts/cleanup.sh -y     # skip confirmation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

YES="false"

while getopts ":yh" opt; do
  case "$opt" in
    y) YES="true" ;;
    h) echo "Usage: $0 [-y]"; exit 0 ;;
    :) echo "Missing argument for -$OPTARG"; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG"; exit 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "Error: az CLI not found"; exit 1; }

load_env

RG="${AHD_RESOURCE_GROUP:-}"
if [[ -z "$RG" ]]; then
  echo "Error: AHD_RESOURCE_GROUP not set. Nothing to clean up."
  echo "Check $ENV_FILE"
  exit 1
fi

if [[ "$YES" != "true" ]]; then
  echo "This will delete resource group '$RG' and ALL contained resources."
  read -r -p "Type the resource group name to confirm: " CONFIRM
  if [[ "$CONFIRM" != "$RG" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "Deleting resource group: $RG"
az group delete --name "$RG" --yes --no-wait

echo "Delete request submitted (Azure may take several minutes)."
echo "Check status: az group show --name $RG"

# Clean the env file
if [[ -f "$ENV_FILE" ]]; then
  rm "$ENV_FILE"
  echo "Removed $ENV_FILE"
fi
