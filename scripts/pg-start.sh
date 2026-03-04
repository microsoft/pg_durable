#!/bin/bash
# pg-start.sh - Start local PostgreSQL with pg_durable extension
#
# Usage: ./scripts/pg-start.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$HOME/.pgrx/data-17"
PG_CONF="$DATA_DIR/postgresql.conf"

# Resolve pg17 binaries from pgrx config (avoids hardcoding a patch version like 17.7).
PGRX_CONFIG="$HOME/.pgrx/config.toml"
if [ ! -f "$PGRX_CONFIG" ]; then
    echo "pgrx config not found at $PGRX_CONFIG"
    exit 1
fi

PG_CONFIG=$(grep -E '^pg17\s*=\s*"' "$PGRX_CONFIG" | head -1 | cut -d'"' -f2)
if [ -z "$PG_CONFIG" ]; then
    echo "pg17 not configured in $PGRX_CONFIG"
    exit 1
fi

PGRX_BIN_DIR="$(dirname "$PG_CONFIG")"

cd "$PROJECT_DIR"

echo -e "\033[0;33mBuilding and installing extension...\033[0m"
cargo pgrx install --pg-config "$PG_CONFIG" 2>&1 | grep -v "^warning:" || true

# Initialize data directory if it doesn't exist
if [ ! -d "$DATA_DIR" ]; then
    echo -e "\033[0;33mInitializing PostgreSQL data directory...\033[0m"
    "$PGRX_BIN_DIR/initdb" -D "$DATA_DIR" -U postgres 2>/dev/null || true
fi

# Configure shared_preload_libraries and pg_durable GUCs
if [ -f "$PG_CONF" ]; then
    if ! grep -q "shared_preload_libraries.*pg_durable" "$PG_CONF"; then
        echo -e "\033[0;33mConfiguring shared_preload_libraries...\033[0m"
        echo "shared_preload_libraries = 'pg_durable'" >> "$PG_CONF"
    fi
    if ! grep -q "^pg_durable.worker_role" "$PG_CONF"; then
        echo -e "\033[0;33mConfiguring pg_durable.worker_role...\033[0m"
        echo "pg_durable.worker_role = 'postgres'" >> "$PG_CONF"
    fi
    if ! grep -q "^pg_durable.database" "$PG_CONF"; then
        echo -e "\033[0;33mConfiguring pg_durable.database...\033[0m"
        echo "pg_durable.database = 'postgres'" >> "$PG_CONF"
    fi
fi

echo -e "\033[0;33mStarting PostgreSQL...\033[0m"
cargo pgrx start pg17 2>/dev/null || true

# Wait for PostgreSQL to be ready
for i in {1..30}; do
    if "$PGRX_BIN_DIR/pg_isready" -h localhost -p 28817 -q 2>/dev/null; then
        break
    fi
    sleep 0.2
done

# Show version
VERSION=$("$PGRX_BIN_DIR/psql" -h localhost -p 28817 -U postgres -d postgres -t -c "SELECT df.version();" 2>/dev/null | tr -d ' \n')
echo -e "\033[0;32mPostgreSQL started with pg_durable $VERSION\033[0m"

echo ""
echo -e "\033[0;36mConnect:\033[0m"
echo "  $PGRX_BIN_DIR/psql -h localhost -p 28817 -U postgres -d postgres"
echo ""
echo -e "\033[0;36mLogs:\033[0m"
echo "  tail -f ~/.pgrx/17.log"
echo ""
echo -e "\033[0;36mStop:\033[0m"
echo "  ./scripts/pg-stop.sh"

