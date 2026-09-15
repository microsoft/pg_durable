#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail
export LC_ALL=C

if [[ $# -ne 5 ]]; then
    echo "usage: $0 TEMPLATE ALLOWLIST VERSION TREEISH OUTPUT" >&2
    exit 2
fi

template="$1"
allowlist="$2"
version="$3"
treeish="$4"
output="$5"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

grep -Ev '^[[:space:]]*(#|$)' "$allowlist" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sort > "$tmp_dir/allowed"

if [[ "$(wc -l < "$tmp_dir/allowed")" -ne "$(sort -u "$tmp_dir/allowed" | wc -l)" ]]; then
    echo "$allowlist contains duplicate paths" >&2
    exit 1
fi

for required in README.md USER_GUIDE.md; do
    if ! grep -Fx "$required" "$tmp_dir/allowed" > /dev/null; then
        echo "$allowlist must include $required" >&2
        exit 1
    fi
done

git ls-tree -r --name-only "$treeish" | sort > "$tmp_dir/tracked"
missing="$(comm -23 "$tmp_dir/allowed" "$tmp_dir/tracked")"
if [[ -n "$missing" ]]; then
    echo "PGXN indexed documentation is not present in $treeish:" >&2
    printf '%s\n' "$missing" >&2
    exit 1
fi

comm -23 "$tmp_dir/tracked" "$tmp_dir/allowed" > "$tmp_dir/excluded"
excluded_count="$(wc -l < "$tmp_dir/excluded")"
awk -v total="$excluded_count" '
    BEGIN {
        print "      \"file\": ["
    }
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        printf "         \"%s\"%s\n", $0, (NR == total ? "" : ",")
    }
    END {
        print "      ]"
    }
' "$tmp_dir/excluded" > "$tmp_dir/no-index.json"

if [[ "$(grep -c '@PGXN_NO_INDEX_FILES@' "$template")" -ne 1 ]]; then
    echo "$template must contain exactly one @PGXN_NO_INDEX_FILES@ token" >&2
    exit 1
fi

mkdir -p "$(dirname "$output")"
awk -v version="$version" -v no_index="$tmp_dir/no-index.json" '
    /@PGXN_NO_INDEX_FILES@/ {
        while ((getline line < no_index) > 0) {
            print line
        }
        close(no_index)
        next
    }
    {
        gsub(/@CARGO_VERSION@/, version)
        print
    }
' "$template" > "$tmp_dir/META.json"
mv "$tmp_dir/META.json" "$output"
