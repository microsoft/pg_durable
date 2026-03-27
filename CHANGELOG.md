# Changelog

Pre-1.0 note: while `pg_durable` is in major version `0`, minor releases may include breaking changes.

## v0.2.0 (in development)

- Breaking change: `df.vars` now uses per-user scoping via RLS. After upgrading from `v0.1.1`, all pre-existing variables are re-homed to the role that ran `ALTER EXTENSION pg_durable UPDATE`; other users will lose access to any variables they had set before the upgrade.
- Security: harden SQL execution against injection (#51)
- Fix: `is_truthy` now correctly treats "false", "no", and "f" as falsy (#57)
- Docs: add "Debugging Failed Workflows" section to User Guide (#71)
- New: Azure Functions integration example (#69)
- Named result substitution now supports dot-notation for column access (`$name.col`), null-safe variants (`$name?`, `$name.col?`), and row-set expansion (`$name.*`). Referencing a named result that returned no rows or a NULL value now fails the orchestration by default; append `?` to substitute an empty string instead.
- New DSL function `df.if_rows()`: branches on whether a named result returned any rows, without executing a SQL condition query.
- New: Connection limits — four Postmaster-context GUCs (`max_management_connections`, `max_duroxide_connections`, `max_user_connections`, `execution_acquire_timeout`) control the background worker's connection budget. User-execution connections are gated by a semaphore with configurable backpressure timeout. The former polling and activity pools are consolidated into a single management pool. Backend provider pools reduced to 1 connection.

## v0.1.1 (Released)

- Tag: [v0.1.1](https://github.com/microsoft/pg_durable/releases/tag/v0.1.1)
- Commit: `b83dc78828b4f5a4d6fb03a6b97cc46fff834df9`