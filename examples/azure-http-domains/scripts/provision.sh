#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Provision Azure resources for HTTP domain tests.
#
# Usage:
#   ./scripts/provision.sh                    # provision all services
#   ./scripts/provision.sh storage-account    # provision one service
#   ./scripts/provision.sh -l westus2         # set Azure location
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: $0 [-l <location>] [<service>]"
  echo "  -l   Azure location (default: eastus)"
  echo ""
  echo "Services: ${IMPLEMENTED_SERVICES[*]}"
  echo "Omit <service> to provision all."
}

LOCATION="eastus"
TARGET_SERVICE=""

while getopts ":l:h" opt; do
  case "$opt" in
    l) LOCATION="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "Missing argument for -$OPTARG"; usage; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG"; usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -gt 1 ]]; then usage; exit 1; fi
if [[ $# -eq 1 ]]; then
  TARGET_SERVICE="$1"
  validate_service_name "$TARGET_SERVICE"
fi

command -v az >/dev/null 2>&1 || { echo "Error: az CLI not found. Run 'az login' first."; exit 1; }

# ---- Resource group (shared by all services) ----

load_env

if [[ -n "${AHD_RESOURCE_GROUP:-}" && -n "${AHD_BASE_NAME:-}" ]]; then
  echo "Reusing existing resource group: $AHD_RESOURCE_GROUP"
  BASE_NAME="$AHD_BASE_NAME"
  RG="$AHD_RESOURCE_GROUP"
  LOCATION="${AHD_LOCATION:-$LOCATION}"
else
  BASE_NAME="$(generate_base_name)"
  RG="pgd-http-${BASE_NAME#pgdhttp}"   # e.g. pgd-http-1a2b3
  upsert_env_var "AHD_BASE_NAME" "$BASE_NAME"
  upsert_env_var "AHD_RESOURCE_GROUP" "$RG"
  upsert_env_var "AHD_LOCATION" "$LOCATION"

  echo "Creating resource group: $RG (location: $LOCATION)"
  az group create --name "$RG" --location "$LOCATION" --output table
fi

# ---- Provision services ----

provision_service() {
  local svc="$1"
  local svc_script="$SERVICES_DIR/$svc/provision.sh"
  if [[ ! -x "$svc_script" ]]; then
    echo "Warning: $svc_script not found or not executable, skipping."
    return 0
  fi
  echo ""
  echo "========================================"
  echo "Provisioning: $svc"
  echo "========================================"
  # Export variables the service scripts need.
  export AHD_BASE_NAME="$BASE_NAME"
  export AHD_RESOURCE_GROUP="$RG"
  export AHD_LOCATION="$LOCATION"
  export ENV_FILE
  bash "$svc_script"
}

if [[ -n "$TARGET_SERVICE" ]]; then
  provision_service "$TARGET_SERVICE"
else
  for svc in "${IMPLEMENTED_SERVICES[@]}"; do
    provision_service "$svc"
  done
fi

echo ""
echo "Provisioning complete. Credentials in: $ENV_FILE"
echo "Next: ./scripts/run-test.sh"
