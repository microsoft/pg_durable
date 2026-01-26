# pg_regress configuration for pg_durable
EXTENSION = pg_durable
DATA = pg_durable--0.1.1.sql

# Test files (in order)
REGRESS = simple sequence variables parallel conditional templates

# PostgreSQL configuration
PG_CONFIG ?= $(shell cargo pgrx info pg-config pg17)
PGXS := $(shell $(PG_CONFIG) --pgxs)

# Connection parameters for pgrx-managed PostgreSQL
REGRESS_OPTS = --host=localhost --port=28817 --load-extension=pg_durable

include $(PGXS)
