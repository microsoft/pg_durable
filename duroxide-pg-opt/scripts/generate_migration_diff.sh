#!/bin/bash
# Generate a per-function diff markdown file for a specific migration.
# Usage: ./scripts/generate_migration_diff.sh <migration_number>
# Example: ./scripts/generate_migration_diff.sh 9
#
# This script:
# 1. Creates two temp schemas (before/after the target migration)
# 2. Extracts DDL for tables, indexes, and individual functions
# 3. Generates a per-function diff where each changed function is shown IN FULL
#    with +/- markers on changed lines (so the reader always knows which function
#    a change belongs to)
# 4. Cleans up temp schemas
#
# Output: migrations/NNNN_diff.md

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <migration_number>"
    echo "Example: $0 9"
    exit 1
fi

MIGRATION_NUM=$1

# Load DATABASE_URL from .env if it exists
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

if [ -z "$DATABASE_URL" ]; then
    echo "Error: DATABASE_URL not set. Create a .env file or export DATABASE_URL."
    exit 1
fi

# Delegate to Python script which handles per-function diffing correctly
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 "$SCRIPT_DIR/generate_migration_diff.py" "$PROJECT_DIR" "$MIGRATION_NUM" "$DATABASE_URL"
