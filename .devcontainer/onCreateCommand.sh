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
# In Codespaces, devcontainer.json grants the built-in GITHUB_TOKEN read
# access to microsoft/duroxide-pg-opt via customizations.codespaces.
# repositories.  The Codespace credential helper handles authentication
# automatically — no PAT needed.
#
# Outside Codespaces (e.g. local Dev Container), the user must have
# their own credentials configured for the private repo.
echo "Initializing submodule (duroxide-pg-opt)..."
if git submodule update --init --recursive; then
    echo "✅ Submodule initialized successfully"
else
    echo "⚠️  Submodule initialization failed — skipping"
    echo "   If running outside Codespaces, ensure you have access to microsoft/duroxide-pg-opt"
fi

echo ""
echo "========================================="
echo "✅ Prebuild setup complete!"
echo "All dependencies are installed and cached."
echo "========================================="
