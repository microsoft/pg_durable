#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# pgspot-gate.sh - Project entry point for the pgspot SQL security gate.
#
# Scans the generated install SQL plus every active upgrade script NOT in the
# frozen baseline (sql/pgspot-frozen.txt). New scripts are gated automatically;
# released ones are exempt.
#
# Usage: scripts/pgspot-gate.sh [INSTALL_SQL]
#   INSTALL_SQL  install SQL to scan. Optional (omit when no local pgrx install);
#                CI always generates and passes it. Without it, only non-frozen
#                upgrade scripts are scanned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL_DIR="$PROJECT_DIR/sql"
FROZEN_LIST="$SQL_DIR/pgspot-frozen.txt"

install_sql="${1:-}"

# Build the set of frozen (exempt) upgrade-script basenames.
declare -A frozen=()
if [[ -f "$FROZEN_LIST" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    frozen["$line"]=1
  done < "$FROZEN_LIST"
fi

# Non-frozen upgrade scripts (basename `*--*--*.sql`; the single-`--` first-
# version fixture never matches).
targets=()
shopt -s nullglob
for f in "$SQL_DIR"/pg_durable--*--*.sql; do
  base="$(basename "$f")"
  if [[ -n "${frozen[$base]:-}" ]]; then
    echo "frozen (skip): $base"
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
  echo "NOTE: no install SQL provided; scanning non-frozen upgrade scripts only." >&2
fi
scan+=("${targets[@]}")

if [[ ${#scan[@]} -eq 0 ]]; then
  echo "ERROR: nothing to scan (no install SQL and no non-frozen upgrade scripts)." >&2
  echo "       CI must pass the generated install SQL; an empty scan set fails the gate." >&2
  exit 2
fi

exec "$SCRIPT_DIR/run-pgspot.sh" "${scan[@]}"
