# Multi-stage build for pg_durable extension
# Stage 1: Build the extension
# Using nightly because cargo-pgrx 0.16.1 requires edition2024
FROM rustlang/rust:nightly-bookworm AS builder

# Install PostgreSQL 17 dev packages and build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    gnupg2 \
    lsb-release \
    pkg-config \
    libssl-dev \
    libclang-dev \
    clang \
    && rm -rf /var/lib/apt/lists/*

# Add PostgreSQL APT repository for PG 17
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

RUN apt-get update && apt-get install -y \
    postgresql-17 \
    postgresql-server-dev-17 \
    && rm -rf /var/lib/apt/lists/*

# Install cargo-pgrx
RUN cargo install cargo-pgrx --version 0.16.1 --locked

# Initialize pgrx with PG17 (use system PostgreSQL)
RUN cargo pgrx init --pg17 /usr/lib/postgresql/17/bin/pg_config

# Create app directory
WORKDIR /app

# Copy Cargo files first for better caching
COPY Cargo.toml Cargo.lock* ./
COPY .cargo .cargo

# Copy source code
COPY src ./src
COPY pg_durable.control ./
COPY sql ./sql

# Build the extension
RUN cargo pgrx package --pg-config /usr/lib/postgresql/17/bin/pg_config

# Stage 2: Runtime image with PostgreSQL
FROM postgres:17-bookworm

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy the built extension from builder
COPY --from=builder /app/target/release/pg_durable-pg17/usr/share/postgresql/17/extension/* /usr/share/postgresql/17/extension/
COPY --from=builder /app/target/release/pg_durable-pg17/usr/lib/postgresql/17/lib/* /usr/lib/postgresql/17/lib/

# Create initialization script inline (avoids Docker context issues)
RUN mkdir -p /docker-entrypoint-initdb.d && \
    echo '#!/bin/bash' > /docker-entrypoint-initdb.d/01-init-pg-durable.sh && \
    echo 'set -e' >> /docker-entrypoint-initdb.d/01-init-pg-durable.sh && \
    echo 'psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL' >> /docker-entrypoint-initdb.d/01-init-pg-durable.sh && \
    echo '    CREATE EXTENSION IF NOT EXISTS pg_durable;' >> /docker-entrypoint-initdb.d/01-init-pg-durable.sh && \
    echo 'EOSQL' >> /docker-entrypoint-initdb.d/01-init-pg-durable.sh && \
    echo 'echo "pg_durable extension created successfully"' >> /docker-entrypoint-initdb.d/01-init-pg-durable.sh && \
    chmod +x /docker-entrypoint-initdb.d/01-init-pg-durable.sh

# Configure shared_preload_libraries for background worker
RUN echo "shared_preload_libraries = 'pg_durable'" >> /usr/share/postgresql/postgresql.conf.sample

# Set writable path for duroxide SQLite store and pre-create the file
ENV PG_DURABLE_STORE_PATH=/tmp/pg_durable_duroxide.db
RUN touch /tmp/pg_durable_duroxide.db && chmod 666 /tmp/pg_durable_duroxide.db

EXPOSE 5432

