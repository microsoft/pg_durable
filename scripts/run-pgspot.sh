#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# run-pgspot.sh - Lint shipped extension SQL with pgspot
#
# Scans the static SQL that pg_durable actually ships -- the generated
# `CREATE EXTENSION` install SQL and the active upgrade scripts -- for
# search_path / privilege-escalation issues (CVE-2018-1058 class) and other
# unsafe SQL constructs.
#
# Strict policy: the gate passes only when pgspot reports ZERO errors, ZERO
# warnings and ZERO unknowns for every file, except for codes on the documented
# allowlist below. pgspot already exits non-zero on any error, warning or
# unknown, so this wrapper relies on that exit code and adds: a pinned pgspot
# version, an explicit allowlist with justifications, and per-file attribution.
#
# Usage:
#   scripts/run-pgspot.sh FILE [FILE ...]
#
# Each FILE is checked independently. Globs should be expanded by the caller;
# patterns that match nothing are reported and skipped.
#
# Environment:
#   PGSPOT_VERSION  pgspot version to pin (default: 0.9.2)
#   PGSPOT_VENV     venv directory to install/reuse (default: a cache dir)
#   PGSPOT_BIN      path to an existing pgspot executable (skips venv setup)

set -euo pipefail

PGSPOT_VERSION="${PGSPOT_VERSION:-0.9.2}"
PGSPOT_VENV="${PGSPOT_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/pg_durable/pgspot-venv}"

# --- Allowlist -------------------------------------------------------------
#
# Each entry MUST carry a justification. Keep this list as small as possible;
# prefer fixing the source over ignoring a code. Codes here are passed to
# pgspot via --ignore, which suppresses both the finding and the exit code.
#
# (Intentionally empty for the initial gate so that all real findings surface.
# Add entries only for constructs we provably cannot control from source, e.g.
# pgrx-emitted DDL, each with a one-line reason.)
PGSPOT_IGNORE=(
  # Example (disabled): PS010  # `CREATE SCHEMA IF NOT EXISTS df` emitted by pgrx #[pg_schema]
)

# ---------------------------------------------------------------------------

err() { printf '%s\n' "$*" >&2; }

resolve_pgspot() {
  if [[ -n "${PGSPOT_BIN:-}" ]]; then
    if "$PGSPOT_BIN" --version 2>/dev/null | grep -q "pgspot ${PGSPOT_VERSION}"; then
      PGSPOT="$PGSPOT_BIN"
      return
    fi
    err "PGSPOT_BIN=$PGSPOT_BIN is not pgspot ${PGSPOT_VERSION}"
    exit 2
  fi

  local venv_bin="$PGSPOT_VENV/bin/pgspot"
  if [[ -x "$venv_bin" ]] && "$venv_bin" --version 2>/dev/null | grep -q "pgspot ${PGSPOT_VERSION}"; then
    PGSPOT="$venv_bin"
    return
  fi

  err "Installing pgspot ${PGSPOT_VERSION} into ${PGSPOT_VENV} ..."
  python3 -m venv "$PGSPOT_VENV"
  "$PGSPOT_VENV/bin/pip" install --quiet --upgrade pip
  "$PGSPOT_VENV/bin/pip" install --quiet "pgspot==${PGSPOT_VERSION}"
  PGSPOT="$venv_bin"
}

main() {
  if [[ $# -eq 0 ]]; then
    err "usage: $0 FILE [FILE ...]"
    exit 2
  fi

  resolve_pgspot

  local ignore_args=()
  local code
  for code in "${PGSPOT_IGNORE[@]:-}"; do
    [[ -z "$code" ]] && continue
    ignore_args+=(--ignore "$code")
  done

  local failed=0
  local checked=0
  local file
  for file in "$@"; do
    if [[ ! -f "$file" ]]; then
      err "skip (not found): $file"
      continue
    fi
    checked=$((checked + 1))
    printf '\n=== pgspot: %s ===\n' "$file"
    if "$PGSPOT" "${ignore_args[@]}" "$file"; then
      printf 'OK: %s\n' "$file"
    else
      err "FAIL: $file"
      failed=$((failed + 1))
    fi
  done

  if [[ $checked -eq 0 ]]; then
    err "ERROR: no files were checked"
    exit 2
  fi

  printf '\n--- pgspot summary: %d file(s) checked, %d failed ---\n' "$checked" "$failed"
  if [[ $failed -ne 0 ]]; then
    err "pgspot gate FAILED ($failed file(s) with findings)"
    exit 1
  fi
  printf 'pgspot gate PASSED\n'
}

main "$@"
