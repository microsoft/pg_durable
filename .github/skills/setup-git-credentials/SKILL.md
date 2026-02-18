---
name: setup-git-credentials
description: Set up and verify HTTPS GitHub credential access for microsoft/duroxide-pg-opt using ~/.git-credentials and credential.helper=store. Use this when git ls-remote or cargo git fetch fails with 401/403 for the private dependency.
---

Use this skill when a user needs to configure GitHub access to `microsoft/duroxide-pg-opt` with HTTPS credentials in `~/.git-credentials`, or when credential-helper precedence is causing auth failures.

## Goal

Ensure Git uses `~/.git-credentials` for `github.com` and verify access with:

- `git credential fill` (effective credential)
- `git ls-remote https://github.com/microsoft/duroxide-pg-opt` (real access)

## Inputs to collect

- GitHub username (for credential URL)
- GitHub PAT with repository read access to `microsoft/duroxide-pg-opt`

If the token is unavailable, stop and ask the user to provide it securely.

## Procedure

1. Write `~/.git-credentials` with mode `600`:

   ```bash
   umask 077
   printf 'https://<username>:<token>@github.com\n' > ~/.git-credentials
   chmod 600 ~/.git-credentials
   ```

2. Configure helper precedence so `store` wins even when system helpers exist (for example Codespaces helpers):

   ```bash
   git config --global --unset-all credential.helper || true
   git config --global --add credential.helper ''
   git config --global --add credential.helper store
   ```

3. Verify helper chain and effective credential (redact password in output):

   ```bash
   git config --show-origin --get-all credential.helper
   printf 'protocol=https\nhost=github.com\n\n' | git credential fill \
     | sed -E 's/(password=).+$/\1***REDACTED***/'
   ```

   Expected: `username=<provided-username>`.

4. Verify remote access:

   ```bash
   git ls-remote https://github.com/microsoft/duroxide-pg-opt | head -n 5
   ```

   Expected: refs are returned.

## Troubleshooting

- If `username=PersonalAccessToken` appears in `git credential fill`, a higher-priority helper is still active. Re-apply step 2.
- If `ls-remote` returns 403, verify token scope/permissions and organization SSO authorization for the token.
- If `ls-remote` returns 401, token is invalid/expired or malformed in `~/.git-credentials`.
- If `~/.git-credentials` has multiple `github.com` lines, keep only the intended one.

## Optional automation

Use the included script:

```bash
.github/skills/setup-git-credentials/setup_and_test.sh <github-username> <github-token>
```

The script configures credentials, enforces helper precedence, and runs verification checks.

## Safety rules

- Never print raw PATs in logs or responses.
- Redact tokens from all command output.
- Do not commit credentials or write them into repository files.