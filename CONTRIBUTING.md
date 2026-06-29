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
cargo check --features pg17
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
cargo build --features pg17
cargo clippy --features pg17
./scripts/test-unit.sh
./scripts/test-e2e-local.sh
```

For extension schema changes, also run the upgrade tests:

```bash
./scripts/test-upgrade.sh
```
