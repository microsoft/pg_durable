#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
#
# Delete everything provision_azure.sh created.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$EXAMPLE_DIR/.audio-roundtrip.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a && source "$ENV_FILE" && set +a
fi

RESOURCE_GROUP="${RESOURCE_GROUP:-${AZURE_RESOURCE_GROUP:-rg-pg-durable-audio-roundtrip}}"

if ! az account show > /dev/null 2>&1; then
    echo "error: not logged in. Run 'az login' first." >&2
    exit 1
fi

if ! az group exists -n "$RESOURCE_GROUP" | grep -q true; then
    echo "[cleanup] Resource group $RESOURCE_GROUP does not exist, nothing to do"
    exit 0
fi

echo "[cleanup] About to delete resource group: $RESOURCE_GROUP"
az resource list -g "$RESOURCE_GROUP" --query "[].[name, type]" -o tsv || true

read -r -p "Delete this resource group and everything in it? [y/N] " reply
# Anything that is not an explicit yes aborts, so a stray keystroke cannot
# delete the group.
case "${reply,,}" in
    y | yes) ;;
    *)
        echo "[cleanup] Aborted"
        exit 0
        ;;
esac

# Discover the account name before deleting, so the soft-deleted resource can be
# purged afterwards even when no env file recorded it.
ACCOUNT_NAME="${AZURE_ACCOUNT_NAME:-$(az cognitiveservices account list \
    -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)}"
ACCOUNT_LOCATION="$(az cognitiveservices account show \
    -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)"

echo "[cleanup] Deleting resource group (this takes a couple of minutes)"
az group delete -n "$RESOURCE_GROUP" --yes

# Deleting the group only soft-deletes the Azure OpenAI account, and a
# soft-deleted account continues to hold its model quota. Quota is granted per
# subscription per region, so skipping the purge leaves the next provision run
# failing with InsufficientQuota. Purge rather than just printing the command.
if [[ -n "$ACCOUNT_NAME" ]]; then
    echo "[cleanup] Purging soft-deleted account $ACCOUNT_NAME to release its quota"
    if az cognitiveservices account purge \
        -n "$ACCOUNT_NAME" \
        -g "$RESOURCE_GROUP" \
        -l "${ACCOUNT_LOCATION:-${LOCATION:-northcentralus}}" -o none 2>/dev/null; then
        echo "[cleanup] Purged $ACCOUNT_NAME"
    else
        echo "[cleanup] warning: purge failed. The account stays soft-deleted and keeps" >&2
        echo "          holding quota. Retry with:" >&2
        echo "    az cognitiveservices account purge -n $ACCOUNT_NAME \\" >&2
        echo "        -g $RESOURCE_GROUP -l ${ACCOUNT_LOCATION:-${LOCATION:-northcentralus}}" >&2
    fi
else
    echo "[cleanup] warning: could not determine the account name; if a soft-deleted" >&2
    echo "          account remains it will keep holding quota. List them with:" >&2
    echo "    az cognitiveservices account list-deleted -o table" >&2
fi

if [[ -f "$ENV_FILE" ]]; then
    rm -f "$ENV_FILE"
    echo "[cleanup] Removed $ENV_FILE"
fi

echo "[cleanup] Done"
