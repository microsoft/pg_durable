# GitHub Codespaces Pre-builds Configuration

This document explains how Codespaces pre-builds are configured for the pg_durable repository and how to maintain them.

## Overview

GitHub Codespaces pre-builds dramatically reduce startup time by pre-building the development environment. Without pre-builds, starting a new Codespace takes ~10 minutes due to PostgreSQL compilation. With pre-builds, startup time is reduced to ~30 seconds.

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

### Private Submodule Access

The `duroxide-pg-opt` submodule is a **private repository**. Two mechanisms provide access:

**1. Interactive Codespaces** — `devcontainer.json` grants the built-in Codespace token read access:

```json
"codespaces": {
  "repositories": {
    "microsoft/duroxide-pg-opt": {
      "permissions": { "contents": "read" }
    }
  }
}
```

This works when users open a Codespace directly.

**2. Prebuild phase** — The Codespace token permissions are **not effective during prebuilds**. A GitHub PAT stored as a Codespace secret is required:

1. Create a **fine-grained PAT** with **read-only** access to `microsoft/duroxide-pg-opt` (Contents: Read)
2. Go to repository **Settings** → **Secrets and variables** → **Codespaces**
3. Click **New repository secret**
4. Name: `GH_PAT`, Value: the PAT from step 1
5. Click **Add secret**

**Security notes:**
- `onCreateCommand.sh` uses a temporary `git config insteadOf` rewrite with the PAT, then **immediately scrubs** all traces (git config, credential cache) before the prebuild image is snapshotted.
- The prebuild image is a **filesystem snapshot** — environment variables from secrets are NOT persisted.
- Users who open a Codespace from the prebuild get the submodule files already present, without needing any PAT themselves.
- Use a fine-grained PAT scoped to only `duroxide-pg-opt` with read-only access to minimize exposure.

## How It Works

### Build Phases

Codespaces has two distinct phases:

1. **Pre-build Phase** (runs in GitHub Actions, cached for all users)
   - Triggered by: `.github/workflows/prebuild.yml`
   - Executes: `onCreateCommand` in `devcontainer.json`
   - Duration: ~15 minutes (but only runs once per configuration change)
   - Installs:
     - System dependencies (libssl, clang, bison, etc.)
     - cargo-pgrx 0.16.1
     - PostgreSQL 17 (downloaded and compiled via pgrx)
     - `duroxide-pg-opt` submodule (via `GH_PAT` Codespace secret)
     - Pre-builds pg_durable (`cargo build --features pg17`)
   - Result: Docker image with all dependencies and build artifacts baked in

2. **Post-Create Phase** (runs when user opens a Codespace)
   - Executes: `postCreateCommand` in `devcontainer.json`
   - Duration: ~5-10 seconds
   - Verifies dependencies are present
   - Falls back to full installation if prebuild wasn't available

### Configuration Files

```
.devcontainer/
├── devcontainer.json          # Main configuration with onCreateCommand
├── onCreateCommand.sh         # Heavy setup (runs during prebuild)
└── postCreateCommand.sh       # Quick verification (runs on open)

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
3. **Wait for prebuild to complete** (~10-15 minutes)
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

This means the prebuild didn't run or failed. The `postCreateCommand.sh` has a fallback:
- It detects missing dependencies
- Automatically runs the full installation
- Takes ~10 minutes but ensures the environment works

**Solution**: Investigate why the prebuild isn't working and fix it for future users

## Cost Considerations

Pre-builds use GitHub Actions compute time (~10 minutes per prebuild). However:
- They save ~10 minutes per user per Codespace start
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

### Why separate onCreateCommand and postCreateCommand?

- `onCreateCommand` runs during prebuild (slow operations)
- `postCreateCommand` runs on every Codespace open (fast verification)
- This separation maximizes the benefit of pre-builds while providing fallback

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
