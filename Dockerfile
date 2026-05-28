# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Multi-stage build for pg_durable extension
# Stage 1: Build the extension
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
COPY build.rs ./

# Copy source code
COPY src ./src
COPY pg_durable.control ./
COPY sql ./sql

# Build the extension
RUN cargo pgrx package --features http-allow-test-domains --pg-config /usr/lib/postgresql/17/bin/pg_config

# Stage 2: Runtime image with PostgreSQL
FROM postgres:17-bookworm

# Install runtime dependencies (ca-certificates needed for native-tls HTTPS)
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
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
# Enable logging_collector so PG writes log files that can be extracted on failure
RUN echo "shared_preload_libraries = 'pg_durable'" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "pg_durable.database = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "pg_durable.worker_role = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "pg_durable.enable_superuser_instances = on" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "logging_collector = on" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "log_directory = 'log'" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "log_filename = 'postgresql.log'" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "log_truncate_on_rotation = on" >> /usr/share/postgresql/postgresql.conf.sample

EXPOSE 5432
