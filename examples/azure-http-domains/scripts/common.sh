#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Common helpers for azure-http-domains tests.
# Sourced by other scripts — do not run directly.

# Service list — add new services here.
IMPLEMENTED_SERVICES=(
  storage-account
  function-app
  key-vault
  service-bus
  cognitive-services
  cosmos-db
)

# ---------------------------------------------------------------------------
# Directory helpers
# ---------------------------------------------------------------------------

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
SERVICES_DIR="$EXAMPLE_ROOT/services"
ENV_FILE="${ENV_FILE:-$EXAMPLE_ROOT/.azure-http-domains.env}"

# ---------------------------------------------------------------------------
# Env file helpers (same pattern as azure-functions example)
# ---------------------------------------------------------------------------

upsert_env_var() {
  local key="$1" value="$2"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

unset_env_var() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] && sed -i "/^${key}=/d" "$ENV_FILE"
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

# ---------------------------------------------------------------------------
# Naming helpers
# ---------------------------------------------------------------------------

# Generate the random base name (once per provision run).
generate_base_name() {
  local rand5
  rand5="$(openssl rand -hex 3 | cut -c1-5)"
  echo "pgdhttp${rand5}"
}

# Derive Azure-safe resource names from base.
# Storage: 3-24 lowercase alphanum.  Key Vault: 3-24 alphanum + hyphen.
# Function App: alphanum + hyphen, <= 60 chars.
derive_storage_name()  { echo "${1}"; }        # e.g. pgdhttp1a2b3
derive_funcapp_name()  { echo "${1}-func"; }    # e.g. pgdhttp1a2b3-func
derive_funcapp_storage() { echo "${1}fn"; }     # e.g. pgdhttp1a2b3fn
derive_keyvault_name() { echo "${1}-kv"; }      # e.g. pgdhttp1a2b3-kv
derive_servicebus_name() { echo "${1}"; }    # e.g. pgdhttp1a2b3 ("-sb" suffix is reserved)
derive_cognitive_name() { echo "${1}-lang"; }   # e.g. pgdhttp1a2b3-lang
derive_cosmos_name()   { echo "${1}-cdb"; }  # e.g. pgdhttp1a2b3-cdb

# ---------------------------------------------------------------------------
# psql discovery (same as azure-functions example)
# ---------------------------------------------------------------------------

resolve_psql() {
  if [[ -n "${PSQL_BIN:-}" && -x "$PSQL_BIN" ]]; then
    echo "$PSQL_BIN"; return 0
  fi
  if command -v psql >/dev/null 2>&1; then
    command -v psql; return 0
  fi
  local p
  p="$(ls -1d "$HOME"/.pgrx/*/pgrx-install/bin/psql 2>/dev/null | head -n 1 || true)"
  if [[ -n "$p" && -x "$p" ]]; then
    echo "$p"; return 0
  fi
  echo "Error: psql not found. Set PSQL_BIN or add psql to PATH." >&2
  return 1
}

# ---------------------------------------------------------------------------
# Service validation
# ---------------------------------------------------------------------------

validate_service_name() {
  local name="$1"
  for s in "${IMPLEMENTED_SERVICES[@]}"; do
    [[ "$s" == "$name" ]] && return 0
  done
  echo "Error: unknown service '$name'. Available: ${IMPLEMENTED_SERVICES[*]}" >&2
  return 1
}
