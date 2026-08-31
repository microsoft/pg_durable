# pg_durable Extension Compatibility

Compatibility evaluation of pg_durable against PostgreSQL extensions available on [Azure Database for PostgreSQL – Flexible Server](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-versions), plus Citus.

## Key pg_durable characteristics affecting compatibility

| Characteristic | Detail |
|---|---|
| **Schemas** | Owns `df` and `duroxide` schemas; no public-schema pollution |
| **Background worker** | Single BGW (`pg_durable_worker`), requires `shared_preload_libraries` and a superuser role |
| **SQL execution** | BGW executes workflow SQL via **sqlx** (async TCP connections), **not** SPI. Two connection contexts: (1) worker role for df/duroxide state management, (2) submitting user's role for workflow SQL execution |
| **Hooks** | None — no executor, planner, utility, or parse hooks |
| **RLS** | Enabled (not forced) on `df.instances`, `df.nodes`, `df.vars` |
| **Operators** | `~>`, `\|=>`, `&`, `\|`, `?>`, `!>`, `@>` — all on `text` operands |
| **Custom types / AMs** | None |
| **GUCs** | `pg_durable.worker_role`, `pg_durable.database` (postmaster context) |
| **LISTEN/NOTIFY** | Used by duroxide long-polling in BGW (own channels) |
| **WAL / replication** | No custom WAL resources; standard heap tables only |

## Compatibility ratings

- **Full** — Works out of the box, no known issues.
- **Full\*** — Works, but a specific interaction is worth knowing about (see notes).
- **Partial** — Functional, but some features don't compose or need workarounds.
- **Risky** — Likely to break or require significant integration work.

## Compatibility table

