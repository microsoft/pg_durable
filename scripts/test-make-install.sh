#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
trap 'status=$?; printf "Source install check failed at line %s: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$status" >&2' ERR

# Some cases verify Makefile discovery, so they must not inherit a real pg_config.
unset PG_CONFIG

file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

create_pg_config() {
    local major="$1"
    local path="$TEST_DIR/pg_config-$major"

    cat > "$path" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    --version) echo "PostgreSQL $major.1" ;;
    --pkglibdir) echo "/usr/lib/postgresql/$major/lib" ;;
    --sharedir) echo "/usr/share/postgresql/$major" ;;
    --pgxs) echo "$TEST_DIR/pgxs-$major.mk" ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$path"

    # `make installcheck` includes whatever pg_config reports, so give it a stub.
    printf 'installcheck:\n\t@echo pgxs installcheck\n' > "$TEST_DIR/pgxs-$major.mk"

    printf '%s\n' "$path"
}

FAKE_CARGO="$TEST_DIR/cargo"
CARGO_LOG="$TEST_DIR/cargo.log"
TEST_PG_CONFIG_17="$(create_pg_config 17)"
TEST_PG_CONFIG_18="$(create_pg_config 18)"
export CARGO_LOG TEST_PG_CONFIG_17 TEST_PG_CONFIG_18

# cargo-pgrx refuses to build without $PGRX_HOME/config.toml, and `package` now
# creates it when it is absent. Point PGRX_HOME at the sandbox so these checks
# neither depend on nor disturb the caller's pgrx installation. The auto-init
# behaviour itself is covered explicitly at the end of this script.
PGRX_HOME="$TEST_DIR/pgrx-home"
mkdir -p "$PGRX_HOME"
printf '[configs]\npg17 = "%s"\n' "$TEST_PG_CONFIG_17" > "$PGRX_HOME/config.toml"
export PGRX_HOME

cat > "$FAKE_CARGO" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "$CARGO_LOG"
printf '\n' >> "$CARGO_LOG"

if [[ "${1:-}" == "install" ]]; then
    exit 0
fi

if [[ "${1:-}" == "pgrx" && "${2:-}" == "init" ]]; then
    mkdir -p "$PGRX_HOME"
    printf '[configs]\n' > "$PGRX_HOME/config.toml"
    exit 0
fi

if [[ "${1:-}" == "pgrx" && "${2:-}" == "info" && "${3:-}" == "pg-config" ]]; then
    case "${4:-}" in
        pg17) printf '%s\n' "$TEST_PG_CONFIG_17" ;;
        pg18) printf '%s\n' "$TEST_PG_CONFIG_18" ;;
        *) exit 1 ;;
    esac
    exit 0
fi

pg_config=""
out_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pg-config)
            pg_config="$2"
            shift 2
            ;;
        --out-dir)
            out_dir="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

pkglibdir="$($pg_config --pkglibdir)"
extension_dir="$($pg_config --sharedir)/extension"
mkdir -p "$out_dir$pkglibdir" "$out_dir$extension_dir"
printf 'shared library\n' > "$out_dir$pkglibdir/pg_durable${PG_DLSUFFIX:-.so}"
printf "default_version = '0.2.6'\n" > "$out_dir$extension_dir/pg_durable.control"
printf 'install sql\n' > "$out_dir$extension_dir/pg_durable--0.2.6.sql"
printf 'upgrade sql\n' > "$out_dir$extension_dir/pg_durable--0.2.5--0.2.6.sql"
EOF
chmod +x "$FAKE_CARGO"

cd "$ROOT_DIR"

unowned_dir="$TEST_DIR/unowned-package"
mkdir -p "$unowned_dir"
printf 'keep\n' > "$unowned_dir/unrelated-file"
if make --no-print-directory package \
    PG_CONFIG="$TEST_PG_CONFIG_17" \
    CARGO=false \
    PGRX_PACKAGE_DIR="$unowned_dir" > "$TEST_DIR/unowned.out" 2>&1; then
    echo "package unexpectedly replaced an unowned directory" >&2
    exit 1
fi
grep -F "refusing to replace unowned package directory" "$TEST_DIR/unowned.out" > /dev/null
test -f "$unowned_dir/unrelated-file"

