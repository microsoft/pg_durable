#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 PG_VERSION ARCH" >&2
    exit 2
fi

PG_VERSION="$1"
ARCH="$2"
PGPORT="${PGPORT:-55432}"
LOG_DIR="${PACKAGE_VALIDATION_LOG_DIR:-package-validation-logs}"
PACKAGE_NAME="pg-durable-postgresql-${PG_VERSION}"

case "$ARCH" in
    amd64|x86_64)
        DEB_ARCH="amd64"
        ;;
    arm64|aarch64)
        DEB_ARCH="arm64"
        ;;
    *)
        echo "unsupported architecture: $ARCH" >&2
        exit 2
        ;;
esac

collect_logs() {
    local exit_code="$?"

    if [ "$exit_code" -ne 0 ]; then
        mkdir -p "$LOG_DIR"
        pg_lsclusters >"$LOG_DIR/pg_lsclusters.txt" 2>&1 || true
        dpkg -L "$PACKAGE_NAME" >"$LOG_DIR/${PACKAGE_NAME}-files.txt" 2>&1 || true
        cp -a /var/log/postgresql/. "$LOG_DIR/" 2>/dev/null || true
    fi

    exit "$exit_code"
}
trap collect_logs EXIT

deb_file=$(find dist -maxdepth 1 -type f -name "${PACKAGE_NAME}_*_${DEB_ARCH}.deb" -print -quit)
if [ -z "$deb_file" ]; then
    echo "missing package dist/${PACKAGE_NAME}_*_${DEB_ARCH}.deb" >&2
    exit 1
fi
deb_file=$(readlink -f "$deb_file")

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    diffutils \
    gnupg \
    lsb-release \
    make

install -d -m 0755 /usr/share/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list

apt-get update
apt-get install -y \
    "postgresql-${PG_VERSION}" \
    "postgresql-server-dev-${PG_VERSION}" \
    "$deb_file"

pg_dropcluster --stop "$PG_VERSION" main 2>/dev/null || true
pg_createcluster "$PG_VERSION" main --start-conf=manual -- \
    --auth-local=trust \
    --auth-host=trust \
    --no-locale \
    -E UTF8

pg_conftool "$PG_VERSION" main set port "$PGPORT"
pg_conftool "$PG_VERSION" main set listen_addresses localhost
pg_conftool "$PG_VERSION" main set shared_preload_libraries pg_durable
pg_conftool "$PG_VERSION" main set pg_durable.worker_role postgres

pg_ctlcluster "$PG_VERSION" main start

for _ in $(seq 1 60); do
    if pg_isready -h localhost -p "$PGPORT" -U postgres -q; then
        break
    fi
    sleep 0.5
done

psql -h localhost -p "$PGPORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT version();"

PG_CONFIG="/usr/lib/postgresql/${PG_VERSION}/bin/pg_config" \
PGHOST=localhost \
PGPORT="$PGPORT" \
PGUSER=postgres \
PGDATABASE=postgres \
REGRESS_OPTS="--use-existing --dbname=postgres" \
make -e installcheck

pg_ctlcluster "$PG_VERSION" main stop