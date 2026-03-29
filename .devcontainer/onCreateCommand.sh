#!/bin/bash
set -e

echo "========================================="
echo "Running Codespaces prebuild setup"
echo "This runs during the prebuild and installs all dependencies"
echo "========================================="

# Install system dependencies (skip if called from fallback)
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

# Install cargo-pgrx
echo "Installing cargo-pgrx 0.16.1..."
cargo install cargo-pgrx --version 0.16.1 --locked

# Initialize pgrx with PostgreSQL 17 (pgrx will download and compile PG17)
# This is the most time-consuming step (~5-8 minutes)
echo "Initializing pgrx with PostgreSQL 17..."
cargo pgrx init --pg17 download

# ── Initialize private submodule (duroxide-pg-opt) ──────────────────
# duroxide-pg-opt is a private repo.  Two auth mechanisms:
#
# 1. Prebuild phase: GH_PAT Codespace secret provides access.
#    The PAT is injected as a temporary git insteadOf rewrite, used
#    for clone, then scrubbed so it never persists in the image.
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
    git config --global url."https://x-access-token:${GH_PAT}@github.com/".insteadOf "https://github.com/"

    if git submodule update --init --recursive; then
        echo "✅ Submodule initialized successfully (via PAT)"
        SUBMODULE_INITIALIZED=1
    else
        echo "⚠️  Submodule initialization failed with PAT"
    fi

    # ── Credential cleanup ──────────────────────────────────────────
    # Remove the insteadOf rewrite so the PAT is NOT baked into the
    # prebuild filesystem snapshot.
    git config --global --remove-section "url.https://x-access-token:${GH_PAT}@github.com/" 2>/dev/null || true
    echo -e "protocol=https\nhost=github.com" | git credential reject 2>/dev/null || true

    # Belt-and-suspenders: verify no PAT traces remain
    if grep -q "x-access-token" "$HOME/.gitconfig" 2>/dev/null; then
        echo "⚠️  WARNING: PAT trace found in ~/.gitconfig — scrubbing"
        sed -i '/x-access-token/d' "$HOME/.gitconfig"
    fi
    echo "✅ Credentials cleaned up"
else
    echo "GH_PAT not set — trying submodule init with default credentials..."
    if git submodule update --init --recursive; then
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
    cargo build --features pg17
    echo "✅ pg_durable built successfully"
else
    echo "⚠️  Submodule not available — skipping pg_durable build"
fi

echo ""
echo "========================================="
echo "✅ Prebuild setup complete!"
echo "All dependencies are installed and cached."
echo "========================================="