| Extension | HorizonDB | Compat | What's most likely to go wrong | Fix effort |
|---|---|---|---|---|
| **address_standardizer** | Yes | Full | Nothing — pure data-type/function extension, separate schema. | — |
| **address_standardizer_data_us** | Yes | Full | Nothing — geocoding reference data, no runtime interaction. | — |
| **age** (Apache AGE) | Yes | Full | Nothing — graph database extension adding `ag_catalog` schema, `agtype` type, and Cypher query language via executor hooks. pg_durable has no hooks, so no conflict. BGW sqlx connections load AGE if it's in `shared_preload_libraries`, so `df.sql()` can execute `cypher()` graph queries. | — |
| **amcheck** | Yes | Full | Nothing — read-only B-tree verification functions. | — |
| **anon** (PostgreSQL Anonymizer) | No | Full* | anon's dynamic masking uses security labels and views. No conflict, but masking rules won't apply inside BGW sqlx connections unless the masking role/policy is explicitly configured there. | Low — configure anon policies for the BGW role if needed. |
| **azure** | Yes | Full | Nothing — Azure platform integration extension (managed identity, metrics). Internal extension loaded via `shared_preload_libraries`, no schema or hook conflicts. | — |
| **azure_ai** | Yes | Full | Nothing — callable functions for Azure AI services. Can be used inside `df.sql()`. | — |
| **azure_local_ai** | No | Full | Nothing — local ML inference functions. | — |
| **azure_storage** | Yes | Full | Nothing — Azure Blob access functions. Can be used inside `df.sql()`. | — |
| **bloom** | Yes | Full | Nothing — alternative index access method, transparent to pg_durable. | — |
| **btree_gin** | Yes | Full | Nothing — adds GIN operator classes for scalar types. | — |
| **btree_gist** | Yes | Full | Nothing — adds GiST operator classes for scalar types. | — |
| **Citus** | No | Partial | **df.\* and duroxide.\* tables must NOT be distributed.** Citus shards distributed tables across worker nodes, but the pg_durable BGW runs only on the coordinator and expects local tables. Distributing `df.instances` or `df.nodes` will break instance tracking. RLS policies may not propagate correctly to Citus workers. However, workflow SQL (`df.sql()`) **can** query distributed tables normally. Also: Citus's `citus.main_db` BGW will compete for resources. | Medium — ensure df/duroxide schemas are excluded from distribution (`SELECT citus_add_local_table_to_metadata()`). No code changes needed if tables stay local. |
| **citext** | Yes | Full | Nothing — case-insensitive text type, orthogonal. | — |
| **cube** | Yes | Full | Nothing — geometric data type, no runtime overlap. | — |
| **dblink** | Yes | Full | Nothing — cross-database queries. Can be called from `df.sql()`. | — |
| **dict_int** | Yes | Full | Nothing — text search dictionary. | — |
| **dict_xsyn** | Yes | Full | Nothing — text search dictionary. | — |
| **earthdistance** | Yes | Full | Nothing — distance calculation functions (depends on cube). | — |
| **file_fdw** | Yes | Full* | Foreign data wrapper for server-side flat files. `df.sql()` can query file_fdw foreign tables. The BGW executes workflow SQL as the submitting user, so that user must have access to the foreign server definition. File paths must be accessible to the PostgreSQL server process. | Low — ensure foreign server/user mappings exist for roles that submit workflows. |
| **fuzzystrmatch** | Yes | Full | Nothing — string matching functions. | — |
| **hstore** | Yes | Full | Nothing — key-value data type. | — |
| **hypopg** | Yes | Full* | hypopg uses planner hooks to inject hypothetical indexes. Since pg_durable's BGW uses sqlx (separate connections), hypothetical indexes will **not** affect workflow SQL execution — they only apply to the session that created them. This is expected behavior, not a bug. | — |
| **intagg** | Yes | Full | Nothing — integer aggregation functions. | — |
| **intarray** | Yes | Full | Nothing — integer array operators. Defines `&` and `\|` on `int[]`, not on `text` — no operator conflict. | — |
| **isn** | Yes | Full | Nothing — ISN data types (ISBN, ISSN, etc.). | — |
| **lo** | Yes | Full | Nothing — large object management trigger. | — |
| **ltree** | Yes | Full | Nothing — hierarchical label type. | — |
| **orafce** | No | Full | Nothing — Oracle compatibility functions and packages. | — |
| **orion_storage** | Yes | Full | Nothing — Azure internal storage-layer extension loaded via `shared_preload_libraries`. No schema or hook conflicts with pg_durable. | — |
| **pageinspect** | Yes | Full | Nothing — low-level page inspection functions. | — |
| **pg_availability** | Yes | Full | Nothing — Azure internal availability monitoring extension loaded via `shared_preload_libraries`. No schema or hook conflicts with pg_durable. | — |
| **pg_buffercache** | Yes | Full | Nothing — read-only shared buffer introspection. | — |
| **pg_cron** | Yes | Full* | Both use background workers and require `shared_preload_libraries`. No direct conflict — different BGWs, different schemas, different GUCs. `pg_cron` can schedule `df.start()` calls, making them complementary. Minor concern: both BGWs maintain their own connection pools, so under very high load they compete for `max_connections` slots. | None — works well as a combination. |
| **pg_diskann** | Yes | Full | Nothing — DiskANN-based vector index access method. Transparent to pg_durable; `df.sql()` queries using DiskANN indexes work normally via the standard planner/executor in BGW sqlx connections. | — |
| **pg_failover_slots** | No | Full | Nothing — replication slot management, different layer. | — |
| **pg_freespacemap** | Yes | Full | Nothing — FSM inspection functions. | — |
| **pg_fts** | Yes | Full | Nothing — Azure enhanced full-text search extension. No hook or schema conflicts. `df.sql()` can execute full-text search queries. | — |
| **pg_hint_plan** | No | Full* | pg_hint_plan uses planner hooks to inject query hints. Since pg_durable's BGW executes SQL via **sqlx** (regular TCP connections, not SPI), pg_hint_plan **will** be loaded in those connections (if in `shared_preload_libraries` or `session_preload_libraries`). Comment-based hints embedded in `df.sql()` queries **will work**. The BGW executes workflow SQL as the submitting user, so `pg_hint_plan.hints` table-based hints **do apply** if configured for that user. The only limitation is that the BGW session is not the user's interactive session, so session-level hint state does not carry over. | — |
| **pg_partman** | No | Full* | Works. Users could partition `df.instances` by `created_at` for large deployments. pg_partman's BGW (for auto-maintenance) coexists with pg_durable's BGW. Minor consideration: partitioning `df.nodes` requires care since the BGW queries by `instance_id`. | Low — ensure partition keys match BGW query patterns. |
| **pg_partman_bgw** | Yes | Full* | Background worker component of pg_partman for automatic partition maintenance. Both pg_durable and pg_partman_bgw run independent BGWs via `shared_preload_libraries` that coexist without conflict. Minor concern: both maintain connection pools competing for `max_connections` slots under heavy load. Users could partition `df.instances` by `created_at` for large deployments; partitioning `df.nodes` requires care since the BGW queries by `instance_id`. | Low — ensure partition keys match BGW query patterns. Monitor resource usage under high concurrency. |
| **pg_prewarm** | Yes | Full | Nothing — buffer prewarming utility. | — |
| **pg_qs** | Yes | Full* | Azure internal query store extension using executor hooks to capture query statistics. No hook conflict with pg_durable. BGW sqlx connections are regular client connections — workflow SQL queries **will** be captured by query store, useful for monitoring workflow performance. | — |
| **pg_repack** | Yes | Full* | Works. Can repack `df.instances` and `df.nodes` to reclaim space. Takes a brief exclusive lock during the swap phase, which may momentarily block `df.start()` or BGW updates. | None — standard operational consideration. |
| **pg_squeeze** | No | Full* | Same as pg_repack — concurrent table reorganization with brief lock at swap. | None. |
| **pg_stat_statements** | Yes | Full* | Uses executor hooks to capture statistics. pg_durable has no hooks, so no conflict. BGW sqlx connections are regular client connections — their queries **will** appear in `pg_stat_statements`. This is actually useful for monitoring workflow SQL performance. Workflow SQL queries appear under the submitting user's role; df state management queries appear under the worker role. | — |
| **pg_surgery** | Yes | Full | Nothing — administrative tool for repairing corrupted heap tuples. No runtime interaction with pg_durable. | — |
| **pg_trgm** | Yes | Full | Nothing — trigram-based text similarity functions and GIN/GiST ops. | — |
| **pg_visibility** | Yes | Full | Nothing — visibility map inspection functions. | — |
| **pgaudit** | Yes | Full* | pgaudit uses executor/utility hooks to log SQL statements. No hook conflict with pg_durable. BGW sqlx connections are regular client connections, so pgaudit **will** audit workflow SQL execution (logged under the submitting user's role). df state management is logged under the worker role. This is a feature, not a bug — full audit trail of workflow activity. | — |
| **pgcrypto** | Yes | Full | Nothing — cryptographic functions. Can be used inside `df.sql()`. | — |
| **pglogical** | No | Partial | pglogical performs logical replication of DML changes. `df.instances`, `df.nodes`, and duroxide state tables will be replicated to subscribers. **Risk: if pg_durable is installed on both publisher and subscriber, the subscriber's BGW will attempt to execute replicated instances**, causing duplicate workflow execution. The `duroxide` schema tables must be replicated atomically with `df.*` tables. | Medium — disable pg_durable BGW on replicas (set `shared_preload_libraries` without pg_durable, or set an unused `pg_durable.database`). Need operational discipline. |
| **pgms_stats** | Yes | Full | Nothing — Azure internal statistics collection extension loaded via `shared_preload_libraries`. No schema or hook conflicts with pg_durable. | — |
| **pgms_wait_sampling** | Yes | Full* | Azure wait event sampling extension with its own BGW loaded via `shared_preload_libraries`. No hook conflicts. pg_durable BGW wait events will be sampled — useful for diagnosing workflow execution bottlenecks. Multiple BGWs coexist without issues. | — |
| **pgrowlocks** | Yes | Full | Nothing — row-level lock inspection functions. | — |
| **pgstattuple** | Yes | Full | Nothing — tuple-level statistics functions. | — |
| **plpgsql** | No | Full | Nothing — PL/pgSQL is the default procedural language. `df.sql()` can call PL/pgSQL functions. `df.if()` condition queries return PL/pgSQL-compatible boolean-ish results. | — |
| **plv8** | No | Full | Nothing — V8 JavaScript procedural language. `df.sql()` can call PLV8 functions. | — |
| **postgis** | Yes | Full | Nothing — spatial types and functions. `df.sql()` can run spatial queries. | — |
| **postgis_raster** | Yes | Full | Nothing — raster type support for PostGIS. | — |
| **postgis_sfcgal** | Yes | Full | Nothing — SFCGAL-backed 3D geometry functions. | — |
| **postgis_tiger_geocoder** | Yes | Full | Nothing — US Census TIGER geocoder, data-only extension. | — |
| **postgis_topology** | Yes | Full | Nothing — topology type and functions for PostGIS. | — |
| **postgres_fdw** | No | Full* | Foreign data wrappers work. `df.sql()` can query foreign tables. The BGW executes workflow SQL as the submitting user, so FDW user mappings for that user apply directly. | Low — ensure FDW user mappings exist for roles that submit workflows. |
| **seg** | Yes | Full | Nothing — floating-point interval data type, no runtime overlap. | — |
| **semver** | No | Full | Nothing — semantic versioning data type. | — |
| **spi** | Yes | Full | Nothing — trigger-based utility functions (autoinc, moddatetime, etc.). No hooks or schema conflicts. Triggers fire normally on tables modified by `df.sql()`. | — |
| **sslinfo** | Yes | Full | Nothing — SSL certificate info functions. Note: BGW sqlx connections are local TCP, so `ssl_is_used()` will return false in BGW-executed queries. | — |
| **tablefunc** | Yes | Full | Nothing — crosstab and other table functions. Can be used in `df.sql()`. | — |
| **tcn** | Yes | Full | Nothing — triggered change notifications (fires NOTIFY on table changes). Uses NOTIFY on different channels than duroxide. No conflict. | — |
| **timescaledb** | No | Full* | TimescaleDB uses BGWs (for compression, retention, continuous aggregates) and planner/executor hooks. No hook conflict since pg_durable uses none. BGW sqlx connections load TimescaleDB if it's in `shared_preload_libraries`, so `df.sql()` queries against hypertables work correctly — TimescaleDB's planner hooks will fire and route queries to chunks. Multiple BGWs coexist (resource competition under heavy load). | None — both extensions' BGWs coexist. Monitor resource usage under high concurrency. |
| **tsm_system_rows** | Yes | Full | Nothing — TABLESAMPLE method. | — |
| **tsm_system_time** | Yes | Full | Nothing — TABLESAMPLE method. | — |
| **unaccent** | Yes | Full | Nothing — text search dictionary for accent removal. | — |
| **uuid-ossp** | Yes | Full | Nothing — UUID generation functions. | — |
| **vector** (pgvector) | Yes | Full | Nothing — vector data type and similarity search. `df.sql()` can run vector queries. Useful combo: durable pipelines that do embedding lookups. | — |
| **wal2json** | Yes | Full* | Logical decoding output plugin producing JSON from WAL changes. pg_durable uses standard heap tables, so DML on `df.*` and `duroxide.*` tables will appear in wal2json output. No runtime conflict. Note: if wal2json output is consumed to replay changes into another pg_durable instance, duplicate workflow execution could occur (same risk as pglogical). | Low — do not replay `df`/`duroxide` schema changes into another pg_durable-enabled database. |
| **xml2** | Yes | Full | Nothing — XML processing functions. | — |

## Summary

Out of all evaluated extensions, only two have meaningful compatibility considerations:

| Extension | Issue | Severity |
|---|---|---|
| **Citus** | df/duroxide tables must stay local (not distributed) | Medium — operational constraint, no code fix needed |
| **pglogical** | Replicated instances may trigger duplicate BGW execution on subscriber | Medium — must disable BGW on replicas |

Everything else works without issues. The core reason is that pg_durable has a minimal PostgreSQL footprint: no hooks, no custom types, no custom WAL, no custom access methods. The `df` and `duroxide` schemas are fully self-contained. The BGW uses standard PostgreSQL connections (via sqlx), which means hook-based extensions like pg_stat_statements, pgaudit, and TimescaleDB naturally interoperate with workflow SQL execution.
