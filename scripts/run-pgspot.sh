#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# run-pgspot.sh - Lint shipped extension SQL with pgspot.
#
# Scans the SQL pg_durable ships (generated install SQL + active upgrade scripts)
# for search_path / privilege-escalation issues (CVE-2018-1058).
#
# A file passes only if every pgspot finding is on the per-finding allowlist
# (PGSPOT_ALLOW); scan_file is fail-closed via two passes (see its comment).
#
# Usage: scripts/run-pgspot.sh FILE [FILE ...]   (globs expanded by caller)
#
# Env:
#   PGSPOT_VERSION       pgspot version to pin (default: 0.9.2)
#   PGSPOT_VENV          venv dir to install/reuse (default: a cache dir)
#   PGSPOT_BIN           existing pgspot executable (skips venv setup)

set -euo pipefail

PGSPOT_VERSION="${PGSPOT_VERSION:-0.9.2}"
PGSPOT_VENV="${PGSPOT_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/pg_durable/pgspot-venv}"

# --- Finding allowlist -----------------------------------------------------
# pgspot prints one line per finding: "PSxxx: <title>: <context> at line N". We
# allow findings by exact match, not by suppressing whole codes (--ignore), so a
# future unsafe instance of the same code still fails. Anything unmatched -- plus
# unknowns, fatals, and unexplained non-zero exits -- fails the gate.
PGSPOT_ALLOW=(
  # pgrx emits `CREATE SCHEMA IF NOT EXISTS df` from #[pg_schema]; the IF NOT
  # EXISTS (what PS010 flags) isn't controllable from source. Only df is allowed;
  # any other PS010 still fails. Schemas we control omit IF NOT EXISTS.
  '^PS010: Unsafe schema creation: df at line [0-9]+$'
  # pg_durable's DSL intentionally exposes unqualified custom operators (for
  # example, `df.sql(...) ~> df.sql(...)`) so users do not need df in search_path.
  # pgspot reports the generated CREATE OPERATOR name as an unqualified object.
  '^PS017: Unqualified object reference: ~> at line [0-9]+$'
)

# Whole codes to suppress globally (pgspot --ignore). Prefer PGSPOT_ALLOW. Empty.
PGSPOT_IGNORE=()

# ---------------------------------------------------------------------------

err() { printf '%s\n' "$*" >&2; }

# Build the two --ignore sets: GLOBAL (PGSPOT_IGNORE only, used in pass A) and
# ALLOW (GLOBAL + the allowlisted codes, used in pass B).
IGNORE_GLOBAL_ARGS=()
IGNORE_ALLOW_ARGS=()
build_ignore_args() {
  local code re
  for code in "${PGSPOT_IGNORE[@]:-}"; do
    [[ -z "$code" ]] && continue
    IGNORE_GLOBAL_ARGS+=(--ignore "$code")
    IGNORE_ALLOW_ARGS+=(--ignore "$code")
  done
  for re in "${PGSPOT_ALLOW[@]:-}"; do
    if [[ "$re" =~ (PS[0-9]+) ]]; then
      IGNORE_ALLOW_ARGS+=(--ignore "${BASH_REMATCH[1]}")
    fi
  done
}

# scan_file FILE -- fail-closed pass/fail against PGSPOT_ALLOW via two passes:
#   Pass A: print all findings; every "PSxxx:" line must match the allowlist.
#     Catches a disallowed instance of an allowlisted code (e.g. PS010 for a
#     non-df schema), which pass B's per-code --ignore would otherwise hide.
#   Pass B: ignore the allowlisted codes; the file must exit fully clean. Catches
#     unknowns, parse fatals, and findings pgspot reports only via exit code.
# FILE passes iff pass A has no disallowed line AND pass B exits clean.
scan_file() {
  local file="$1"

  local outA
  # Pass A uses the printed findings, not the exit code; `|| true` keeps set -e
  # from aborting when pgspot exits non-zero on a finding.
  outA="$("$PGSPOT" "${IGNORE_GLOBAL_ARGS[@]}" "$file" 2>&1)" || true
  printf '%s\n' "$outA"

  local disallowed=0 line re ok
  while IFS= read -r line; do
    [[ "$line" =~ ^PS[0-9]+:\  ]] || continue
    ok=0
    for re in "${PGSPOT_ALLOW[@]}"; do
      [[ -z "$re" ]] && continue
      if [[ "$line" =~ $re ]]; then ok=1; break; fi
    done
    if [[ $ok -eq 0 ]]; then
      disallowed=$((disallowed + 1))
      err "  disallowed finding: $line"
    fi
  done <<< "$outA"

  local rcB=0
  "$PGSPOT" "${IGNORE_ALLOW_ARGS[@]}" "$file" >/dev/null 2>&1 || rcB=$?

  if [[ $disallowed -gt 0 ]]; then
    return 1
  fi
  if [[ $rcB -ne 0 ]]; then
    err "  pgspot reports residual findings after ignoring allowlisted codes (unknown/fatal/non-allowlisted); exit $rcB"
    return 1
  fi
  return 0
}

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
  build_ignore_args

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
    if scan_file "$file"; then
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
