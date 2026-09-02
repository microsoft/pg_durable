# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# pg_durable Makefile

# PostgreSQL major version for pgrx (override with: make ... PG_VERSION=pg18)
PG_VERSION ?= pg17
CARGO ?= cargo
EXTRA_FEATURES ?=
ACR_REGISTRY ?= myregistry.azurecr.io
ACR_IMAGE ?= pg_durable

.PHONY: all build package install uninstall test test-unit test-e2e test-regress pg-clean docker-build docker-push pg-install pgxn-zip install-pgrx pgrx-init

# Default target
all: package

# Build the extension
build:
	cargo build

# Build release artifacts for source installation. This runs without elevated
# privileges; `install` only copies the resulting package tree.
package:
	@if test -e "$(PGRX_PACKAGE_DIR)" \
	    && test "$(PGRX_PACKAGE_DIR)" != "$(DEFAULT_PGRX_PACKAGE_DIR)" \
	    && test ! -f "$(PGRX_PACKAGE_MARKER)" \
	    && { test ! -d "$(PGRX_PACKAGE_DIR)" \
	        || test -n "$$(ls -A "$(PGRX_PACKAGE_DIR)" 2>/dev/null)"; }; then \
	    echo "refusing to replace unowned package directory: $(PGRX_PACKAGE_DIR)" >&2; \
	    exit 1; \
	fi
	@set -eu; \
	if test ! -f "$(PGRX_CONFIG)"; then \
	    if test "$(PGRX_AUTO_INIT)" = "0"; then \
	        echo "cargo-pgrx is not initialized: $(PGRX_CONFIG) not found" >&2; \
	        echo "run: $(MAKE) pgrx-init PG_CONFIG=\"$(PG_CONFIG)\"" >&2; \
	        exit 1; \
	    fi; \
	    echo "cargo-pgrx is not initialized; running 'cargo pgrx init --pg$(PG_MAJOR)'"; \
	    $(CARGO) pgrx init --pg$(PG_MAJOR) "$(PG_CONFIG)"; \
	fi
	rm -rf "$(PGRX_PACKAGE_DIR)"
	$(CARGO) pgrx package --pg-config "$(PG_CONFIG)" \
	    --out-dir "$(PGRX_PACKAGE_DIR)" \
	    --no-default-features --features "$(strip pg$(PG_MAJOR) $(EXTRA_FEATURES))"
	@touch "$(PGRX_PACKAGE_MARKER)"

# Run all tests (unit + E2E)
test:
	./scripts/test.sh --all

# Run only pgrx unit tests
test-unit:
	./scripts/test.sh --unit

# Run only E2E tests (Docker-based)
test-e2e:
	./scripts/test.sh --e2e

# Build Docker image
docker-build:
	docker build --platform linux/amd64 -t pg_durable:latest .

# Build and push to ACR
docker-push: docker-build
	docker tag pg_durable:latest $(ACR_REGISTRY)/$(ACR_IMAGE):latest
	REGISTRY_NAME="$(ACR_REGISTRY)"; az acr login --name "$${REGISTRY_NAME%%.*}"
	docker push $(ACR_REGISTRY)/$(ACR_IMAGE):latest

# Run local development server
run:
	cargo pgrx run pg17

# Clean build artifacts (renamed to avoid PGXS conflict)
pg-clean:
	cargo clean
	rm -rf target/
	rm -f META.json $(DISTNAME)-$(DISTVERSION).zip

# Install extension locally (renamed to avoid PGXS conflict)
pg-install:
	cargo pgrx install --features http-allow-test-domains

# Run pg_regress tests (convenience target)
# Override version: make test-regress PG_VERSION=pg18
test-regress:
	@echo "Resetting PostgreSQL..."
	./scripts/pg-reset.sh $(subst pg,,$(PG_VERSION))
	@echo "Starting PostgreSQL with PGDATABASE=contrib_regression..."
	PGDATABASE=contrib_regression ./scripts/pg-start.sh --pg-version $(subst pg,,$(PG_VERSION))
	@echo "Running pg_regress tests..."
	PGHOST=$(HOME)/.pgrx PGUSER=postgres PG_CONFIG=$$(cargo pgrx info pg-config $(PG_VERSION)) $(MAKE) -e installcheck

