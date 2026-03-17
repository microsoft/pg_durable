# Setup Scripts

This directory contains helper scripts to provision and deploy the Azure Function and configure pg_durable variables.

## Included scripts

- `create_function_app.sh`
- `deploy_function.sh`
- `configure_pg.sh`
- `cleanup_azure.sh`
- `smoke_check.sh`

## Script responsibilities

### create_function_app.sh

- Validate required tools (`az`, optionally `func`)
- Create resource group (or use existing)
- Create storage account and function app
- Generate names automatically from `pgd_ex_af_<5 random hex>`
- Allow changing only location (`-l`, default `eastus`)
- Derive function app and storage account names with Azure-safe sanitization
- Output app name and default URL
- Write app metadata to `.azure-functions.env`

### deploy_function.sh

- Package/deploy Python function code
- Sync function definitions
- Read app/resource-group from `.azure-functions.env` (required)
- Use function name from `.azure-functions.env` when present, else `chunk_text`
- Return function endpoint and function key retrieval instructions
- Write function endpoint and key to `.azure-functions.env`

### configure_pg.sh

- Read endpoint + function key from `.azure-functions.env` by default
- Allow endpoint + key overrides via `-u` / `-k`
- Run SQL that sets pg_durable variables for current session/demo
- Optionally print verification queries

### cleanup_azure.sh

- Read resource group from `.azure-functions.env` by default
- Allow resource group override via `-g`
- Delete the resource group and all contained resources
- Prompt for confirmation unless `-y` is supplied

### smoke_check.sh

- Run fast, non-cloud validation for this example
- Check shell syntax for all scripts in this directory
- Check Python syntax for the function code
- Validate JSON files used by Azure Functions host/runtime

## Usage notes

- Keep scripts non-interactive where possible (flags/env vars)
- Fail fast with clear error messages
- Avoid writing secrets to tracked files
- Print copy/paste-safe outputs for SQL setup
- Use `./scripts/smoke_check.sh` locally before opening a PR