for test_case in 17:.so 18:.so 17:.dylib 18:.dylib; do
    major="${test_case%%:*}"
    dlsuffix="${test_case#*:}"
    pg_config_variable="TEST_PG_CONFIG_$major"
    pg_config="${!pg_config_variable}"
    suffix_label="${dlsuffix#.}"
    package_dir="$TEST_DIR/package $major-$suffix_label"
    stage_dir="$TEST_DIR/stage-$major-$suffix_label"

    : > "$CARGO_LOG"
    if [[ "$test_case" == "17:.so" ]]; then
        make --no-print-directory package \
            PG_CONFIG="$pg_config" \
            CARGO="$FAKE_CARGO" \
            PGRX_PACKAGE_DIR="$package_dir" \
            PG_DLSUFFIX="$dlsuffix" \
            EXTRA_FEATURES=http-allow-azure-domains
        grep -F -- "--features pg17\\ http-allow-azure-domains" "$CARGO_LOG" > /dev/null
    else
        make --no-print-directory \
            PG_VERSION="pg$major" \
            CARGO="$FAKE_CARGO" \
            PGRX_PACKAGE_DIR="$package_dir" \
            PG_DLSUFFIX="$dlsuffix"
        grep -F -- "--features pg$major" "$CARGO_LOG" > /dev/null
    fi
    cargo_calls="$(wc -l < "$CARGO_LOG")"

    PATH=/usr/bin:/bin make --no-print-directory install help \
        PG_CONFIG="$pg_config" \
        CARGO=/missing/cargo \
        PGXS=/caller/supplied/pgxs.mk \
        PGRX_PACKAGE_DIR="$package_dir" \
        PG_DLSUFFIX="$dlsuffix" \
        DESTDIR="$stage_dir" > /dev/null

    test "$(wc -l < "$CARGO_LOG")" -eq "$cargo_calls"
    test -f "$stage_dir/usr/lib/postgresql/$major/lib/pg_durable$dlsuffix"
    test -f "$stage_dir/usr/share/postgresql/$major/extension/pg_durable.control"
    test -f "$stage_dir/usr/share/postgresql/$major/extension/pg_durable--0.2.6.sql"
    test -f "$stage_dir/usr/share/postgresql/$major/extension/pg_durable--0.2.5--0.2.6.sql"
    test "$(file_mode "$stage_dir/usr/lib/postgresql/$major/lib/pg_durable$dlsuffix")" = "755"
    test "$(file_mode "$stage_dir/usr/share/postgresql/$major/extension/pg_durable.control")" = "644"
    test "$(file_mode "$stage_dir/usr/share/postgresql/$major/extension/pg_durable--0.2.6.sql")" = "644"

    printf 'unrelated library\n' > "$stage_dir/usr/lib/postgresql/$major/lib/other_extension.so"
    printf 'unrelated control\n' > "$stage_dir/usr/share/postgresql/$major/extension/other_extension.control"
    printf 'unrelated sql\n' > "$stage_dir/usr/share/postgresql/$major/extension/other_extension--1.0.sql"
    if [[ "$major" == "17" ]]; then
        rm "$stage_dir/usr/share/postgresql/17/extension/pg_durable.control"
    fi

    # `pgxn uninstall` runs uninstall directly on an unbuilt source tree, so it
    # must not need a package directory, and must remove exactly what install put
    # down.
    PATH=/usr/bin:/bin make --no-print-directory uninstall \
        PG_CONFIG="$pg_config" \
        CARGO=/missing/cargo \
        PGXS=/caller/supplied/pgxs.mk \
        PGRX_PACKAGE_DIR="$TEST_DIR/missing-package" \
        PG_DLSUFFIX="$dlsuffix" \
        DESTDIR="$stage_dir" > /dev/null

    test "$(wc -l < "$CARGO_LOG")" -eq "$cargo_calls"
    test ! -e "$stage_dir/usr/lib/postgresql/$major/lib/pg_durable$dlsuffix"
    test ! -e "$stage_dir/usr/share/postgresql/$major/extension/pg_durable.control"
    test -z "$(find "$stage_dir/usr/share/postgresql/$major/extension" -name 'pg_durable--*.sql')"
    test -f "$stage_dir/usr/lib/postgresql/$major/lib/other_extension.so"
    test -f "$stage_dir/usr/share/postgresql/$major/extension/other_extension.control"
    test -f "$stage_dir/usr/share/postgresql/$major/extension/other_extension--1.0.sql"

    # Removing twice is not an error; a partial install must always be cleanable.
    make --no-print-directory uninstall \
        PG_CONFIG="$pg_config" \
        PG_DLSUFFIX="$dlsuffix" \
        DESTDIR="$stage_dir" > "$TEST_DIR/uninstall-again-$major.out"
    grep -F "nothing to remove" "$TEST_DIR/uninstall-again-$major.out" > /dev/null
