#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
#
# Provision the Azure OpenAI resources this example needs and write a local
# .audio-roundtrip.env file. Requires an existing `az login`.
#
# Everything lands in a single resource group so cleanup_azure.sh can remove it
# all in one call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-pg-durable-audio-roundtrip}"
# Both `tts` and `whisper` must exist in the same region. northcentralus and
# swedencentral are the two that currently carry both on the plain Standard SKU.
# westeurope has whisper but no tts; eastus2 has whisper but only the
# GlobalStandard gpt-4o-mini-tts. Verify before changing this:
#   az cognitiveservices model list -l <region> \
#     --query "[?model.name=='tts' || model.name=='whisper'].model.name" -o tsv
LOCATION="${LOCATION:-northcentralus}"
ACCOUNT_NAME="${ACCOUNT_NAME:-oai-pgdurable-audio-$RANDOM}"
TTS_DEPLOYMENT="${TTS_DEPLOYMENT:-tts}"
WHISPER_DEPLOYMENT="${WHISPER_DEPLOYMENT:-whisper}"
API_VERSION="${API_VERSION:-2025-04-01-preview}"
# Whisper quota is granted per subscription, not per deployment, and the default
# limit is 3 requests per minute. Asking for more than the subscription allows
# fails with InsufficientQuota.
WHISPER_CAPACITY="${WHISPER_CAPACITY:-3}"
TTS_CAPACITY="${TTS_CAPACITY:-1}"

ENV_FILE="$EXAMPLE_DIR/.audio-roundtrip.env"

if ! command -v az > /dev/null 2>&1; then
    echo "error: the Azure CLI (az) is not installed" >&2
    exit 1
fi

if ! az account show > /dev/null 2>&1; then
    echo "error: not logged in. Run 'az login' first." >&2
    exit 1
fi

echo "[provision] Subscription: $(az account show --query name -o tsv)"
echo "[provision] Resource group: $RESOURCE_GROUP ($LOCATION)"

# Preflight the model quotas before creating anything. Both tts and whisper
# quota are granted per *subscription* per region, not per deployment, so an
# unrelated deployment elsewhere in the subscription can exhaust them. Checking
# up front avoids a half-provisioned resource group: without this, a whisper
# shortfall surfaces only after the group, the account and the tts deployment
# have already been created and started billing.
check_quota() {
    local quota_name="$1" wanted="$2" usage available
    usage="$(az cognitiveservices usage list -l "$LOCATION" \
        --query "[?name.value=='${quota_name}'].{c:currentValue, l:limit}" \
        -o tsv 2>/dev/null || true)"

    if [[ -z "$usage" ]]; then
        echo "[provision] warning: could not read '$quota_name' quota in $LOCATION; continuing" >&2
        return 0
    fi

    available="$(awk '{printf "%d", $2 - $1}' <<< "$usage")"
    if (( available < wanted )); then
        cat >&2 <<MSG
error: not enough '$quota_name' quota in $LOCATION.
       Need $wanted, only $available available (used/limit: $(tr '\t' '/' <<< "$usage")).

       This quota is per subscription per region, so another deployment is
       likely holding it. Options:
         - free it:      az cognitiveservices account deployment delete \\
                             -n <account> -g <group> --deployment-name <name>
         - use a region with spare quota:  LOCATION=swedencentral $0
         - request an increase:            https://aka.ms/oai/quotaincrease
MSG
        exit 1
    fi
    echo "[provision] Quota OK: $quota_name ($available available, need $wanted)"
}

check_quota "OpenAI.Standard.tts" "$TTS_CAPACITY"
check_quota "OpenAI.Standard.whisper" "$WHISPER_CAPACITY"

az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none

echo "[provision] Creating Azure OpenAI account: $ACCOUNT_NAME"
# --custom-domain is what produces an *.openai.azure.com endpoint. Without it
# the account gets a *.cognitiveservices.azure.com endpoint instead; both are on
# the pg_durable allowlist, but the URLs in this example assume the former.
az cognitiveservices account create \
    -n "$ACCOUNT_NAME" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --kind OpenAI \
    --sku S0 \
    --custom-domain "$ACCOUNT_NAME" \
    --yes \
    -o none

echo "[provision] Deploying $TTS_DEPLOYMENT (tts:001, capacity $TTS_CAPACITY)"
az cognitiveservices account deployment create \
    -n "$ACCOUNT_NAME" \
    -g "$RESOURCE_GROUP" \
    --deployment-name "$TTS_DEPLOYMENT" \
    --model-name tts \
    --model-version 001 \
    --model-format OpenAI \
    --sku-name Standard \
    --sku-capacity "$TTS_CAPACITY" \
    -o none

echo "[provision] Deploying $WHISPER_DEPLOYMENT (whisper:001, capacity $WHISPER_CAPACITY)"
az cognitiveservices account deployment create \
    -n "$ACCOUNT_NAME" \
    -g "$RESOURCE_GROUP" \
    --deployment-name "$WHISPER_DEPLOYMENT" \
    --model-name whisper \
    --model-version 001 \
    --model-format OpenAI \
    --sku-name Standard \
    --sku-capacity "$WHISPER_CAPACITY" \
    -o none

ENDPOINT="$(az cognitiveservices account show \
    -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" \
    --query properties.endpoint -o tsv)"
KEY="$(az cognitiveservices account keys list \
    -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" \
    --query key1 -o tsv)"

umask 077
cat > "$ENV_FILE" <<EOF
# Generated by scripts/provision_azure.sh — contains a secret, do not commit.
AZURE_OPENAI_ENDPOINT=$ENDPOINT
AZURE_OPENAI_KEY=$KEY
AZURE_OPENAI_API_VERSION=$API_VERSION
AZURE_TTS_DEPLOYMENT=$TTS_DEPLOYMENT
AZURE_WHISPER_DEPLOYMENT=$WHISPER_DEPLOYMENT

# For cleanup_azure.sh
AZURE_RESOURCE_GROUP=$RESOURCE_GROUP
AZURE_ACCOUNT_NAME=$ACCOUNT_NAME
EOF
# umask only constrains newly created files, so tighten explicitly in case the
# env file already existed with looser permissions.
chmod 600 "$ENV_FILE"

echo "[provision] Wrote $ENV_FILE (mode 600)"
echo "[provision] Endpoint: $ENDPOINT"
echo "[provision] Done. Next:"
echo "    set -a && source $ENV_FILE && set +a"
echo "    psql -d postgres -f sql/01_schema.sql"
