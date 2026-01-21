#!/bin/bash
set -e

echo "========================================="
echo "Setting up pg_durable development environment"
echo "========================================="

# Install system dependencies
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

# Install cargo-pgrx
echo "Installing cargo-pgrx 0.15.0..."
cargo install cargo-pgrx --version 0.15.0 --locked

# Initialize pgrx with PostgreSQL 17 (pgrx will download and compile PG17)
echo "Initializing pgrx with PostgreSQL 17..."
cargo pgrx init --pg17 download

echo ""
echo "========================================="
echo "✅ Development environment ready!"
echo "========================================="
