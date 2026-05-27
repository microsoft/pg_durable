# Changelog

Pre-1.0 note: while `pg_durable` is in major version `0`, minor releases may include breaking changes.

## Unreleased

- Fix: `df.signal()` now propagates the event to running sub-orchestrations spawned by `df.race` / `df.join` / `df.join3`, so `df.wait_for_signal` inside a parallel branch wakes as expected. Known limitation: signals raised before the target sub-orchestration is in the `Running` state are not yet redelivered when it starts; a proper fix requires unmatched-event forwarding in duroxide (#154).
- Fix: `df.start()`, RLS policies on `df.instances` / `df.nodes` / `df.vars`, and `df.vars` reads/writes no longer fail with `role "..." does not exist` when `current_user` requires quoting (mixed case, spaces, embedded quotes). All `current_user::regrole` casts are now wrapped with `quote_ident()` so the role lookup preserves the original identifier casing (#161, #162). Schema upgrade DDL is in `sql/pg_durable--0.2.1--0.2.2.sql`.

- Behavior change (bug fix): `df.join` / `df.join3` results are now a proper JSON array of objects instead of an array of double-encoded JSON strings. Consumers that previously unescaped each element (e.g. `(elem #>> '{}')::jsonb`) must now read the element directly (#143)

- Monitoring: add `idx_instances_created_at_desc_id` on `df.instances(created_at DESC, id)` to support efficient chronological listing; extend `df.list_instances` to return `created_at` and `completed_at`; add `df.list_instances_paginated(status_filter, limit_count, after_cursor)` with keyset cursor pagination and `total_count` / `next_cursor`.

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