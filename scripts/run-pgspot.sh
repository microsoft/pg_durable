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
# Strict policy: a file passes only when every pgspot finding is on the
# documented per-finding allowlist (PGSPOT_ALLOW). Each file is scanned twice so
# the result is fail-closed (see scan_file): pass A verifies that only
# allowlisted findings are present; pass B (ignoring the allowlisted codes) must
# come back completely clean, which catches unknowns, parse fatals, and any
# finding pgspot reports only via its exit code.
#
# Known pgspot limitation (DO-block isolation):
#   pgspot scans a whole file and, once it sees a function that establishes a
#   trusted search_path, marks top-level state "search_path secure" and exempts
#   all LATER top-level statements from the unqualified-reference rules. Anonymous
#   `DO` blocks do NOT inherit a function's `SET search_path` at run time, so an
#   unqualified reference inside a DO block is a real CVE-2018-1058 surface that
#   the whole-file pass masks. To close this for DO blocks, each DO block is also
#   extracted (see extract-do-blocks.py) and scanned in isolation. Other statement
#   classes that cannot carry their own search_path (e.g. plain DML at install
#   time) are NOT auto-isolated; keep all install DDL schema-qualified.
#
# Usage:
#   scripts/run-pgspot.sh FILE [FILE ...]
#
# Each FILE is checked independently. Globs should be expanded by the caller;
# patterns that match nothing are reported and skipped.
#
# Environment:
#   PGSPOT_VERSION      pgspot version to pin (default: 0.9.2)
#   PGSPOT_VENV         venv directory to install/reuse (default: a cache dir)
#   PGSPOT_BIN          path to an existing pgspot executable (skips venv setup)
#   PGSPOT_DO_ISOLATION set to 0 to disable DO-block isolation (debug only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGSPOT_VERSION="${PGSPOT_VERSION:-0.9.2}"
PGSPOT_VENV="${PGSPOT_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/pg_durable/pgspot-venv}"
# Also isolate-scan anonymous DO blocks to defeat pgspot's whole-file
# search_path leak (see extract-do-blocks.py). On by default; set to 0 only for
# debugging.
PGSPOT_DO_ISOLATION="${PGSPOT_DO_ISOLATION:-1}"

# --- Finding allowlist -----------------------------------------------------
#
# pgspot prints one line per error/warning: "PSxxx: <title>: <context> at line
# N". Instead of suppressing whole codes with --ignore (which is GLOBAL and
# would also hide future, genuinely-unsafe instances of the same code), we
# allow specific findings by exact line. A finding is permitted only if it
# matches one of the regexes below; everything else fails the gate. Unknowns,
# fatals/parse errors, and any unexplained non-zero pgspot exit also fail.
#
# Each entry MUST carry a justification. Keep this list as small as possible;
# prefer fixing the source.
PGSPOT_ALLOW=(
  # pgrx emits `CREATE SCHEMA IF NOT EXISTS df` from #[pg_schema]; the
  # `IF NOT EXISTS` (the construct PS010 flags, as it can adopt a pre-existing
  # attacker-crafted schema) is not controllable from our source. Residual risk
  # is negligible: all df objects are created by the installing superuser and we
  # ship no SECURITY DEFINER functions. ONLY the df schema is allowed -- any
  # other PS010 (e.g. a future `CREATE SCHEMA IF NOT EXISTS something_else`)
  # still fails the gate. Schemas we fully control are created without
  # IF NOT EXISTS (see `CREATE SCHEMA duroxide`) and never trip PS010 at all.
  '^PS010: Unsafe schema creation: df at line [0-9]+$'
)

# Whole codes to suppress globally via pgspot --ignore. Prefer PGSPOT_ALLOW
# (precise, per-finding) over this. Intentionally empty.
PGSPOT_IGNORE=()

# ---------------------------------------------------------------------------

err() { printf '%s\n' "$*" >&2; }

