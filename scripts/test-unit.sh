#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# test-unit.sh - Run pgrx unit tests
#
# Usage: ./scripts/test-unit.sh [options] [test_filter]
#
# Options:
#   --pg-version VER  PostgreSQL major version (default: 17)
#
# Examples:
#   ./scripts/test-unit.sh              # Run all unit tests
#   ./scripts/test-unit.sh simple       # Run tests matching "simple"
#   ./scripts/test-unit.sh --pg-version 18

set -e

cd "$(dirname "$0")/.."

PG_VERSION="17"
TEST_FILTER=""
FEATURES=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --pg-version)
            PG_VERSION="$2"
            shift 2
            ;;
        --features)
            FEATURES="$2"
            shift 2
            ;;
        *)
            TEST_FILTER="$1"
            shift
            ;;
    esac
done

echo "================================================"
echo "pg_durable Unit Tests (pgrx) — PG${PG_VERSION}"
if [ -n "$FEATURES" ]; then
    echo "Features: $FEATURES"
fi
echo "================================================"
echo ""

FEATURES_ARG=""
if [ -n "$FEATURES" ]; then
    FEATURES_ARG="--features $FEATURES"
fi

if [ -n "$TEST_FILTER" ]; then
    echo "Filter: $TEST_FILTER"
    cargo pgrx test "pg${PG_VERSION}" $FEATURES_ARG -- "$TEST_FILTER"
else
    cargo pgrx test "pg${PG_VERSION}" $FEATURES_ARG
fi

