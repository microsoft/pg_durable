# pg_regress configuration for pg_durable
EXTENSION = pg_durable
DATA = pg_durable--0.1.1.sql

# Test files (in order)
REGRESS = simple sequence variables parallel conditional

# PostgreSQL configuration
# Check if PG_CONFIG is already set (e.g., from parent Makefile or environment)
# If not, try to get it from pgrx (for development)
ifndef PG_CONFIG
  # Check if we have pg_config in PATH (standard install)
  PG_CONFIG := $(shell which pg_config 2>/dev/null)
  # If not found, try to get it from pgrx
  ifeq ($(PG_CONFIG),)
    PG_CONFIG := $(shell cargo pgrx info pg-config pg17 2>/dev/null)
  endif
endif

PGXS := $(shell $(PG_CONFIG) --pgxs)

# Extract PGPORT from pg_config if not already set in environment
ifndef PGPORT
  PGPORT := $(shell $(PG_CONFIG) --configure 2>/dev/null | grep -oE -- '--with-pgport=[0-9]+' | cut -d= -f2)
  export PGPORT
endif

# Connection parameters - use environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE)
# Default to load-extension for pg_durable
REGRESS_OPTS = --load-extension=pg_durable

include $(PGXS)
