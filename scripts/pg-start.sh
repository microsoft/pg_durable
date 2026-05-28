#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# pg-start.sh - Start local PostgreSQL with pg_durable extension
#
# Usage: ./scripts/pg-start.sh [options]
#
# Options:
#   --build            Force build/install even if an existing install is detected
#   --pg-version VER   PostgreSQL major version number (default: 17)

set -e

PG_MAJOR="${PG_MAJOR:-17}"
BUILD_MODE="auto"

usage() {
    echo "Usage: ./scripts/pg-start.sh [--build] [--pg-version VER]"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            BUILD_MODE="force"
            shift
            ;;
        --pg-version)
            if ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                echo "Error: --pg-version requires a numeric argument, got: ${2:-<missing>}"
                usage
                exit 1
            fi
            PG_MAJOR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            echo "Error: Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1"
            echo "Use --pg-version VER to select PostgreSQL major version."
            usage
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./pg-common.sh
. "$SCRIPT_DIR/pg-common.sh"

resolve_pgrx_environment "$PG_MAJOR"

cd "$PROJECT_DIR"

if [ "$BUILD_MODE" = "auto" ]; then
    PKGLIBDIR=$("$PG_CONFIG" --pkglibdir)
    SHAREDIR=$("$PG_CONFIG" --sharedir)
    if [ -f "$PKGLIBDIR/pg_durable.so" ] && [ -f "$SHAREDIR/extension/pg_durable.control" ]; then
        BUILD_MODE="skip"
        echo -e "\033[0;33mExisting pg_durable install detected for PG${PG_MAJOR}; skipping build/install. Use --build to force.\033[0m"
    else
        BUILD_MODE="force"
    fi
fi

if [ "$BUILD_MODE" != "skip" ]; then
    echo -e "\033[0;33mBuilding and installing extension...\033[0m"
    cargo pgrx install --pg-config "$PG_CONFIG" --features http-allow-test-domains 2>&1 | grep -v "^warning:" || true
fi

echo -e "\033[0;33mPreparing PostgreSQL data directory...\033[0m"
ensure_local_cluster_config

echo -e "\033[0;33mStarting PostgreSQL...\033[0m"
start_local_postgres
ensure_compatible_roles
ensure_pg_durable_extension

VERSION=$(pg_durable_version)
echo -e "\033[0;32mPostgreSQL started with pg_durable $VERSION\033[0m"

echo ""
echo -e "\033[0;36mConnect:\033[0m"
echo "  $PGRX_BIN_DIR/psql -h localhost -p $PG_PORT -U postgres -d postgres"
echo ""
echo -e "\033[0;36mLogs:\033[0m"
echo "  tail -f ~/.pgrx/${PG_MAJOR}.log"
echo ""
echo -e "\033[0;36mStop:\033[0m"
echo "  ./scripts/pg-stop.sh"

