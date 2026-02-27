#!/usr/bin/env bash
set -euo pipefail

# Verify that pg_durable's checked-in copy of duroxide-pg-opt migrations matches
# the current duroxide-pg-opt/migrations directory.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_SRC_DIR="$ROOT_DIR/duroxide-pg-opt/migrations"
UPSTREAM_COPY_DIR="$ROOT_DIR/sql/duroxide_upstream"
INSTALL_SQL="$ROOT_DIR/sql/duroxide_install.sql"

if [ ! -d "$UPSTREAM_SRC_DIR" ]; then
  echo "Missing: $UPSTREAM_SRC_DIR" >&2
  exit 1
fi

if [ ! -d "$UPSTREAM_COPY_DIR" ]; then
  echo "Missing: $UPSTREAM_COPY_DIR" >&2
  exit 1
fi

src_files=("$UPSTREAM_SRC_DIR"/000*.sql)
copy_files=("$UPSTREAM_COPY_DIR"/000*.sql)

if [ "${#src_files[@]}" -eq 0 ]; then
  echo "No migration sql files found in $UPSTREAM_SRC_DIR" >&2
  exit 1
fi

# Compare file lists
src_list="$(for f in "${src_files[@]}"; do basename "$f"; done | sort)"
copy_list="$(for f in "${copy_files[@]}"; do basename "$f"; done | sort)"

if [ "$src_list" != "$copy_list" ]; then
  echo "Migration file list mismatch." >&2
  echo "duroxide-pg-opt/migrations:" >&2
  echo "$src_list" >&2
  echo "sql/duroxide_upstream:" >&2
  echo "$copy_list" >&2
  exit 1
fi

# Compare contents
for f in ${src_list}; do
  diff -u "$UPSTREAM_SRC_DIR/$f" "$UPSTREAM_COPY_DIR/$f" >/dev/null
done

echo "OK: upstream migration copies match duroxide-pg-opt" 

# Verify install SQL matches the generator output
if [ ! -f "$INSTALL_SQL" ]; then
  echo "Missing: $INSTALL_SQL (run scripts/gen-duroxide-install-sql.sh)" >&2
  exit 1
fi

tmp1="$(mktemp)"
tmp2="$(mktemp)"
trap 'rm -f "$tmp1" "$tmp2"' EXIT

OUT_FILE="$tmp1" "$ROOT_DIR/scripts/gen-duroxide-install-sql.sh" >/dev/null
diff -u "$INSTALL_SQL" "$tmp1" >/dev/null

OUT_FILE="$tmp2" "$ROOT_DIR/scripts/gen-duroxide-install-sql.sh" >/dev/null
diff -u "$tmp1" "$tmp2" >/dev/null

echo "OK: sql/duroxide_install.sql matches generator output"
