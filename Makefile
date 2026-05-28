# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# pg_durable Makefile

# PostgreSQL major version for pgrx (override with: make ... PG_VERSION=pg16)
PG_VERSION ?= pg17
ACR_REGISTRY ?= myregistry.azurecr.io
ACR_IMAGE ?= pg_durable

.PHONY: build test test-unit test-e2e test-regress pg-clean docker-build docker-push pg-install

# Default target
all: build

# Build the extension
build:
	cargo build

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

# Install extension locally (renamed to avoid PGXS conflict)
pg-install:
	cargo pgrx install --features http-allow-test-domains

# Run pg_regress tests (convenience target)
# Override version: make test-regress PG_VERSION=pg16
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
	@echo "  build         - Build the extension"
	@echo "  test          - Run all tests (unit + E2E)"
	@echo "  test-unit     - Run pgrx unit tests only"
	@echo "  test-e2e      - Run E2E tests only (Docker)"
	@echo "  test-regress  - Run pg_regress tests (resets and starts PostgreSQL)"
	@echo "  installcheck  - Run pg_regress tests (requires PostgreSQL running, via PGXS)"
	@echo "  docker-build  - Build Docker image"
	@echo "  docker-push   - Build and push to ACR"
	@echo "  run           - Start local pgrx dev server"
	@echo "  pg-clean      - Clean build artifacts"
	@echo "  pg-install    - Install extension locally"

# ============================================================================
# pg_regress (PGXS) configuration
# ============================================================================
EXTENSION = pg_durable

REGRESS = 00_init simple sequence variables parallel conditional

ifndef PG_CONFIG
  PG_CONFIG := $(shell cargo pgrx info pg-config $(PG_VERSION) 2>/dev/null)
  ifeq ($(PG_CONFIG),)
    PG_CONFIG := $(shell which pg_config 2>/dev/null)
  endif
endif

ifeq ($(PG_CONFIG),)
  # PG_CONFIG is not available; handle PGXS targets explicitly.
  ifneq ($(filter installcheck,$(MAKECMDGOALS)),)
    $(error PG_CONFIG is not set and could not be auto-detected; cannot run 'make installcheck')
  else
    $(warning PG_CONFIG is not set and could not be auto-detected; PGXS-based targets such as 'installcheck' are unavailable)
  endif
else
  PGXS := $(shell $(PG_CONFIG) --pgxs)
  include $(PGXS)
endif

