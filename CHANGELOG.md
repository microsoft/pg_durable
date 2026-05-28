# Changelog

Pre-1.0 note: while `pg_durable` is in major version `0`, minor releases may include breaking changes.

## [0.2.2] - 2026-05-28

### Breaking Changes

- **Provider compatibility boundary:** `pg_durable` now uses the crates.io `duroxide-pg` provider instead of the `duroxide-pg-opt` submodule. This is the first open-source release in the `duroxide-pg` provider line. Upgrade testing treats `v0.2.2` as the compatibility start for this line; Azure's fork owns upgrade compatibility for the earlier `duroxide-pg-opt` line (#158).
- **`df.join` / `df.join3` result shape:** join results are now a proper JSON array of objects instead of an array of double-encoded JSON strings. Consumers that previously unescaped each element, for example `(elem #>> '{}')::jsonb`, must now read the element directly (#143).

### Added

- **Typed SQL result decoding:** SQL node execution now preserves richer PostgreSQL column types in JSON results instead of treating all values as strings (#135).
- **Composite capture support:** `|=>` captures are now honored on composite THEN / IF / LOOP nodes (#163).

### Changed

- **Dependencies:** switched from `duroxide-pg-opt` to crates.io `duroxide-pg = 0.1.34` and bumped `duroxide` to `0.1.29` (#158).
- **License:** changed project licensing from MIT to PostgreSQL License (#187).
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
- Named result substitution now supports dot-notation for column access (`$name.col`), null-safe variants (`$name?`, `$name.col?`), and row-set expansion (`$name.*`). Referencing a named result that returned no rows or a NULL value now fails the orchestration by default; append `?` to substitute an empty string instead.
- New DSL function `df.if_rows()`: branches on whether a named result returned any rows, without executing a SQL condition query.
- New: Connection limits — four Postmaster-context GUCs (`max_management_connections`, `max_duroxide_connections`, `max_user_connections`, `execution_acquire_timeout`) control the background worker's connection budget. User-execution connections are gated by a semaphore with configurable backpressure timeout. The former polling and activity pools are consolidated into a single management pool. Backend provider pools reduced to 1 connection.
- Breaking change: simplified user isolation by dropping `login_role` from `df.instances` and `df.nodes`. User isolation now captures only `current_user` as `submitted_by`, and the background worker connects directly as `submitted_by` instead of connecting as `login_role` and running `SET ROLE`. `df.start()` now validates that `current_user` has the `LOGIN` attribute. The new binary remains compatible with the v0.1.1 schema shape, but any pending or running v0.1.1 instance whose `submitted_by` is a NOLOGIN role from the old `SET ROLE` workflow will fail after upgrade and must be recreated under the new model.
- Breaking change: fresh installs no longer grant `PUBLIC` access to the `df` schema. An administrator must explicitly grant privileges to each role that needs to use pg_durable (e.g., `GRANT USAGE ON SCHEMA df TO my_role; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO my_role;`). Existing v0.1.1 installations are not modified by the upgrade — their current permissions remain intact.

## v0.1.1 (Released)

- Tag: [v0.1.1](https://github.com/microsoft/pg_durable/releases/tag/v0.1.1)
- Commit: `b83dc78828b4f5a4d6fb03a6b97cc46fff834df9`