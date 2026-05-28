#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 VERSION PGRX_PACKAGE_DIR ARCH PG_VERSION" >&2
    exit 2
fi

VERSION="$1"
PGRX_PACKAGE_DIR="$2"
ARCH="$3"
PG_VERSION="$4"

CLEAN_VERSION="${VERSION#v}"
DEB_VERSION="${CLEAN_VERSION}-1"
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

if [ ! -d "$PGRX_PACKAGE_DIR/usr" ]; then
    echo "pgrx package directory must contain a usr/ tree: $PGRX_PACKAGE_DIR" >&2
    exit 1
fi

LIBRARY_PATH="$PGRX_PACKAGE_DIR/usr/lib/postgresql/${PG_VERSION}/lib/pg_durable.so"
CONTROL_PATH="$PGRX_PACKAGE_DIR/usr/share/postgresql/${PG_VERSION}/extension/pg_durable.control"

if [ ! -f "$LIBRARY_PATH" ]; then
    echo "missing packaged library: $LIBRARY_PATH" >&2
    exit 1
fi

if [ ! -f "$CONTROL_PATH" ]; then
    echo "missing packaged control file: $CONTROL_PATH" >&2
    exit 1
fi

if ! compgen -G "$PGRX_PACKAGE_DIR/usr/share/postgresql/${PG_VERSION}/extension/pg_durable--*.sql" >/dev/null; then
    echo "missing packaged extension SQL files" >&2
    exit 1
fi

BASE_DIR="$(cd "$(dirname "$PGRX_PACKAGE_DIR")/../.." && pwd)"
DIST_DIR="$BASE_DIR/dist"
BUILD_DIR="$BASE_DIR/debian-build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/DEBIAN" "$DIST_DIR"
cp -a "$PGRX_PACKAGE_DIR/usr" "$BUILD_DIR/"

INSTALLED_SIZE=$(du -sk "$BUILD_DIR/usr" | awk '{print $1}')

cat > "$BUILD_DIR/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${DEB_VERSION}
Architecture: ${DEB_ARCH}
Maintainer: Microsoft <opensource@microsoft.com>
Depends: postgresql-${PG_VERSION}, libssl3, ca-certificates
Section: database
Priority: optional
Installed-Size: ${INSTALLED_SIZE}
Homepage: https://github.com/microsoft/pg_durable
Description: pg_durable PostgreSQL extension
 pg_durable provides SQL-native durable function execution for PostgreSQL.
 It stores workflow state in PostgreSQL and runs the durable runtime inside
 the database server background worker process.
EOF

cat > "$BUILD_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "configure" ]; then
    echo "pg_durable installed. Add pg_durable to shared_preload_libraries, restart PostgreSQL, then run CREATE EXTENSION pg_durable;"
fi

exit 0
EOF
chmod 755 "$BUILD_DIR/DEBIAN/postinst"

cat > "$BUILD_DIR/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "remove" ]; then
    echo "Removing pg_durable package. Drop the pg_durable extension from databases before removing package files."
fi

exit 0
EOF
chmod 755 "$BUILD_DIR/DEBIAN/prerm"

PACKAGE_FILE="${PACKAGE_NAME}_${DEB_VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build "$BUILD_DIR" "$DIST_DIR/$PACKAGE_FILE"
rm -rf "$BUILD_DIR"

echo "Package created: $DIST_DIR/$PACKAGE_FILE"