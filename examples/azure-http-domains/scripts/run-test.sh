#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Run df.http() domain tests against a running pg_durable server.
#
# Usage:
#   ./scripts/run-test.sh                        # run all
#   ./scripts/run-test.sh storage-account         # run one
#   ./scripts/run-test.sh -p 28817 key-vault      # custom port
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Usage: $0 [-h <host>] [-p <port>] [-d <database>] [-U <user>] [<service>]"
  echo ""
  echo "  -h   PostgreSQL host (default: localhost)"
  echo "  -p   PostgreSQL port (default: 28817)"
  echo "  -d   Database name  (default: postgres)"
  echo "  -U   User           (default: postgres)"
  echo ""
  echo "Services: ${IMPLEMENTED_SERVICES[*]}"
  echo "Omit <service> to test all provisioned services."
}

PGHOST_VAL="${PGHOST:-localhost}"
PGPORT_VAL="${PGPORT:-28817}"
PGDB_VAL="${PGDATABASE:-postgres}"
PGUSER_VAL="${PGUSER:-postgres}"
TARGET_SERVICE=""

while getopts ":h:p:d:U:?" opt; do
  case "$opt" in
    h) PGHOST_VAL="$OPTARG" ;;
    p) PGPORT_VAL="$OPTARG" ;;
    d) PGDB_VAL="$OPTARG" ;;
    U) PGUSER_VAL="$OPTARG" ;;
    ?) usage; exit 0 ;;
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

PSQL_CMD="$(resolve_psql)"
load_env

export PGHOST="$PGHOST_VAL"
export PGPORT="$PGPORT_VAL"
export PGUSER="$PGUSER_VAL"

# ---- Fetch fresh Azure AD tokens for services that need them ----

fetch_ad_tokens() {
  echo "Fetching Azure AD bearer tokens..."

  if [[ -n "${AHD_KEYVAULT_NAME:-}" ]]; then
    local kv_token
    kv_token="$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv 2>/dev/null || true)"
    if [[ -n "$kv_token" ]]; then
      export AHD_KEYVAULT_TOKEN="$kv_token"
    else
      echo "  Warning: could not get Key Vault token"
    fi
  fi

  if [[ -n "${AHD_SERVICEBUS_NAMESPACE:-}" ]]; then
    local sb_token
    sb_token="$(az account get-access-token --resource https://servicebus.windows.net --query accessToken -o tsv 2>/dev/null || true)"
    if [[ -n "$sb_token" ]]; then
      export AHD_SERVICEBUS_TOKEN="$sb_token"
    else
      echo "  Warning: could not get Service Bus token"
    fi
  fi

  if [[ -n "${AHD_COSMOS_ACCOUNT:-}" ]]; then
    local cosmos_token
    cosmos_token="$(az account get-access-token --resource https://cosmos.azure.com --query accessToken -o tsv 2>/dev/null || true)"
    if [[ -n "$cosmos_token" ]]; then
      export AHD_COSMOS_TOKEN="$cosmos_token"
    else
      echo "  Warning: could not get Cosmos DB token"
    fi
  fi
}

fetch_ad_tokens

# ---- Run tests ----

PASS=0
FAIL=0
SKIP=0

# Maps each service to the env var set by its provision.sh.
# If the var is unset/empty, the service is not provisioned and the test is skipped.
get_provision_var() {
  case "$1" in
    storage-account)    echo "AHD_STORAGE_ACCOUNT" ;;
    function-app)       echo "AHD_FUNCAPP_NAME" ;;
    key-vault)          echo "AHD_KEYVAULT_NAME" ;;
    service-bus)        echo "AHD_SERVICEBUS_NAMESPACE" ;;
    cognitive-services) echo "AHD_COGNITIVE_ACCOUNT" ;;
    cosmos-db)          echo "AHD_COSMOS_ACCOUNT" ;;
  esac
}

run_service_test() {
  local svc="$1"
  local test_sql="$SERVICES_DIR/$svc/test.sql"

  if [[ ! -f "$test_sql" ]]; then
    echo "  SKIP: $svc (no test.sql)"
    SKIP=$((SKIP + 1))
    return 0
  fi

  local provision_var
  provision_var="$(get_provision_var "$svc")"
  if [[ -n "$provision_var" && -z "${!provision_var:-}" ]]; then
    echo "  SKIP: $svc (not provisioned)"
    SKIP=$((SKIP + 1))
    return 0
  fi

  echo ""
  echo "--- Testing: $svc ---"

  local output
  if output=$("$PSQL_CMD" -d "$PGDB_VAL" -X -f "$test_sql" 2>&1); then
    if echo "$output" | grep -q "TEST FAILED"; then
      echo "  FAILED: $svc"
      echo "$output" | grep -i "fail\|error\|exception" | head -5
      FAIL=$((FAIL + 1))
    elif echo "$output" | grep -qP "^\s*psql:.*ERROR:"; then
      echo "  FAILED: $svc (psql error)"
      echo "$output" | grep -P "^\s*psql:.*ERROR:" | head -5
      FAIL=$((FAIL + 1))
    elif echo "$output" | grep -q "TEST PASSED"; then
      echo "  PASSED: $svc"
      PASS=$((PASS + 1))
    else
      echo "  PASSED: $svc (no explicit PASSED marker, but psql succeeded)"
      PASS=$((PASS + 1))
    fi
    # Always show NOTICE lines so callers can see what each sub-test actually did.
    echo "$output" | grep -oP "(?<=NOTICE:  ).*" | sed 's/^/    /'
  else
    echo "  FAILED: $svc"
    echo "$output" | tail -10
    FAIL=$((FAIL + 1))
  fi
}

if [[ -n "$TARGET_SERVICE" ]]; then
  run_service_test "$TARGET_SERVICE"
else
  for svc in "${IMPLEMENTED_SERVICES[@]}"; do
    run_service_test "$svc"
  done
fi

# ---- Summary ----

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "========================================"

[[ "$FAIL" -eq 0 ]]
