#!/bin/bash
set -e

PG_MAJOR=17
PG_PORT=$((28800 + PG_MAJOR))

echo "========================================="
echo "Running Codespaces prebuild setup"
echo "This runs during the prebuild and installs all dependencies,"
echo "builds pg_durable, and prepares a ready-to-use PostgreSQL."
echo "========================================="

# ── 1. System dependencies ──────────────────────────────────────────
if [ "$SKIP_APT_UPDATE" != "1" ]; then
    echo "Installing system dependencies..."
    sudo apt-get update
    sudo apt-get install -y \
        pkg-config \
        libssl-dev \
        libclang-dev \
        clang \
        bison \
        flex \
        libreadline-dev \
        zlib1g-dev \
        libxml2-dev \
        libxslt1-dev \
        libicu-dev
else
    echo "Skipping apt-get update (SKIP_APT_UPDATE=1)"
fi

# ── 2. Install cargo-pgrx & initialize PG17 ─────────────────────────
echo "Installing cargo-pgrx 0.16.1..."
cargo install cargo-pgrx --version 0.16.1 --locked

echo "Initializing pgrx with PostgreSQL ${PG_MAJOR}..."
cargo pgrx init --pg${PG_MAJOR} download

# ── 3. Build and install pg_durable (release) ────────────────────────
PGRX_CONFIG="$HOME/.pgrx/config.toml"
PG_CONFIG=$(grep -E "^pg${PG_MAJOR}\s*=\s*\"" "$PGRX_CONFIG" | head -1 | cut -d'"' -f2)
PGRX_BIN_DIR="$(dirname "$PG_CONFIG")"

echo "Building and installing pg_durable (release)..."
cargo pgrx install --release --pg-config "$PG_CONFIG"

# ── 4. Initialize data directory & configure PG ─────────────────────
# pgrx init creates a data dir with the OS user; we recreate it with
# the 'postgres' superuser so psql -U postgres works out of the box.
DATA_DIR="$HOME/.pgrx/data-${PG_MAJOR}"

if [ -d "$DATA_DIR" ]; then
    echo "Removing existing data directory (will recreate with postgres user)..."
    rm -rf "$DATA_DIR"
fi
echo "Initializing PostgreSQL data directory..."
"$PGRX_BIN_DIR/initdb" -D "$DATA_DIR" -U postgres

# Configure shared_preload_libraries and pg_durable GUCs
PG_CONF="$DATA_DIR/postgresql.conf"

set_pg_conf() {
    local key="$1" value="$2"
    if grep -q "^${key}\s*=" "$PG_CONF" 2>/dev/null; then
        sed -i "s|^${key}\s*=.*|${key} = '${value}'|" "$PG_CONF"
    else
        echo "${key} = '${value}'" >> "$PG_CONF"
    fi
}

set_pg_conf "shared_preload_libraries" "pg_durable"
set_pg_conf "pg_durable.worker_role" "postgres"
set_pg_conf "pg_durable.database" "postgres"

# ── 5. Start PG, create extension, stop PG ───────────────────────────
echo "Starting PostgreSQL to create extension..."
"$PGRX_BIN_DIR/pg_ctl" -D "$DATA_DIR" -l "$HOME/.pgrx/${PG_MAJOR}.log" \
    -o "-p ${PG_PORT} -h localhost" start

# Wait for ready
for i in $(seq 1 30); do
    "$PGRX_BIN_DIR/pg_isready" -h localhost -p "$PG_PORT" -U postgres -q 2>/dev/null && break
    sleep 0.5
done

echo "Creating pg_durable extension..."
"$PGRX_BIN_DIR/psql" -h localhost -p "$PG_PORT" -U postgres -d postgres \
    -c "CREATE EXTENSION IF NOT EXISTS pg_durable;"

# Verify
VERSION=$("$PGRX_BIN_DIR/psql" -h localhost -p "$PG_PORT" -U postgres -d postgres \
    -t -c "SELECT df.version();" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
echo "pg_durable ${VERSION} installed successfully"

echo "Stopping PostgreSQL..."
"$PGRX_BIN_DIR/pg_ctl" -D "$DATA_DIR" stop

echo ""
echo "========================================="
echo "✅ Prebuild complete!"
echo "pg_durable is built, installed, and ready to use."
echo "========================================="