# Help
help:
	@echo "pg_durable Makefile targets:"
	@echo ""
	@echo "  all           - Build release artifacts for source installation"
	@echo "  build         - Build the extension in debug mode"
	@echo "  package       - Build release artifacts for source installation"
	@echo "  test          - Run all tests (unit + E2E)"
	@echo "  test-unit     - Run pgrx unit tests only"
	@echo "  test-e2e      - Run E2E tests only (Docker)"
	@echo "  test-regress  - Run pg_regress tests (resets and starts PostgreSQL)"
	@echo "  installcheck  - Run pg_regress tests (requires PostgreSQL running, via PGXS)"
	@echo "  docker-build  - Build Docker image"
	@echo "  docker-push   - Build and push to ACR"
	@echo "  run           - Start local pgrx dev server"
	@echo "  pg-clean      - Clean build artifacts"
	@echo "  install       - Install prebuilt artifacts for the selected PostgreSQL"
	@echo "  uninstall     - Remove installed artifacts for the selected PostgreSQL"
	@echo "  pg-install    - Install extension locally"
	@echo "  pgxn-zip      - Build the PGXN release bundle (META.json + zip)"
	@echo "  install-pgrx  - Install the cargo-pgrx release pinned in Cargo.toml"
	@echo "  pgrx-init     - Register PG_CONFIG with cargo-pgrx (needed once per machine)"

# ============================================================================
# cargo-pgrx toolchain
# ============================================================================
# cargo-pgrx keeps its configuration in $PGRX_HOME (default ~/.pgrx) and refuses
# to build without it, failing with "$PGRX_HOME does not exist" or
# "config.toml not found". Only `cargo pgrx init` creates that file.
#
# Installers that drive this Makefile never run it: `pgxn install pg_durable`
# runs `make all` and then `make install`, so on a machine that has PostgreSQL,
# Rust and cargo-pgrx but has never initialized pgrx, `package` failed before
# the guard in that target existed.
#
# Only the presence of config.toml matters. `package` always passes an explicit
# --pg-config, so the entries recorded in that file are never consulted, and an
# existing pgrx configuration naming a different PostgreSQL cannot redirect the
# build.
PGRX_VERSION = $(shell sed -nE 's/^pgrx[[:space:]]*=[[:space:]]*"=?([0-9][^"]*)".*/\1/p' Cargo.toml | head -1)
PGRX_HOME_DIR = $(if $(PGRX_HOME),$(PGRX_HOME),$(HOME)/.pgrx)
PGRX_CONFIG = $(PGRX_HOME_DIR)/config.toml

# Install the cargo-pgrx release pinned in Cargo.toml, so the build tool and the
# pgrx crate cannot drift apart.
install-pgrx:
	$(CARGO) install --locked cargo-pgrx --version "$(PGRX_VERSION)"

# Register PG_CONFIG with cargo-pgrx. Passing an existing pg_config makes this a
# validate-and-record step: cargo-pgrx does not download or build a PostgreSQL
# of its own.
pgrx-init:
	$(CARGO) pgrx init --pg$(PG_MAJOR) "$(PG_CONFIG)"

# ============================================================================
# PGXN packaging
# ============================================================================
# The distribution version is read from Cargo.toml so the PGXN metadata can
# never drift from the crate version. META.json is generated, not committed.
DISTNAME    = pg_durable
DISTVERSION = $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)

# Render the PGXN metadata, stamping in the Cargo.toml version. This reuses the
# same @CARGO_VERSION@ token that pgrx substitutes into pg_durable.control.
META.json: META.json.in Cargo.toml
	sed 's/@CARGO_VERSION@/$(DISTVERSION)/g' $< > $@

# Build the PGXN release bundle. git archive ships only committed files, so the
# generated META.json is added explicitly.
pgxn-zip: META.json
	git archive --format zip --prefix $(DISTNAME)-$(DISTVERSION)/ \
	    --add-file META.json -o $(DISTNAME)-$(DISTVERSION).zip HEAD

# ============================================================================
# pg_regress (PGXS) configuration
# ============================================================================
EXTENSION = pg_durable

REGRESS = 00_init simple sequence variables parallel conditional

REQUESTED_GOALS := $(if $(MAKECMDGOALS),$(MAKECMDGOALS),all)
PG_CONFIG_GOALS := all package install uninstall installcheck pgrx-init

ifneq ($(filter $(PG_CONFIG_GOALS),$(REQUESTED_GOALS)),)
ifndef PG_CONFIG
PG_CONFIG := $(shell $(CARGO) pgrx info pg-config $(PG_VERSION) 2>/dev/null)
ifeq ($(PG_CONFIG),)
PG_CONFIG := $(shell command -v pg_config 2>/dev/null)
endif
endif

ifeq ($(PG_CONFIG),)
$(error PG_CONFIG is not set and pg_config could not be found via cargo-pgrx or PATH)
endif

PG_MAJOR := $(shell "$(PG_CONFIG)" --version 2>/dev/null | sed -nE 's/^PostgreSQL ([0-9]+).*/\1/p')
ifeq ($(filter $(PG_MAJOR),17 18),)
$(error unsupported PostgreSQL major '$(PG_MAJOR)'; pg_durable supports PostgreSQL 17 and 18)
endif
endif

