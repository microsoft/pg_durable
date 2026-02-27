#!/usr/bin/env bash
set -euo pipefail

# Generate sql/duroxide_install.sql from the checked-in upstream migration copies.
#
# This keeps the extension install DDL explicit/reviewable, while still tracking
# duroxide-pg-opt's migration sources.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_FILE="${OUT_FILE:-$ROOT_DIR/sql/duroxide_install.sql}"
UPSTREAM_DIR="$ROOT_DIR/sql/duroxide_upstream"

if [ ! -d "$UPSTREAM_DIR" ]; then
  echo "Upstream migrations dir not found: $UPSTREAM_DIR" >&2
  exit 1
fi

migrations=("$UPSTREAM_DIR"/000*.sql)
if [ "${#migrations[@]}" -eq 0 ]; then
  echo "No upstream migrations found in $UPSTREAM_DIR" >&2
  exit 1
fi

{
  echo "-- BEGIN duroxide-pg-opt migrations (checked-in copy)"
  echo "CREATE SCHEMA IF NOT EXISTS duroxide;"
  echo "SET LOCAL search_path TO duroxide;"
  echo ""

  for path in "${migrations[@]}"; do
    file="$(basename "$path")"

    # Parse leading version from 0001_foo.sql
    version="${file%%_*}"
    if ! [[ "$version" =~ ^[0-9]{4}$ ]]; then
      echo "Skipping unexpected migration filename: $file" >&2
      exit 1
    fi

    echo "-- Migration ${version}: ${file}"
    cat "$path"
    echo ""

    # duroxide-pg-opt's MigrationPolicy "ApplyAll" populates _duroxide_migrations. We don't use that policy, so we record the applied migrations manually.
    version_num=$((10#$version))
    file_escaped="$(printf "%s" "$file" | sed "s/'/''/g")"
    printf "INSERT INTO _duroxide_migrations(version, name) VALUES (%s, '%s') ON CONFLICT (version) DO NOTHING;\n" "$version_num" "$file_escaped"
    echo ""
  done

  # Restore the search_path that CREATE EXTENSION set.  We cannot use
  # "RESET search_path" because that reverts to the boot default (typically
  # '"$user",public'), NOT to what CREATE EXTENSION originally set
  # ('@extschema@, pg_temp').  @extschema@ is substituted by PostgreSQL
  # during CREATE EXTENSION, so the operators / helper functions that follow
  # in the extension SQL will be created in the correct schema.
  echo "SET LOCAL search_path TO @extschema@;"
  echo ""
  echo "-- END duroxide-pg-opt migrations (checked-in copy)"
} > "$OUT_FILE"

echo "Wrote $OUT_FILE"
