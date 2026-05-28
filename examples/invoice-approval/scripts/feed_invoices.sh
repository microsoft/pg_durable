#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail

usage() {
  echo "Usage: $0 [-d <database>] [-h <host>] [-p <port>] [-U <user>] [-n <count>] [-s <sleep>]"
  echo "  -n  Number of invoices per batch (default: 2)"
  echo "  -s  Seconds between batches, 0 = one-shot (default: 0)"
  echo "Example: $0 -d postgres -p 28817 -n 3 -s 10"
}

DB_NAME="postgres"
PGHOST_VAL="${PGHOST:-localhost}"
PGPORT_VAL="${PGPORT:-28817}"
PGUSER_VAL="${PGUSER:-postgres}"
BATCH_SIZE=2
SLEEP_SEC=0

while getopts ":d:h:p:U:n:s:?" opt; do
  case "$opt" in
    d) DB_NAME="$OPTARG" ;;
    h) PGHOST_VAL="$OPTARG" ;;
    p) PGPORT_VAL="$OPTARG" ;;
    U) PGUSER_VAL="$OPTARG" ;;
    n) BATCH_SIZE="$OPTARG" ;;
    s) SLEEP_SEC="$OPTARG" ;;
    ?) usage; exit 0 ;;
    :) echo "Missing argument for -$OPTARG"; usage; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG"; usage; exit 1 ;;
  esac
done

resolve_psql() {
  if [[ -n "${PSQL_BIN:-}" ]] && [[ -x "$PSQL_BIN" ]]; then
    echo "$PSQL_BIN"
    return 0
  fi
  if command -v psql >/dev/null 2>&1; then
    command -v psql
    return 0
  fi
  local pgrx_psql=""
  pgrx_psql="$(ls -1d "$HOME"/.pgrx/*/pgrx-install/bin/psql 2>/dev/null | head -n 1 || true)"
  if [[ -n "$pgrx_psql" && -x "$pgrx_psql" ]]; then
    echo "$pgrx_psql"
    return 0
  fi
  echo "Error: psql not found" >&2
  return 1
}

PSQL_CMD="$(resolve_psql)"

export PGHOST="$PGHOST_VAL"
export PGPORT="$PGPORT_VAL"
export PGUSER="$PGUSER_VAL"

# Realistic invoice descriptions and amounts
DESCRIPTIONS=(
  "Contoso Ltd - Annual software license renewal"
  "Northwind Traders - Office furniture order"
  "Fabrikam Inc - Cloud infrastructure advisory engagement"
  "AdventureWorks - Marketing campaign Q3"
  "WideWorld Importers - Server hardware procurement"
  "Tailspin Toys - Travel expenses reimbursement"
  "Alpine Ski House - Facility maintenance contract"
  "Proseware Inc - Data analytics consulting retainer"
  "Trey Research - Laboratory supplies quarterly order"
  "Consolidated Messenger - Advertising sponsorship deal"
  "Graphic Design Institute - SaaS subscription bundle"
  "Litware Inc - Network equipment upgrade"
)

AMOUNTS=(
  "\$1,250.00"
  "\$4,890.00"
  "\$18,750.00"
  "\$7,200.00"
  "\$32,400.00"
  "\$950.00"
  "\$3,100.00"
  "\$45,000.00"
  "\$2,340.00"
  "\$15,500.00"
  "\$6,780.00"
  "\$28,900.00"
)

insert_batch() {
  local count="$1"
  local total="${#DESCRIPTIONS[@]}"
  local sql="INSERT INTO demo.invoices (description, raw_amount) VALUES"
  local sep=""

  for (( i=0; i<count; i++ )); do
    local idx=$(( RANDOM % total ))
    local desc="${DESCRIPTIONS[$idx]}"
    local amt="${AMOUNTS[$idx]}"
    sql+="${sep} ('${desc}', '${amt}')"
    sep=","
  done
  sql+=" RETURNING id, description, raw_amount, status;"

  echo "--- Inserting $count invoice(s) ---"
  "$PSQL_CMD" -d "$DB_NAME" -c "$sql"
}

insert_batch "$BATCH_SIZE"

if [[ "$SLEEP_SEC" -gt 0 ]]; then
  echo "Continuous mode: inserting $BATCH_SIZE invoice(s) every ${SLEEP_SEC}s. Ctrl-C to stop."
  while true; do
    sleep "$SLEEP_SEC"
    insert_batch "$BATCH_SIZE"
  done
fi
