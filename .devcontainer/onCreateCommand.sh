#!/bin/bash
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

# ── Initialize private submodule (duroxide-pg-opt) ──────────────────
# duroxide-pg-opt is a private repo.  Two auth mechanisms:
#
# 1. Prebuild phase: GH_PAT Codespace secret provides access.
#    We use a temporary git insteadOf rewrite during submodule clone.
#    The secret remains available in the Codespace environment, so there
#    is no meaningful security benefit to trying to scrub local traces.
#
# 2. Interactive Codespace: devcontainer.json grants the built-in
#    GITHUB_TOKEN read access via customizations.codespaces.repositories.
#    The Codespace credential helper handles auth automatically.
#
# 3. Local Dev Container: user must have their own credentials.

SUBMODULE_INITIALIZED=0

if [ -n "$GH_PAT" ]; then
    echo "GH_PAT detected — initializing submodule with PAT..."

    # Temporarily rewrite GitHub HTTPS URLs to include the token.
    PAT_REWRITE_URL="https://x-access-token:${GH_PAT}@github.com/"

    cleanup_pat_rewrite() {
        local rc=$?
        # GH_PAT is still available in Codespace env vars; cleanup here ensures
        # subsequent user git operations prefer devcontainer.json repo permissions
        # and Codespaces credential helper instead of forcing PAT rewrite behavior.
        git config --global --remove-section "url.${PAT_REWRITE_URL}" 2>/dev/null || true
        return $rc
    }

    trap cleanup_pat_rewrite EXIT
    git config --global url."${PAT_REWRITE_URL}".insteadOf "https://github.com/"

    if [ "$SMOKE_MODE" = "1" ]; then
        echo "Smoke mode: skipping git submodule update"
        if [ -f "duroxide-pg-opt/Cargo.toml" ]; then
            SUBMODULE_INITIALIZED=1
        fi
    elif git submodule update --init --recursive; then
        echo "✅ Submodule initialized successfully (via PAT)"
        SUBMODULE_INITIALIZED=1
    else
        echo "⚠️  Submodule initialization failed with PAT"
    fi
else
    echo "GH_PAT not set — trying submodule init with default credentials..."
    if [ "$SMOKE_MODE" = "1" ]; then
        echo "Smoke mode: skipping git submodule update"
        if [ -f "duroxide-pg-opt/Cargo.toml" ]; then
            SUBMODULE_INITIALIZED=1
        fi
    elif git submodule update --init --recursive; then
        echo "✅ Submodule initialized successfully"
        SUBMODULE_INITIALIZED=1
    else
        echo "⚠️  Submodule initialization failed — skipping"
        echo "   Set GH_PAT secret or ensure credentials for microsoft/duroxide-pg-opt"
    fi
fi

# ── Build pg_durable ────────────────────────────────────────────────
# Only build if the submodule is present (needed for compilation)
if [ "$SUBMODULE_INITIALIZED" = "1" ] && [ -f "duroxide-pg-opt/Cargo.toml" ]; then
    echo "Building pg_durable..."
    if [ "$SMOKE_MODE" = "1" ]; then
        echo "Smoke mode: skipping cargo build"
    else
        cargo build --features pg17
        echo "✅ pg_durable built successfully"
    fi

    echo "Installing pg_durable into PostgreSQL ${PG_MAJOR}..."
    if [ "$SMOKE_MODE" = "1" ]; then
        echo "Smoke mode: skipping install/cluster bootstrap"
    else
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
else
    echo "⚠️  Submodule not available — skipping pg_durable build"
fi

echo ""
echo "========================================="
echo "✅ Prebuild setup complete!"
echo "All dependencies are installed and cached."
echo "========================================="
