# GitHub Codespaces Pre-builds Configuration

This document explains how Codespaces pre-builds are configured for the pg_durable repository and how to maintain them.

## Overview

GitHub Codespaces pre-builds reduce startup time by pre-building the development environment. Without a prebuild, first-time setup is noticeably slower because PostgreSQL, pgrx, and the extension toolchain all need to be prepared. With a healthy prebuild, opening a new Codespace is much faster because the expensive setup has already been done.

## Enabling Pre-builds (One-Time Setup)

Pre-builds must be enabled by a repository administrator:

1. Go to repository **Settings** → **Codespaces**
2. Click **Set up prebuild**
3. Configure the prebuild:
   - **Configuration**: Select `.devcontainer/devcontainer.json`
   - **Region**: Select your preferred region(s)
   - **Trigger**: Choose "Automatically" for changes to main branch
   - **Reduce prebuild available to specific regions**: Optional
4. Click **Create**

### Provider Dependencies

`duroxide` and `duroxide-pg` are crates.io dependencies. No provider checkout, provider PAT, or extra Codespaces repository permission is required.

## How It Works

### Build Phases

Codespaces has two distinct phases:

1. **Pre-build Phase** (runs in GitHub Actions, cached for all users)
   - Triggered by: `.github/workflows/prebuild.yml`
   - Executes: `onCreateCommand` in `devcontainer.json`
  - Duration: depends on cache state and network conditions; it is the slow phase and runs only when the prebuild needs to be refreshed
   - Installs:
     - System dependencies (libssl, clang, bison, etc.)
     - cargo-pgrx 0.16.1
     - PostgreSQL 17 (downloaded and compiled via pgrx)
   - Rust dependencies from crates.io
    - Builds and installs pg_durable
    - Recreates the local `~/.pgrx/data-17` cluster with `initdb -U postgres`
    - Pre-creates the `pg_durable` extension and verifies it
  - Result: a prebuilt environment with dependencies, build artifacts, and a ready-to-start local PostgreSQL cluster

2. **Post-Create Phase** — no `postCreateCommand` is configured. When the Codespace opens the prebuild environment is ready; run `./scripts/pg-start.sh` to start PostgreSQL and begin working.

### Configuration Files

```
.devcontainer/
├── devcontainer.json          # Main configuration with onCreateCommand
└── onCreateCommand.sh         # Heavy setup (runs during prebuild)

.github/workflows/
└── prebuild.yml               # Validates devcontainer configuration
```

**Note**: The workflow doesn't trigger prebuilds directly. GitHub automatically triggers prebuilds when enabled in repository settings.

## Triggering Pre-builds

Once prebuilds are enabled in Settings, they are automatically triggered when:

- Changes are pushed to the `main` branch
- The devcontainer configuration is updated
- Dependencies change (Cargo.toml, Cargo.lock)

You can manually trigger a prebuild:
1. Go to repository **Settings** → **Codespaces**
2. Find your prebuild configuration
3. Click the **"..."** menu → **"Trigger prebuild"**

## Monitoring Pre-builds

### In Codespaces Settings

1. Go to repository **Settings** → **Codespaces** → **Prebuild configuration**
2. View prebuild status for each configuration
3. See which branches have active prebuilds
4. Check prebuild success/failure history
5. View logs for failed prebuilds

The prebuild logs will show the execution of `onCreateCommand.sh` and any errors that occurred.

## Updating Dependencies

When you need to update system dependencies or pgrx version:

1. **Update `onCreateCommand.sh`** with the new dependencies
2. **Commit and push to main** (or create a PR)
3. **Wait for the prebuild to complete**
4. **Test in a new Codespace** to verify the changes work

Example: Updating pgrx version
```bash
# In .devcontainer/onCreateCommand.sh
cargo install cargo-pgrx --version 0.16.1 --locked  # Updated from 0.15.0
```

## Troubleshooting

### Pre-build Failed

1. Check the prebuild logs in **Settings** → **Codespaces** → **Prebuild configuration**
2. Common issues:
   - System dependency installation failures (apt-get)
   - Network timeouts during PostgreSQL download
   - Cargo compilation errors
3. Fix the issue in the relevant script and push
4. The prebuild will automatically retry on next push or trigger manually

### Codespace Still Takes 10 Minutes to Start

Possible causes:
- Prebuilds not enabled yet (check Settings → Codespaces)
- Prebuild hasn't completed yet (check prebuild status)
- Prebuild is for a different branch than you're using
- Recent changes weren't included in the last prebuild
- Cache was invalidated (check if base image changed)

**Solution**: Enable prebuilds if not done, wait for completion, or manually trigger

### User Gets "cargo-pgrx not found" Error

This means the prebuild did not run or failed. There is no automatic fallback — open a terminal and run `./scripts/pg-start.sh` to trigger a full build and install.

**Solution**: Investigate why the prebuild isn't working and fix it for future users

### User Can See `GH_PAT` In Their Codespace Environment

No longer applicable — provider dependencies come from crates.io and `GH_PAT` is not used by the prebuild. If you see a `GH_PAT` secret configured at the repo level, you can safely remove it.

## Cost Considerations

Pre-builds use GitHub Actions compute time. However:
- They save users from repeating the expensive environment setup on every fresh Codespace
- Break-even after 1-2 Codespace opens
- Well worth it for active repositories
- Storage costs apply for prebuild images (typically negligible)

To manage costs:
- Configure prebuilds only for active branches (typically just `main`)
- Set appropriate retention policies in prebuild settings
- Monitor usage in Settings → Codespaces

## Best Practices

1. **Keep `onCreateCommand.sh` deterministic** - Don't use dynamic versions
2. **Test changes locally first** - Use Dev Containers in VS Code
3. **Monitor prebuild success rate** - Set up notifications for failures
4. **Update documentation** - Keep this doc in sync with changes
5. **Pin dependency versions** - Avoid surprises from version changes

## Architecture Decision Records

### Why only onCreateCommand and no postCreateCommand?

- `onCreateCommand` runs during prebuild and does all the heavy setup once.
- When the Codespace opens the environment is already ready; there is nothing useful a `postCreateCommand` can do that the user cannot trigger themselves with `./scripts/pg-start.sh`.
- Omitting `postCreateCommand` avoids running a script whose output is not visible to most users.

### Why use scripts instead of inline commands?

- Better maintainability and readability
- Easier to test locally
- Can share logic between scripts
- Better error handling with `set -e`

## Related Resources

- [GitHub Docs: Configuring Prebuilds](https://docs.github.com/en/codespaces/prebuilding-your-codespaces/configuring-prebuilds)
- [GitHub Docs: Managing Prebuilds](https://docs.github.com/en/codespaces/prebuilding-your-codespaces/managing-prebuilds)
- [Dev Containers Specification](https://containers.dev/implementors/json_reference/)

## Testing Locally

You can test the devcontainer configuration locally using VS Code:

1. Install the **Dev Containers** extension in VS Code
2. Open the repository in VS Code
3. Press `F1` and select "Dev Containers: Rebuild Container"
4. This simulates the Codespace environment locally

Note: Local testing doesn't simulate the prebuild workflow exactly, but it validates the scripts work.
