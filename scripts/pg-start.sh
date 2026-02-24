#!/bin/bash
# pg-start.sh - Start local PostgreSQL with pg_durable extension
#
# Usage: ./scripts/pg-start.sh [database_name]
#   database_name: Optional value for pg_durable.database_name GUC

set -e

# Parse optional database_name parameter
DATABASE_GUC=""
if [ -n "$1" ]; then
    DATABASE_GUC="$1"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$HOME/.pgrx/data-17"
PG_CONF="$DATA_DIR/postgresql.conf"

cd "$PROJECT_DIR"

echo -e "\033[0;33mBuilding and installing extension...\033[0m"
cargo pgrx install --pg-config ~/.pgrx/17.7/pgrx-install/bin/pg_config 2>&1 | grep -v "^warning:" || true

# Initialize data directory if it doesn't exist
if [ ! -d "$DATA_DIR" ]; then
    echo -e "\033[0;33mInitializing PostgreSQL data directory...\033[0m"
    ~/.pgrx/17.7/pgrx-install/bin/initdb -D "$DATA_DIR" 2>/dev/null || true
fi

# Configure shared_preload_libraries for background worker
if [ -f "$PG_CONF" ]; then
    if ! grep -q "shared_preload_libraries.*pg_durable" "$PG_CONF"; then
        echo -e "\033[0;33mConfiguring shared_preload_libraries...\033[0m"
        echo "shared_preload_libraries = 'pg_durable'" >> "$PG_CONF"
    fi
    
    # Configure pg_durable.database_name GUC if provided
    if [ -n "$DATABASE_GUC" ]; then
        # Remove any existing pg_durable.database_name setting (portable sed -i usage)
        sed -i.bak '/^pg_durable\.database_name/d' "$PG_CONF" && rm -f "$PG_CONF.bak"
        echo -e "\033[0;33mSetting pg_durable.database_name = '$DATABASE_GUC'...\033[0m"
        echo "pg_durable.database_name = '$DATABASE_GUC'" >> "$PG_CONF"
    fi
fi

echo -e "\033[0;33mStarting PostgreSQL...\033[0m"
cargo pgrx start pg17 2>/dev/null || true

# Wait for PostgreSQL to be ready
for i in {1..30}; do
    if ~/.pgrx/17.7/pgrx-install/bin/pg_isready -h localhost -p 28817 -q 2>/dev/null; then
        break
    fi
    sleep 0.2
done

# Create extension if needed
~/.pgrx/17.7/pgrx-install/bin/psql -h localhost -p 28817 -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_durable;" 2>/dev/null || true

# Show version
VERSION=$(~/.pgrx/17.7/pgrx-install/bin/psql -h localhost -p 28817 -d postgres -t -c "SELECT df.version();" 2>/dev/null | tr -d ' \n')
echo -e "\033[0;32mPostgreSQL started with pg_durable $VERSION\033[0m"

# Show configured GUC if set
if [ -n "$DATABASE_GUC" ]; then
    echo -e "\033[0;32mConfigured: pg_durable.database_name = '$DATABASE_GUC'\033[0m"
fi

echo ""
echo -e "\033[0;36mConnect:\033[0m"
echo "  ~/.pgrx/17.7/pgrx-install/bin/psql -h localhost -p 28817 -d postgres"
echo ""
echo -e "\033[0;36mLogs:\033[0m"
echo "  tail -f ~/.pgrx/17.log"
echo ""
echo -e "\033[0;36mStop:\033[0m"
echo "  ./scripts/pg-stop.sh"

