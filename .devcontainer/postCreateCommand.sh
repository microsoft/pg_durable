#!/bin/bash
set -e

PG_MAJOR=17
PG_PORT=$((28800 + PG_MAJOR))
PGRX_CONFIG="$HOME/.pgrx/config.toml"

echo "========================================="
echo "Starting pg_durable environment"
echo "========================================="

# Check if prebuild ran (extension should already be installed)
if [ ! -f "$PGRX_CONFIG" ]; then
    echo "⚠️  Prebuild not available — running full setup (this may take several minutes)..."
    export SKIP_APT_UPDATE=1
    bash .devcontainer/onCreateCommand.sh
fi

# Resolve PG binaries
PG_CONFIG=$(grep -E "^pg${PG_MAJOR}\s*=\s*\"" "$PGRX_CONFIG" | head -1 | cut -d'"' -f2)
PGRX_BIN_DIR="$(dirname "$PG_CONFIG")"
DATA_DIR="$HOME/.pgrx/data-${PG_MAJOR}"

# Start PostgreSQL
echo "Starting PostgreSQL..."
"$PGRX_BIN_DIR/pg_ctl" -D "$DATA_DIR" -l "$HOME/.pgrx/${PG_MAJOR}.log" \
    -o "-p ${PG_PORT} -h localhost" start

# Wait for ready
for i in $(seq 1 30); do
    "$PGRX_BIN_DIR/pg_isready" -h localhost -p "$PG_PORT" -U postgres -q 2>/dev/null && break
    sleep 0.5
done

# Verify extension
VERSION=$("$PGRX_BIN_DIR/psql" -h localhost -p "$PG_PORT" -U postgres -d postgres \
    -t -c "SELECT df.version();" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

echo ""
echo "========================================="
echo "✅ pg_durable ${VERSION} is running!"
echo "========================================="
echo ""
echo "Connect with:"
echo "  $PGRX_BIN_DIR/psql -h localhost -p $PG_PORT -U postgres -d postgres"
echo ""
echo "Quick start:"
echo "  SELECT df.start('SELECT 1' ~> 'SELECT 2');"
echo ""
echo "Logs:"
echo "  tail -f ~/.pgrx/${PG_MAJOR}.log"
echo ""
echo "Stop:"
echo "  ./scripts/pg-stop.sh"
