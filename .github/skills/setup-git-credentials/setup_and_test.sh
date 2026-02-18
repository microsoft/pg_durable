#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <github-username> <github-token> [repo-url]" >&2
  echo "Default repo-url: https://github.com/microsoft/duroxide-pg-opt" >&2
  exit 1
fi

github_username="$1"
github_token="$2"
repo_url="${3:-https://github.com/microsoft/duroxide-pg-opt}"
credentials_file="${HOME}/.git-credentials"

if [[ -z "$github_username" || -z "$github_token" ]]; then
  echo "Username and token must be non-empty." >&2
  exit 1
fi

echo "Writing ${credentials_file} with restricted permissions..."
umask 077
printf 'https://%s:%s@github.com\n' "$github_username" "$github_token" > "$credentials_file"
chmod 600 "$credentials_file"

echo "Configuring git credential helper precedence (global): clear inherited helpers, then use store..."
git config --global --unset-all credential.helper || true
git config --global --add credential.helper ''
git config --global --add credential.helper store

echo ""
echo "Credential helpers in effect:"
git config --show-origin --get-all credential.helper

echo ""
echo "Resolved credential for github.com (password redacted):"
printf 'protocol=https\nhost=github.com\n\n' | git credential fill \
  | sed -E 's/(password=).+$/\1***REDACTED***/'

echo ""
echo "Testing remote access: ${repo_url}"
git ls-remote "$repo_url" | head -n 5

echo ""
echo "Success: credential helper is configured and remote is accessible."
