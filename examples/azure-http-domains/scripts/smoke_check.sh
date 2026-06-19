#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# Offline validation for shell syntax and required service files in this example.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$EXAMPLE_DIR"

echo "[smoke] Checking shell script syntax"
find scripts services -name '*.sh' -print0 | xargs -0 bash -n

echo "[smoke] Checking SQL file existence"
for svc_dir in services/*/; do
  svc="$(basename "$svc_dir")"
  if [[ ! -f "$svc_dir/provision.sh" ]]; then
    echo "  Warning: $svc missing provision.sh"
  fi
  if [[ ! -f "$svc_dir/test.sql" ]]; then
    echo "  Warning: $svc missing test.sql"
  fi
done

echo "[smoke] Azure HTTP domain tests smoke checks passed"
