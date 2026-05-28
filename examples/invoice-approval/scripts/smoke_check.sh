#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$EXAMPLE_DIR"

echo "[smoke] Checking shell script syntax"
bash -n scripts/*.sh

echo "[smoke] Checking Python syntax"
python3 -m py_compile function-app/classify_invoice/__init__.py

echo "[smoke] Validating JSON files"
python3 -m json.tool function-app/host.json > /dev/null
python3 -m json.tool function-app/classify_invoice/function.json > /dev/null

echo "[smoke] Invoice approval example smoke checks passed"
