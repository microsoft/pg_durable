# Contributing

This project welcomes contributions and suggestions. Most contributions require you to
agree to a Contributor License Agreement (CLA) declaring that you have the right to,
and actually do, grant us the rights to use your contribution. For details, visit
https://cla.microsoft.com.

When you submit a pull request, a CLA-bot will automatically determine whether you need
to provide a CLA and decorate the PR appropriately (e.g., label, comment). Simply follow the
instructions provided by the bot. You will only need to do this once across all repositories using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/)
or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Reporting security issues

Please do not report security vulnerabilities through public GitHub issues. Follow the instructions in [SECURITY.md](SECURITY.md).

## Development workflow

### Targeted local checks

For small changes, you do not need to run the entire E2E suite before opening a PR.
Run the narrowest check that covers your change and include the command in the PR description.

In a Codespace or VS Code Dev Container, Rust, pgrx, and PostgreSQL 17 are already installed. For most Rust changes, a useful minimal check is:

```bash
cargo fmt -p pg_durable -- --check
cargo check --locked --features pg17
```

For an E2E scenario, run the matching SQL test by filename prefix or name:

```bash
./scripts/test-e2e-local.sh --verbose 05_monitoring_and_explain
```

The local E2E script starts and stops PostgreSQL automatically. Use `--keep` if you want to inspect the database or logs after a failure:

```bash
./scripts/test-e2e-local.sh --keep --verbose 05_monitoring_and_explain
tail -f ~/.pgrx/17.log
```

If you cannot run the targeted check locally, say so in the PR and CI will still run the full suite.

### Full pre-PR checks

Before opening a pull request, run the checks relevant to your change:

```bash
cargo fmt -p pg_durable -- --check
cargo build --locked --features pg17
cargo clippy --locked --features pg17
./scripts/test-unit.sh
./scripts/test-e2e-local.sh
```

For extension schema changes, also run the upgrade tests:

```bash
./scripts/test-upgrade.sh
```

### Replay compatibility

The background worker replays durable histories created by **previous** binaries. A change can keep every new instance correct — passing unit and E2E tests — while making an in-flight instance started under the previous binary fail to replay. Fresh-execution tests cannot catch this; the real previous-binary lifecycle in `./scripts/test-upgrade.sh` can. See [docs/upgrade-testing.md](docs/upgrade-testing.md) for the full strategy.

Run `./scripts/test-upgrade.sh` (it includes the N-1 lifecycle) when your change touches any of the following, because each is replay-visible:

- orchestration code in `src/orchestrations/`, or any helper it transitively calls;
- an activity or orchestration `NAME` constant;
- how a scheduled activity or sub-orchestration **input** is constructed (including adding, removing, renaming, or reordering a serialized field — the recorded bytes must match, even when deserialization stays backward compatible);
- the `continue_as_new` input;
- timers, signals, durable-clock (`ctx.utc_now()`) calls, branching, the order durable operations are scheduled, or an orchestration's returned output;
- any serialized graph, orchestration, or activity envelope.

`ctx.utc_now()` is deterministic, but **adding, removing, or reordering** a durable call like it changes the recorded operation sequence and breaks replay of older histories.

When a replay-visible change is genuinely required, prefer durable versioning: record a version in the new orchestration input, default old inputs to the old behavior, and keep old operation names and input shapes while their histories are still supported. Do not branch on current process or schema state during replay. If versioning is infeasible, document a drain/cancel-before-upgrade contract in [docs/upgrade-testing.md](docs/upgrade-testing.md) and [CHANGELOG.md](CHANGELOG.md) rather than silently shipping an incompatibility.

If you add a new DSL behavior family or a new durable suspension pattern that the existing lifecycle families do not represent, extend [tests/upgrade/lifecycle.sql](tests/upgrade/lifecycle.sql) and [scripts/upgrade_lifecycle.py](scripts/upgrade_lifecycle.py) so real N-1 histories cover it.

### Dependency updates

Keep `Cargo.toml` and `Cargo.lock` consistent. After editing a requirement, regenerate the lockfile with Cargo and check it with `--locked`. A newer version that already fits the requirement may change only the lockfile. Do not let a routine build rewrite the committed graph.

[Dependabot](.github/dependabot.yml) updates ordinary Cargo requirements automatically. These dependencies are excluded from version-update and security-update pull requests, so watch them manually. Alerts still open.

- Upgrade `pgrx` and `pgrx-tests` together, including `cargo-pgrx`.
- Upgrade `duroxide` and `duroxide-pg` as a compatible pair.

Review pre-1.0 minor upgrades as potentially breaking. CI checks the lockfile with `cargo metadata --locked` and fails if packaging or tests change `Cargo.lock`.
