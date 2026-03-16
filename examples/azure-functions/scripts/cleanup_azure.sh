#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [-g <resource-group>] [-e <env-file>] [-y]"
  echo "Default env file: .azure-functions.env"
  echo "Examples:"
  echo "  $0 -y"
  echo "  $0 -g my-resource-group -y"
}

RESOURCE_GROUP=""
YES="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.azure-functions.env}"

while getopts ":g:e:yh" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    e) ENV_FILE="$OPTARG" ;;
    y) YES="true" ;;
    h) usage; exit 0 ;;
    :) echo "Missing argument for -$OPTARG"; usage; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG"; usage; exit 1 ;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "Error: az CLI not found"; exit 1; }

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Error: resource group not provided and not found in env file."
  echo "Use -g <resource-group> or set AZURE_RESOURCE_GROUP in $ENV_FILE"
  exit 1
fi

if [[ "$YES" != "true" ]]; then
  echo "This will delete Azure resource group '$RESOURCE_GROUP' and all contained resources."
  read -r -p "Type the resource group name to continue: " CONFIRM
  if [[ "$CONFIRM" != "$RESOURCE_GROUP" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "Deleting resource group: $RESOURCE_GROUP"
az group delete --name "$RESOURCE_GROUP" --yes --no-wait

echo "Delete request submitted. Azure may take several minutes to complete."
echo "You can check status with: az group show --name $RESOURCE_GROUP"
