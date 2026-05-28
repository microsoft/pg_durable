#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# pg-reset.sh - Reset local PostgreSQL data (wipe everything)
#
# Usage: ./scripts/pg-reset.sh [pg_major_version]
#
# Arguments:
#   pg_major_version  PostgreSQL major version number (default: 17)

set -e

PG_MAJOR="${1:-17}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$HOME/.pgrx/data-$PG_MAJOR"

cd "$PROJECT_DIR"

echo -e "\033[0;33mStopping PostgreSQL if running...\033[0m"
cargo pgrx stop "pg${PG_MAJOR}" 2>/dev/null || true

echo -e "\033[0;33mRemoving data directory: $DATA_DIR\033[0m"
rm -rf "$DATA_DIR"

echo -e "\033[0;33mClearing log file...\033[0m"
rm -f "$HOME/.pgrx/${PG_MAJOR}.log"

echo -e "\033[0;32mPostgreSQL data and logs wiped.\033[0m"
echo ""
echo "Run ./scripts/pg-start.sh to start fresh."