ifneq ($(filter install uninstall,$(REQUESTED_GOALS)),)
ifneq ($(filter installcheck,$(REQUESTED_GOALS)),)
$(error run 'make install' or 'make uninstall' and 'make installcheck' as separate commands)
endif
endif

# PGXS is used only for the regression-test entry point. Keeping it out of
# normal builds prevents its `install` recipe from conflicting with ours.
ifneq ($(filter installcheck,$(REQUESTED_GOALS)),)
ifndef PGXS
PGXS := $(shell "$(PG_CONFIG)" --pgxs)
endif
include $(PGXS)
endif

# ============================================================================
# Source installation
# ============================================================================
DEFAULT_PGRX_PACKAGE_DIR = $(CURDIR)/target/release/pg_durable-pg$(PG_MAJOR)
PGRX_PACKAGE_DIR ?= $(DEFAULT_PGRX_PACKAGE_DIR)
PGRX_PACKAGE_MARKER = $(PGRX_PACKAGE_DIR).pg_durable-owned
PG_DLSUFFIX ?= $(if $(filter Darwin,$(shell uname -s)),.dylib,.so)

ifeq ($(filter installcheck,$(REQUESTED_GOALS)),)

PG_PKGLIBDIR = $(shell "$(PG_CONFIG)" --pkglibdir)
PG_EXTENSION_DIR = $(shell "$(PG_CONFIG)" --sharedir)/extension
PACKAGE_LIBRARY = $(PGRX_PACKAGE_DIR)$(PG_PKGLIBDIR)/pg_durable$(PG_DLSUFFIX)
PACKAGE_EXTENSION_DIR = $(PGRX_PACKAGE_DIR)$(PG_EXTENSION_DIR)
# Same directories relative to the package root, for auditing the packaged tree.
PG_PKGLIBDIR_REL = $(patsubst /%,%,$(PG_PKGLIBDIR))
PG_EXTENSION_DIR_REL = $(patsubst /%,%,$(PG_EXTENSION_DIR))

install:
	@set -eu; \
	package_library="$(PACKAGE_LIBRARY)"; \
	package_extension_dir="$(PACKAGE_EXTENSION_DIR)"; \
	test -f "$$package_library" || { echo "missing packaged library: $$package_library; run 'make package' first" >&2; exit 1; }; \
	test -f "$$package_extension_dir/pg_durable.control" || { echo "missing packaged control file; run 'make package' first" >&2; exit 1; }; \
	set -- "$$package_extension_dir"/pg_durable--*.sql; \
	test -f "$$1" || { echo "missing packaged SQL files; run 'make package' first" >&2; exit 1; }; \
	unexpected="$$(cd "$(PGRX_PACKAGE_DIR)" && find . -type f \
	    ! -path "./$(PG_PKGLIBDIR_REL)/pg_durable$(PG_DLSUFFIX)" \
	    ! -path "./$(PG_EXTENSION_DIR_REL)/pg_durable.control" \
	    ! -path "./$(PG_EXTENSION_DIR_REL)/pg_durable--*.sql")"; \
	test -z "$$unexpected" || { \
	    echo "packaged tree contains files this target does not install:" >&2; \
	    echo "$$unexpected" >&2; \
	    echo "the Debian package ships the whole tree, so a source install would silently differ from it; extend the install and uninstall recipes or exclude these files" >&2; \
	    exit 1; }; \
	install -d -m 0755 "$(DESTDIR)$(PG_PKGLIBDIR)" "$(DESTDIR)$(PG_EXTENSION_DIR)"; \
	install -m 0755 "$$package_library" "$(DESTDIR)$(PG_PKGLIBDIR)/pg_durable$(PG_DLSUFFIX)"; \
	install -m 0644 "$$package_extension_dir/pg_durable.control" "$$@" "$(DESTDIR)$(PG_EXTENSION_DIR)/"

# `pgxn uninstall` runs this target directly, without building first, so it must
# not depend on a package tree. It removes only what `install` places, and is
# idempotent so a partial installation can always be cleaned up.
uninstall:
	@set -eu; \
	extension_dir="$(DESTDIR)$(PG_EXTENSION_DIR)"; \
	library="$(DESTDIR)$(PG_PKGLIBDIR)/pg_durable$(PG_DLSUFFIX)"; \
	removed=0; \
	if test -e "$$library"; then rm -f "$$library"; removed=1; fi; \
	if test -e "$$extension_dir/pg_durable.control"; then rm -f "$$extension_dir/pg_durable.control"; removed=1; fi; \
	for sql in "$$extension_dir"/pg_durable--*.sql; do \
	    test -e "$$sql" || continue; \
	    rm -f "$$sql"; \
	    removed=1; \
	done; \
	test "$$removed" -eq 1 || echo "pg_durable is not installed for $(PG_CONFIG); nothing to remove"

endif