done

pg16_config="$(create_pg_config 16)"
if make --no-print-directory -n package PG_CONFIG="$pg16_config" > "$TEST_DIR/pg16.out" 2>&1; then
    echo "PostgreSQL 16 was unexpectedly accepted" >&2
    exit 1
fi
grep -F "pg_durable supports PostgreSQL 17 and 18" "$TEST_DIR/pg16.out" > /dev/null

if make --no-print-directory install \
    PG_CONFIG="$TEST_PG_CONFIG_17" \
    PGRX_PACKAGE_DIR="$TEST_DIR/missing-package" > "$TEST_DIR/missing.out" 2>&1; then
    echo "install unexpectedly succeeded without packaged artifacts" >&2
    exit 1
fi
grep -F "run 'make package' first" "$TEST_DIR/missing.out" > /dev/null

for artifact in control sql; do
    partial_dir="$TEST_DIR/partial-$artifact"
    cp -a "$TEST_DIR/package 17-so" "$partial_dir"
    if [[ "$artifact" == "control" ]]; then
        rm "$partial_dir/usr/share/postgresql/17/extension/pg_durable.control"
        expected_error="missing packaged control file"
    else
        rm "$partial_dir/usr/share/postgresql/17/extension"/pg_durable--*.sql
        expected_error="missing packaged SQL files"
    fi

    if make --no-print-directory install \
        PG_CONFIG="$TEST_PG_CONFIG_17" \
        PG_DLSUFFIX=.so \
        PGRX_PACKAGE_DIR="$partial_dir" > "$TEST_DIR/partial-$artifact.out" 2>&1; then
        echo "install unexpectedly accepted a package without $artifact files" >&2
        exit 1
    fi
    grep -F "$expected_error" "$TEST_DIR/partial-$artifact.out" > /dev/null
done

if make --no-print-directory -n install installcheck \
    PG_CONFIG="$TEST_PG_CONFIG_17" > "$TEST_DIR/mixed-goals.out" 2>&1; then
    echo "install and installcheck were unexpectedly accepted together" >&2
    exit 1
fi
grep -F "run 'make install' or 'make uninstall' and 'make installcheck' as separate commands" "$TEST_DIR/mixed-goals.out" > /dev/null

# The Debian package ships the whole packaged tree while install copies a fixed
# set of files, so an unexpected artifact must fail loudly rather than be dropped
# silently from source installs.
stray_dir="$TEST_DIR/stray-package"
cp -a "$TEST_DIR/package 17-so" "$stray_dir"
printf 'bitcode\n' > "$stray_dir/usr/lib/postgresql/17/lib/pg_durable.bc"
if make --no-print-directory install \
    PG_CONFIG="$TEST_PG_CONFIG_17" \
    PG_DLSUFFIX=.so \
    PGRX_PACKAGE_DIR="$stray_dir" \
    DESTDIR="$TEST_DIR/stray-stage" > "$TEST_DIR/stray.out" 2>&1; then
    echo "install unexpectedly accepted an unrecognized packaged file" >&2
    exit 1
fi
grep -F "packaged tree contains files this target does not install" "$TEST_DIR/stray.out" > /dev/null
grep -F "pg_durable.bc" "$TEST_DIR/stray.out" > /dev/null

# `pgxn check` calls installcheck directly, with PG_CONFIG on the command line
# and no wrapper, so that invocation shape must still resolve PGXS.
make --no-print-directory -n installcheck \
    PG_CONFIG="$TEST_PG_CONFIG_17" \
    CONTRIB_TESTDB=contrib_regression > "$TEST_DIR/installcheck.out" 2>&1
grep -F "pgxs installcheck" "$TEST_DIR/installcheck.out" > /dev/null

# Match conventional PGXS builds: a supported pg_config on PATH remains enough
# to run installcheck when PostgreSQL is not registered with cargo-pgrx.
path_bin="$TEST_DIR/path-pg17"
mkdir -p "$path_bin"
ln -s "$TEST_PG_CONFIG_17" "$path_bin/pg_config"
PATH="$path_bin:/usr/bin:/bin" make --no-print-directory -n installcheck \
    CARGO=/missing/cargo \
    CONTRIB_TESTDB=contrib_regression > "$TEST_DIR/installcheck-path.out" 2>&1
