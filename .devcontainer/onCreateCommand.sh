#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/pg-common.sh
. "$PROJECT_DIR/scripts/pg-common.sh"

PG_MAJOR=17
SMOKE_MODE="${PG_DURABLE_SMOKE:-0}"

echo "========================================="
echo "Running Codespaces prebuild setup"
echo "This runs during the prebuild and installs all dependencies"
echo "========================================="

# Install system dependencies (skip if called from fallback)
if [ "$SKIP_APT_UPDATE" != "1" ]; then
    if [ "$SMOKE_MODE" = "1" ]; then
        echo "Smoke mode: skipping apt-get install"
    else
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
    fi
else
    echo "Skipping apt-get update (SKIP_APT_UPDATE=1)"
fi

# Install cargo-pgrx
echo "Installing cargo-pgrx 0.16.1..."
if [ "$SMOKE_MODE" = "1" ]; then
    echo "Smoke mode: skipping cargo-pgrx install"
else
    cargo install cargo-pgrx --version 0.16.1 --locked
fi

# Initialize pgrx with PostgreSQL 17 (pgrx will download and compile PG17)
# This is the most time-consuming step (~5-8 minutes)
echo "Initializing pgrx with PostgreSQL 17..."
if [ "$SMOKE_MODE" = "1" ]; then
    echo "Smoke mode: skipping cargo pgrx init"
else
    cargo pgrx init --pg17 download
fi

# ── Build pg_durable ────────────────────────────────────────────────
# duroxide-pg is pulled as a crates.io dependency (see Cargo.toml).
echo "Building pg_durable..."
if [ "$SMOKE_MODE" = "1" ]; then
    echo "Smoke mode: skipping cargo build"
else
    cargo build --features pg17,http-allow-test-domains
    echo "✅ pg_durable built successfully"

    echo "Installing pg_durable into PostgreSQL ${PG_MAJOR}..."
    resolve_pgrx_environment "$PG_MAJOR"
    cargo pgrx install --release --pg-config "$PG_CONFIG"

    echo "Preparing PostgreSQL ${PG_MAJOR} cluster..."
    recreate_local_cluster
    start_local_postgres
    ensure_compatible_roles
    ensure_pg_durable_extension

    VERSION=$(pg_durable_version)
    echo "✅ pg_durable ${VERSION} installed and verified"

    echo "Stopping PostgreSQL ${PG_MAJOR} after prebuild verification..."
    stop_local_postgres
fi

echo ""
echo "========================================="
echo "✅ Prebuild setup complete!"
echo "All dependencies are installed and cached."
echo "========================================="