# Build the two --ignore argument sets from PGSPOT_IGNORE and PGSPOT_ALLOW.
# - GLOBAL: codes in PGSPOT_IGNORE only (suppressed everywhere). Used in pass A.
# - ALLOW:  GLOBAL plus the codes mentioned by PGSPOT_ALLOW regexes. Used in
#           pass B, where the file must come back completely clean.
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

# scan_file FILE
# Decide pass/fail for FILE against PGSPOT_ALLOW using two pgspot passes, so the
# result is fail-closed (an unexpected fatal/parse error or unknown can never be
# masked by the presence of an allowlisted finding).
#
#   Pass A (no allow-code ignores): print all findings and verify every printed
#     "PSxxx:" line matches the allowlist. This is what catches a DISALLOWED
#     instance of an allowlisted code (e.g. PS010 for a schema other than df) --
#     pass B would hide it because --ignore is per-code/global.
#   Pass B (ignore the allowlisted codes): the file must now be COMPLETELY clean
#     (exit 0). This catches unknowns, parse fatals, and any non-allowlisted
#     finding regardless of how pgspot reports it.
#
# FILE passes only if pass A finds no disallowed line AND pass B exits clean.
scan_file() {
  local file="$1"

  local outA
  # Pass A relies on the printed findings, not the exit code; `|| true` keeps
  # `set -e` from aborting when pgspot exits non-zero on a finding.
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
      PGSPOT_PY="$(dirname "$PGSPOT_BIN")/python3"
      return
    fi
    err "PGSPOT_BIN=$PGSPOT_BIN is not pgspot ${PGSPOT_VERSION}"
    exit 2
  fi

  local venv_bin="$PGSPOT_VENV/bin/pgspot"
  if [[ -x "$venv_bin" ]] && "$venv_bin" --version 2>/dev/null | grep -q "pgspot ${PGSPOT_VERSION}"; then
    PGSPOT="$venv_bin"
    PGSPOT_PY="$PGSPOT_VENV/bin/python3"
    return
  fi

  err "Installing pgspot ${PGSPOT_VERSION} into ${PGSPOT_VENV} ..."
  python3 -m venv "$PGSPOT_VENV"
  "$PGSPOT_VENV/bin/pip" install --quiet --upgrade pip
  "$PGSPOT_VENV/bin/pip" install --quiet "pgspot==${PGSPOT_VERSION}"
  PGSPOT="$venv_bin"
  PGSPOT_PY="$PGSPOT_VENV/bin/python3"
}

main() {
  if [[ $# -eq 0 ]]; then
    err "usage: $0 FILE [FILE ...]"
    exit 2
  fi

  resolve_pgspot
  build_ignore_args

  local do_isolation=0
  local workdir=""
  if [[ "$PGSPOT_DO_ISOLATION" == "1" ]]; then
    if "$PGSPOT_PY" -c 'import pglast' 2>/dev/null; then
      do_isolation=1
      workdir="$(mktemp -d)"
      # shellcheck disable=SC2064
      trap "rm -rf '$workdir'" EXIT
    else
      err "ERROR: DO-block isolation requested but pglast is unavailable in $PGSPOT_PY"
      exit 2
    fi
  fi

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

    # Supplementary: isolate-scan each anonymous DO block so the whole-file
    # search_path leak cannot mask an unqualified reference inside it.
    if [[ $do_isolation -eq 1 ]]; then
      local do_file
      while IFS= read -r do_file; do
        [[ -z "$do_file" ]] && continue
        printf '\n=== pgspot (DO-isolation): %s ===\n' "$do_file"
        if scan_file "$do_file"; then
          printf 'OK: %s\n' "$do_file"
        else
          err "FAIL (DO-isolation, source file $file): $do_file"
          failed=$((failed + 1))
        fi
      done < <("$PGSPOT_PY" "$SCRIPT_DIR/extract-do-blocks.py" "$workdir" "$file")
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