grep -F "pgxs installcheck" "$TEST_DIR/installcheck-path.out" > /dev/null

if make --no-print-directory -n uninstall installcheck \
    PG_CONFIG="$TEST_PG_CONFIG_17" > "$TEST_DIR/mixed-uninstall.out" 2>&1; then
    echo "uninstall and installcheck were unexpectedly accepted together" >&2
    exit 1
fi
grep -F "as separate commands" "$TEST_DIR/mixed-uninstall.out" > /dev/null

# `pgxn install` runs `make all` and then `make install`, and never runs
# `cargo pgrx init`, so package must create the cargo-pgrx configuration itself
# when none exists. Without this a first build on a clean machine fails with
# "$PGRX_HOME does not exist".
auto_init_home="$TEST_DIR/pgrx-auto"
: > "$CARGO_LOG"
PGRX_HOME="$auto_init_home" make --no-print-directory package \
    PG_CONFIG="$TEST_PG_CONFIG_17" \
    CARGO="$FAKE_CARGO" \
    PGRX_PACKAGE_DIR="$TEST_DIR/auto-init-package" \
    PG_DLSUFFIX=.so > "$TEST_DIR/auto-init.out" 2>&1
grep -F "cargo-pgrx is not initialized" "$TEST_DIR/auto-init.out" > /dev/null
grep -F "pgrx init --pg17" "$CARGO_LOG" > /dev/null
test -f "$auto_init_home/config.toml"
test -f "$TEST_DIR/auto-init-package/usr/lib/postgresql/17/lib/pg_durable.so"

# An existing configuration is left alone: only its absence triggers init.
# Packaging must still run after the init guard; skipping init must not skip
# `cargo pgrx package`.
: > "$CARGO_LOG"
PGRX_HOME="$auto_init_home" make --no-print-directory package \
    PG_CONFIG="$TEST_PG_CONFIG_17" \
    CARGO="$FAKE_CARGO" \
    PGRX_PACKAGE_DIR="$TEST_DIR/auto-init-package-again" \
    PG_DLSUFFIX=.so > /dev/null 2>&1
if grep -F "pgrx init" "$CARGO_LOG" > /dev/null; then
    echo "package re-initialized cargo-pgrx despite an existing configuration" >&2
    exit 1
fi
grep -F "pgrx package" "$CARGO_LOG" > /dev/null
test -f "$TEST_DIR/auto-init-package-again/usr/lib/postgresql/17/lib/pg_durable.so"

# PGRX_AUTO_INIT=0 opts out and must name the command to run instead.
: > "$CARGO_LOG"
if PGRX_HOME="$TEST_DIR/pgrx-optout" make --no-print-directory package \
    PGRX_AUTO_INIT=0 \
    PG_CONFIG="$TEST_PG_CONFIG_17" \
    CARGO="$FAKE_CARGO" \
    PGRX_PACKAGE_DIR="$TEST_DIR/optout-package" > "$TEST_DIR/optout.out" 2>&1; then
    echo "package unexpectedly built without a cargo-pgrx configuration" >&2
    exit 1
fi
grep -F "cargo-pgrx is not initialized" "$TEST_DIR/optout.out" > /dev/null
grep -F "make pgrx-init PG_CONFIG=" "$TEST_DIR/optout.out" > /dev/null
test ! -s "$CARGO_LOG"

# pgrx-init derives the major version from pg_config rather than PG_VERSION.
: > "$CARGO_LOG"
make --no-print-directory pgrx-init \
    PG_CONFIG="$TEST_PG_CONFIG_18" \
    CARGO="$FAKE_CARGO" > /dev/null 2>&1
grep -F "pgrx init --pg18" "$CARGO_LOG" > /dev/null

# install-pgrx installs the cargo-pgrx release pinned in Cargo.toml, so the
# build tool and the pgrx crate cannot drift apart.
pgrx_version="$(sed -nE 's/^pgrx[[:space:]]*=[[:space:]]*"=?([0-9][^"]*)".*/\1/p' Cargo.toml | head -1)"
test -n "$pgrx_version"
: > "$CARGO_LOG"
make --no-print-directory install-pgrx CARGO="$FAKE_CARGO" > /dev/null 2>&1
grep -F "install --locked cargo-pgrx --version $pgrx_version" "$CARGO_LOG" > /dev/null

echo "Makefile source installation checks passed"