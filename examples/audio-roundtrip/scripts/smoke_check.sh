#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
#
# Offline, CI-safe checks. No Azure login, no network, no database.
# See examples/README.md for the smoke_check.sh contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$EXAMPLE_DIR"

echo "[smoke] Checking shell script syntax"
bash -n scripts/*.sh

echo "[smoke] Checking expected files are present"
for f in \
    README.md \
    .audio-roundtrip.env.sample \
    sql/01_schema.sql \
    sql/02_set_vars.sql \
    sql/03_seed_phrases.sql \
    sql/04_start_workflow.sql \
    sql/05_monitor.sql \
    sql/06_verify.sql \
    sql/07_reset.sql \
    scripts/provision_azure.sh \
    scripts/cleanup_azure.sh \
    scripts/live_smoke_check.sh
do
    if [[ ! -f "$f" ]]; then
        echo "[smoke] missing expected file: $f" >&2
        exit 1
    fi
done

echo "[smoke] Checking the env sample carries no real secret"
# The sample must stay a template. A key would be 32+ characters of hex or
# base64; the placeholder is not.
if grep -Eq '^AZURE_OPENAI_KEY=[A-Za-z0-9+/]{32,}' .audio-roundtrip.env.sample; then
    echo "[smoke] .audio-roundtrip.env.sample looks like it contains a real key" >&2
    exit 1
fi

echo "[smoke] Checking no generated env file is committed"
if git ls-files --error-unmatch .audio-roundtrip.env > /dev/null 2>&1; then
    echo "[smoke] .audio-roundtrip.env is tracked by git — it holds a secret" >&2
    exit 1
fi

echo "[smoke] Checking the binary handoff is present in the workflow"
# The whole point of the example. If a refactor reintroduces a bridging SQL node
# for the audio, this catches it.
if ! grep -q "'data_b64',     '\$speech.body'" sql/04_start_workflow.sql; then
    echo "[smoke] sql/04_start_workflow.sql no longer hands \$speech.body straight to the upload" >&2
    exit 1
fi

echo "[smoke] Checking seeded phrases satisfy the JSON-safety constraint"
# Mirrors the CHECK constraint in 01_schema.sql: a double quote or backslash in
# a phrase would break out of the JSON request body.
if grep -E "^\s+\('.*[\"\\\\].*'\)" sql/03_seed_phrases.sql; then
    echo "[smoke] a seeded phrase contains a quote or backslash" >&2
    exit 1
fi

echo "[smoke] Audio round trip example smoke checks passed"
