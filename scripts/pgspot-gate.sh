#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# pgspot-gate.sh - Project entry point for the pgspot SQL security gate.
#
# Scans the generated install SQL plus every active upgrade script, except the
# pre-pgspot legacy scripts listed below. New scripts are gated automatically.
#
# Usage: scripts/pgspot-gate.sh [INSTALL_SQL]
#   INSTALL_SQL  install SQL to scan. Optional (omit when no local pgrx install);
#                CI always generates and passes it. Without it, only upgrade
#                scripts are scanned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL_DIR="$PROJECT_DIR/sql"

install_sql="${1:-}"

# Released upgrade scripts authored before the install DDL was schema-qualified.
# They are immutable and don't all pass pgspot, so they're excluded. Scripts
# written after qualification pass the gate, so they need no entry here.
EXCLUDE=(
  pg_durable--0.1.1--0.2.0.sql
  pg_durable--0.2.0--0.2.1.sql
  pg_durable--0.2.1--0.2.2.sql
)

is_excluded() {
  local base="$1" e
  for e in "${EXCLUDE[@]}"; do
    [[ "$base" == "$e" ]] && return 0
  done
  return 1
}

# Upgrade scripts (basename `*--*--*.sql`; the single-`--` first-version fixture
# never matches), minus the excluded legacy ones.
targets=()
shopt -s nullglob
for f in "$SQL_DIR"/pg_durable--*--*.sql; do
  base="$(basename "$f")"
  if is_excluded "$base"; then
    echo "excluded (pre-pgspot): $base"
    continue
  fi
  targets+=("$f")
done
shopt -u nullglob

scan=()
if [[ -n "$install_sql" ]]; then
  if [[ ! -f "$install_sql" ]]; then
    echo "ERROR: install SQL not found: $install_sql" >&2
    exit 2
  fi
  scan+=("$install_sql")
else
  echo "NOTE: no install SQL provided; scanning upgrade scripts only." >&2
fi
scan+=("${targets[@]}")

if [[ ${#scan[@]} -eq 0 ]]; then
  echo "ERROR: nothing to scan (no install SQL and no gated upgrade scripts)." >&2
  echo "       CI must pass the generated install SQL; an empty scan set fails the gate." >&2
  exit 2
fi

exec "$SCRIPT_DIR/run-pgspot.sh" "${scan[@]}"
