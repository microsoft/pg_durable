#!/bin/bash
set -e

echo "========================================="
echo "Verifying pg_durable development environment"
echo "========================================="

# Quick verification that dependencies are installed
echo "Verifying cargo-pgrx is available..."
if command -v cargo-pgrx >/dev/null 2>&1; then
    echo "✓ cargo-pgrx found: $(cargo-pgrx --version)"
else
    echo "⚠️  cargo-pgrx not found - prebuild may not have completed"
    echo "Running installation now (this may take several minutes)..."
    # Set environment variable to skip redundant apt-get update
    export SKIP_APT_UPDATE=1
    bash .devcontainer/onCreateCommand.sh
fi

# Verify pgrx is initialized
echo "Verifying pgrx PostgreSQL 17 installation..."
if [ -d "$HOME/.pgrx" ]; then
    echo "✓ pgrx directory exists"
else
    echo "⚠️  pgrx not initialized - running initialization..."
    cargo pgrx init --pg17 download
fi
# Check if submodule is initialized
echo "Checking submodule status..."
if [ -f "duroxide-pg-opt/Cargo.toml" ]; then
    echo "✓ duroxide-pg-opt submodule is initialized"
else
    echo "⚠️  duroxide-pg-opt submodule not initialized"
    echo "   Run: git submodule update --init --recursive"
fi

# Check if pg_durable is already built
echo "Checking build status..."
if [ -n "$(find target/debug -name 'libpg_durable*' -print -quit 2>/dev/null)" ]; then
    echo "✓ pg_durable is already built"
elif [ -f "duroxide-pg-opt/Cargo.toml" ]; then
    echo "Building pg_durable (submodule present but build artifacts missing)..."
    cargo build --features pg17
else
    echo "⚠️  pg_durable not built (submodule needed first)"
fi
echo ""
echo "========================================="
echo "✅ Development environment ready!"
echo "========================================="
echo ""
echo "You can now:"
echo "  • Build the extension: cargo build --features pg17"
echo "  • Run tests: ./scripts/test-unit.sh"
echo "  • Start development: cargo pgrx run pg17"
echo ""
