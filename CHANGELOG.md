# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0 note: while `pg_durable` is in major version `0`, minor releases may include breaking changes.

## [0.2.4] - 2026-07-02

Provider-line note: v0.2.4 stays in the `duroxide-pg` provider compatibility line, so the upgrade source is v0.2.3 (`sql/pg_durable--0.2.3--0.2.4.sql`).

### Added

- **Instance retention/pruning (#265):** terminal instances are now pruned by a hard cap and a retention window, bounding unbounded growth of `df.instances`.
- **`df.list_instances()` pagination & filtering (#278):** added a `label_filter`, keyset pagination (`after_cursor`/`next_cursor`), and `created_at`/`updated_at` timestamps to the result set.

### Changed

- **`df.wait_for_schedule()` cron timing:** the next cron tick is now computed at execution time using duroxide's deterministic clock (`ctx.utc_now()`) inside the `execute_function_graph` orchestration, instead of being pre-computed at `df.start()` time. This makes recurring `@>` schedules and any start-to-execution delay target the correct upcoming tick (#130).

  > ⚠️ **Replay-breaking for in-flight `wait_for_schedule` instances.** This change adds a recorded `utc_now()` decision before the WAIT_SCHEDULE timer, altering the orchestration's history sequence. Any durable function that was started under a `<= 0.2.3` binary and is **mid-`wait_for_schedule`** (parked on its timer) when this `.so` is loaded will fail with a duroxide nondeterminism error on replay, because its recorded history no longer matches the new code. Drain or allow such in-flight `wait_for_schedule` instances to complete before upgrading. Instances that are not currently inside a `wait_for_schedule` node are unaffected. We accepted this break (rather than introducing orchestration versioning) given the early pre-1.0 stage of the project.

- **Instance/node ID collision hardening (#129):** `df.start()` now reserves IDs with `INSERT ... ON CONFLICT DO NOTHING RETURNING id` and re-rolls the random 8-hex value on collision — instances arbitrate on the `df.instances` primary key (`id`), nodes on the new composite `PRIMARY KEY (instance_id, id)` — replacing the previous `SELECT EXISTS` pre-check. Doing the conflict check at the index level (rather than a pre-check `SELECT`) closes a TOCTOU window and, for instances, an RLS blind spot where the pre-check could not see another role's rows. `df.nodes` now uses the composite `PRIMARY KEY (instance_id, id)` instead of a global single-column key, so the random 8-hex node ID is no longer the sole cross-instance collision guard. The `update-node-status` activity now scopes its `df.nodes` update by `instance_id` (a required activity-input field) and asserts it affects exactly one row. IDs stay `VARCHAR(8)` HEX; the `0.2.3 → 0.2.4` upgrade restructures the `df.nodes` keys in place (#238).
  - **Breaking for in-flight work:** the new activity-input shape changes the string duroxide records in orchestration history, and duroxide validates activity inputs by exact equality on replay, so any instance left **in flight across the 0.2.3 → 0.2.4 binary upgrade** cannot complete. Drain or cancel in-flight instances before deploying 0.2.4. The in-place `df.nodes` key restructure also takes an `ACCESS EXCLUSIVE` lock whose duration scales with table size — run the upgrade in a maintenance window. See the #129 section of `docs/upgrade-testing.md` for the full drain-before-upgrade contract.
- **`df.grant_usage()` / `df.revoke_usage()`:** dropped the explicit per-function `EXECUTE` allowlist. Schema `USAGE` on `df` is the real access gate for ordinary `df.*` functions, so the helpers now grant/revoke schema `USAGE`, the table privileges, and `EXECUTE` only on the sensitive functions (`df.http`, `df.grant_usage`, `df.revoke_usage`). Function signatures are unchanged and existing privileges are unaffected (#242).
- **`df.list_instances()` page-size cap is now a loud error (#146):** `df.list_instances()` previously truncated `limit_count` silently to a fixed ceiling of 10000. It now raises an error when `limit_count` exceeds the new `pg_durable.list_instances_max_limit` GUC (`SUSET` context, default `1000`, range `1`–`1000000`), so an over-cap request fails fast instead of returning a silently short page that is indistinguishable from "no more rows". Both the basic and paginated overloads enforce the cap; clients needing more rows should lower `limit_count` or use the paginated overload (`after_cursor`/`next_cursor`). A superuser can change the cap at runtime without a restart; by default an ordinary caller cannot.
- **Renamed `df.wait_for_completion()` (#164):** the function was renamed and hardened against unsafe use. **Breaking:** callers of the old name must update to the new name.
- **Node statuses derived from execution lineage (#263, #283):** node status is now derived from the durable engine's execution lineage, reconciling the `df` control-plane with the engine so reported statuses match actual execution.
- **`df.start()` fails fast on engine hand-off failure (#282):** if the hand-off to the durable engine fails, `df.start()` now returns an error immediately instead of leaving a stuck instance behind.
- **Dependencies:** bumped `reqwest` to 0.13.4 (#260) and `uuid` to 1.23.4 (#273).

### Fixed

- **`explain` race branches (#276):** race (`|`) branches now render correctly in `df.explain()` output.
- **Loop safety (#254):** `df.loop()` now enforces a max-iteration guard and detects malformed loop configuration instead of looping unboundedly or misbehaving.
- **`$name.*` expansion cap (#255):** a row-count limit (10,000) is now enforced when expanding `$name.*`, preventing unbounded expansion.
- **`df.http()` User-Agent (#270):** requests now send a default `User-Agent` header.
- **Connection reliability (#251, #252):** the client is now recoverable after a connection failure, and epoch/extension polling is isolated onto a dedicated connection pool so it can no longer contend with execution work.
- **`df.list_instances()` N+1 (#275):** instance-info lookups are now batched, removing an N+1 query pattern.
- **Indexes (#271):** added a `created_at` index and a composite status index on `df.instances` to speed up listing and status queries.

### Security

- **SSRF CGNAT range (#253):** the `100.64.0.0/10` CGNAT range is now blocked by SSRF protection in `df.http()`.
- **`df.metrics()` access (#184):** `df.metrics()` is now gated behind an explicit `EXECUTE` grant rather than being callable by default.

### Removed

- **`df.debug_connection()`:** removed from the SQL surface as non-security, surface-reduction cleanup (#110). The function returned the worker connection string (`postgres://role@host:port/db`) with no password or credential, and the worker role is already visible through native PostgreSQL channels (the world-readable `pg_durable.worker_role` GUC and `pg_stat_activity.usename`) — so issue #110 is reclassified from a security finding to cleanup. Fresh installs no longer create the function and the `0.2.3 → 0.2.4` upgrade drops it; a binary-compatibility shim retains the underlying C symbol so pre-0.2.4 schemas keep resolving the function until `ALTER EXTENSION pg_durable UPDATE` runs.

### Documentation

- Documented `SECURITY DEFINER df.start()` behavior (#185), corrected documentation examples (#257), and clarified that `df.status()`/`df.result()` take an `instance_id` rather than a label (#167).

## [0.2.3] - 2026-06-17

Provider-line note: v0.2.3 stays in the `duroxide-pg` provider compatibility line started in v0.2.2, so the upgrade source is v0.2.2 (`sql/pg_durable--0.2.2--0.2.3.sql`).

### Added

- **Debian release packages:** AMD64 `.deb` packages for PostgreSQL 17 and 18, built and validated by the Package Release workflow on tagged releases (#190, #203).
- **Public Docker images:** `ghcr.io/microsoft/pg_durable` images are published from the released `.deb` packages for PG 17 and 18. These images are for evaluating and learning pg_durable only - not for production (#218, #222, #223).

### Changed

- **duroxide provider schema:** fresh installs now use `_duroxide` as the duroxide-pg provider schema, while installations upgraded from earlier versions keep the legacy `duroxide` schema. The active schema is resolved at runtime via `df.duroxide_schema()`, so the change is transparent to existing deployments (#201).
- **Default worker role:** the background worker's default role is now `postgres` instead of `azuresu` (#206).
- **`df.break()` internals:** `df.break()` now carries its value as a typed `NodeError` instead of a JSON sentinel, with a compatibility fallback for envelopes written before #148 (#229).
- **JSON conversion:** internal SQL-to-JSON value conversion now goes through `try_from_json()` for more robust error handling (#235).
- **Dependencies:** bumped `reqwest` to 0.13 to match the lockfile (#237) and updated five crates in the cargo dependency group (#236). Added Dependabot for weekly cargo updates (#231).

### Fixed

- **Reliability audit:** fixed a set of correctness and safety bugs found during a reliability audit (#220):
  - `df.if()` / `df.loop()` conditions whose SQL returns zero rows now correctly evaluate as false instead of true (previously the empty result envelope was treated as truthy).
  - Graphs nested deeper than 256 levels are now rejected, preventing stack overflow from deeply nested operator chains.
  - Graphs with more than 10,000 nodes are now rejected, preventing unbounded INSERT storms and out-of-memory conditions.
  - Per-user SQL connections now have a 30-second connect timeout, so a stalled connection can no longer hold an execution slot indefinitely.
- **Non-finite floats:** SQL columns containing `NaN` or `Infinity` now map to JSON `null` instead of failing the workflow (#144).
- **Execution-history errors:** `df.instance_executions` now surfaces execution-history lookup failures instead of silently hiding them (#225, closes #168).

### Security

- **Docker/GHCR hardening:** hardened the published Docker image and the GHCR publish workflow, including least-privilege permissions and provenance/SBOM attestations on published images (#223).

### Documentation

- Clarified `df.http()` security scope versus SQL extension execution (#216).
- Corrected stale identity-model documentation and examples (#219, #224).
- Added the documentation website, refreshed the README, and standardized terminology to "durable functions" (#198, #204, #205, #207, #208, #211).
- Referenced the `pg_durable.database` GUC instead of the `PGDATABASE` environment variable (#200).

## [0.2.2] - 2026-05-28

First open-source release of `pg_durable` on GitHub under the PostgreSQL License.

### Open Source Release

- **License:** changed project licensing from MIT to PostgreSQL License (#187).
- **Repository:** moved to `github.com/microsoft/pg_durable` and updated crate metadata accordingly.
- **Community files:** added `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and `NOTICE` (direct third-party dependency inventory). `README.md` now includes Support, Code of Conduct, Security, Privacy & Telemetry (no telemetry), and Trademarks sections.
- **Source headers:** added PostgreSQL License headers to Microsoft-authored Rust, SQL, shell, Python, Makefile, Dockerfile, and config files; pre-existing notices preserved.
- **Sanitized internal references:** removed internal Azure Container Registry defaults from `Makefile`, `.env.example`, `scripts/deploy-acr.sh`, `docs/TESTING.md`, and release prompts; `ACR_REGISTRY` is now caller-provided.

### Breaking Changes

- **Provider compatibility boundary:** `pg_durable` now uses the crates.io `duroxide-pg` provider instead of the `duroxide-pg-opt` submodule. This is the first open-source release in the `duroxide-pg` provider line. Upgrade testing treats `v0.2.2` as the compatibility start for this line; Azure's fork owns upgrade compatibility for the earlier `duroxide-pg-opt` line (#158).
- **`df.join` / `df.join3` result shape:** join results are now a proper JSON array of objects instead of an array of double-encoded JSON strings. Consumers that previously unescaped each element, for example `(elem #>> '{}')::jsonb`, must now read the element directly (#143).

### Added

- **Typed SQL result decoding:** SQL node execution now preserves richer PostgreSQL column types in JSON results instead of treating all values as strings (#135).
- **Composite capture support:** `|=>` captures are now honored on composite THEN / IF / LOOP nodes (#163).

### Changed

- **Dependencies:** switched from `duroxide-pg-opt` to crates.io `duroxide-pg = 0.1.34` and bumped `duroxide` to `0.1.29` (#158).
- **Cancel status spelling:** status handling and documentation now consistently use `cancelled` (#145, #160).
- **Signal payloads:** `df.signal(text)` now accepts non-JSON text payloads as its SQL signature implies (#173).

### Fixed

- **JOIN/RACE branch state:** variables, labels, and named results now propagate correctly through JOIN/RACE subtrees (#137, #138).
- **Instance status transition:** instances are marked `running` before graph execution begins, so monitoring reflects active work promptly (#136).
- **Loop throttling:** `df.loop()` enforces a minimum iteration delay to avoid busy-spin behavior (#141).
- **Branch breaks:** `df.break()` is no longer silently ignored inside JOIN/RACE branches (#140).
- **Signals in sub-orchestrations:** `df.signal()` now propagates events to running sub-orchestrations spawned by `df.race`, `df.join`, and `df.join3`, so `df.wait_for_signal` inside a parallel branch wakes as expected. Known limitation: signals raised before the target sub-orchestration is in the `Running` state are not yet redelivered when it starts; a proper fix requires unmatched-event forwarding in duroxide (#154).
- **Quoted role names:** `df.start()`, RLS policies on `df.instances` / `df.nodes` / `df.vars`, and `df.vars` reads/writes no longer fail with `role "..." does not exist` when `current_user` requires quoting, such as mixed case, spaces, or embedded quotes. Schema upgrade DDL is in `sql/pg_durable--0.2.1--0.2.2.sql` (#161, #162).

### Security

- **Workflow composition hardening:** variable setup helpers are rejected inside workflow composition where they would mutate session state during graph construction (#153).
- **Dependency update:** bumped `openssl` from `0.10.78` to `0.10.80` (#176).

### Documentation

- Clarified that `df.break(value)` takes a literal value, not SQL (#157).
- Clarified text payload guidance for `df.signal(text)` (#174).

## v0.2.1 (Released)

- Dependency: upgrade duroxide `0.1.26→0.1.28` and duroxide-pg-opt `v0.1.23→v0.1.26`; adds cached-plan retryability, instance stats API, and error propagation fixes; switches TLS backend to `native-tls`, removing the `ring` crate entirely (#116)
- Dependency: `cargo update` to refresh transitive dependencies (#116)
- Security: harden `df.explain()` to reject non-DSL input before SPI evaluation (#112)
- Security: harden SPI queries against search_path poisoning (#114)
- Security: add annotations for raw variable substitution (#111)
- Fix: improvements and fixes to `df.grant_usage()` / `df.revoke_usage()` helpers (#109)
- Fix: enable `superuser_instances` GUC in Docker CI (#117)
- New: Azure HTTP domains validation example (#115)

## v0.2.0 (Released)

- Tag: [v0.2.0](https://github.com/microsoft/pg_durable/releases/tag/v0.2.0)
- Commit: `f5607fb`
- Breaking change: `df.vars` now uses per-user scoping via RLS. After upgrading from `v0.1.1`, all pre-existing variables are re-homed to the role that ran `ALTER EXTENSION pg_durable UPDATE`; other users will lose access to any variables they had set before the upgrade.
- Security: harden SQL execution against injection (#51)
- Fix: `is_truthy` now correctly treats "false", "no", and "f" as falsy (#57)
- Docs: add "Debugging Failed Workflows" section to User Guide (#71)
- New: Azure Functions integration example (#69)
- Named result substitution now supports dot-notation for column access (`$name.col`), null-safe variants (`$name?`, `$name.col?`), and row-set expansion (`$name.*`). Referencing a named result that returned no rows or a NULL value now fails the orchestration by default; append `?` to substitute `NULL` instead.
- New DSL function `df.if_rows()`: branches on whether a named result returned any rows, without executing a SQL condition query.
- New: Connection limits — four Postmaster-context GUCs (`max_management_connections`, `max_duroxide_connections`, `max_user_connections`, `execution_acquire_timeout`) control the background worker's connection budget. User-execution connections are gated by a semaphore with configurable backpressure timeout. The former polling and activity pools are consolidated into a single management pool. Backend provider pools reduced to 1 connection.
- Breaking change: simplified user isolation by dropping `login_role` from `df.instances` and `df.nodes`. User isolation now captures only `current_user` as `submitted_by`, and the background worker connects directly as `submitted_by` instead of connecting as `login_role` and running `SET ROLE`. `df.start()` now validates that `current_user` has the `LOGIN` attribute. The new binary remains compatible with the v0.1.1 schema shape, but any pending or running v0.1.1 instance whose `submitted_by` is a NOLOGIN role from the old `SET ROLE` workflow will fail after upgrade and must be recreated under the new model.
- Breaking change: fresh installs no longer grant `PUBLIC` access to the `df` schema. An administrator must explicitly grant privileges to each role that needs to use pg_durable (e.g., `GRANT USAGE ON SCHEMA df TO my_role; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO my_role;`). Existing v0.1.1 installations are not modified by the upgrade — their current permissions remain intact.

## v0.1.1 (Released)

- Tag: [v0.1.1](https://github.com/microsoft/pg_durable/releases/tag/v0.1.1)
- Commit: `b83dc78828b4f5a4d6fb03a6b97cc46fff834df9`