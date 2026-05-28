#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.


resolve_pgrx_environment() {
    local pg_major="$1"

    PG_MAJOR="$pg_major"
    PGRX_CONFIG="$HOME/.pgrx/config.toml"
    DATA_DIR="$HOME/.pgrx/data-$PG_MAJOR"
    PG_CONF="$DATA_DIR/postgresql.conf"
    PG_PORT="$((28800 + PG_MAJOR))"
    PG_LOG_FILE="$HOME/.pgrx/${PG_MAJOR}.log"

    if [ ! -f "$PGRX_CONFIG" ]; then
        echo "pgrx config not found at $PGRX_CONFIG"
        return 1
    fi

    PG_CONFIG=$(grep -E "^pg${PG_MAJOR}\s*=\s*\"" "$PGRX_CONFIG" | head -1 | cut -d'"' -f2)
    if [ -z "$PG_CONFIG" ]; then
        echo "pg${PG_MAJOR} not configured in $PGRX_CONFIG"
        return 1
    fi

    PGRX_BIN_DIR="$(dirname "$PG_CONFIG")"
    PSQL="$PGRX_BIN_DIR/psql"
    PG_CTL="$PGRX_BIN_DIR/pg_ctl"
    PG_ISREADY="$PGRX_BIN_DIR/pg_isready"
}

set_pg_conf() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}\s*=" "$PG_CONF" 2>/dev/null; then
        sed -i "s|^${key}\s*=.*|${key} = '${value}'|" "$PG_CONF"
    else
        echo "${key} = '${value}'" >> "$PG_CONF"
    fi
}

configure_local_cluster() {
    set_pg_conf "shared_preload_libraries" "pg_durable"
    set_pg_conf "pg_durable.worker_role" "postgres"
    set_pg_conf "pg_durable.database" "${PGDATABASE:-postgres}"
    set_pg_conf "pg_durable.enable_superuser_instances" "on"
    set_pg_conf "unix_socket_directories" "$HOME/.pgrx"
}

recreate_local_cluster() {
    rm -rf "$DATA_DIR"
    "$PGRX_BIN_DIR/initdb" -D "$DATA_DIR" -U postgres --no-locale -E UTF8 >/dev/null
    configure_local_cluster
}

ensure_local_cluster_config() {
    if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
        echo "Initializing PostgreSQL data directory..."
        recreate_local_cluster
        return
    fi

    configure_local_cluster
}

start_local_postgres() {
    if "$PG_CTL" status -D "$DATA_DIR" >/dev/null 2>&1; then
        return
    fi

    "$PG_CTL" -D "$DATA_DIR" -l "$PG_LOG_FILE" -o "-p ${PG_PORT} -h localhost" start >/dev/null
    wait_for_local_postgres
}

stop_local_postgres() {
    if "$PG_CTL" status -D "$DATA_DIR" >/dev/null 2>&1; then
        "$PG_CTL" -D "$DATA_DIR" stop -m fast >/dev/null
    fi
}

wait_for_local_postgres() {
    local user_name="${1:-postgres}"

    for _ in $(seq 1 60); do
        if "$PG_ISREADY" -h localhost -p "$PG_PORT" -U "$user_name" -q >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done

    echo "PostgreSQL did not become ready on port $PG_PORT"
    return 1
}

detect_admin_user() {
    if "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres -Atqc "SELECT 1" >/dev/null 2>&1; then
        echo "postgres"
        return 0
    fi

    if "$PSQL" -h localhost -p "$PG_PORT" -U "$USER" -d postgres -Atqc "SELECT 1" >/dev/null 2>&1; then
        echo "$USER"
        return 0
    fi

    return 1
}

ensure_superuser_role() {
    local admin_user="$1"
    local role_name="$2"

    # Validate role name: only allow characters valid in PostgreSQL/Linux usernames.
    # This avoids shell-to-SQL injection since psql variable substitution does not
    # work inside $$ dollar-quoted PL/pgSQL blocks.
    if ! [[ "$role_name" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        echo "Invalid role name: $role_name"
        return 1
    fi

    "$PSQL" -h localhost -p "$PG_PORT" -U "$admin_user" -d postgres \
        -v ON_ERROR_STOP=1 \
        -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role_name}') THEN EXECUTE format('CREATE ROLE %I WITH LOGIN SUPERUSER', '${role_name}'); END IF; END \$\$;" >/dev/null
}

ensure_compatible_roles() {
    local admin_user

    admin_user=$(detect_admin_user) || {
        echo "Unable to connect to PostgreSQL as postgres or $USER"
        return 1
    }

    ensure_superuser_role "$admin_user" "postgres"
    if [ "$USER" != "postgres" ]; then
        ensure_superuser_role "$admin_user" "$USER"
    fi
}

ensure_pg_durable_extension() {
    local db="${PGDATABASE:-postgres}"

    # Validate database name: only allow characters safe for identifiers.
    if ! [[ "$db" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        echo "Invalid database name: $db"
        return 1
    fi

    # Create the target database if it doesn't exist (e.g. contrib_regression for pg_regress)
    if [ "$db" != "postgres" ]; then
        "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres -Atqc \
            "SELECT 1 FROM pg_database WHERE datname = '${db}'" 2>/dev/null | grep -q 1 || \
        "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
            -c "CREATE DATABASE \"${db}\";" >/dev/null
    fi

    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$db" -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION IF NOT EXISTS pg_durable;" >/dev/null
}

pg_durable_version() {
    local db="${PGDATABASE:-postgres}"
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$db" -Atqc "SELECT df.version();"
}
