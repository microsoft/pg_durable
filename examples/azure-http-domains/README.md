# Azure HTTP Domain Tests for pg_durable

Systematically test `df.http()` against every Azure domain suffix in the
`http-allow-azure-domains` allowlist.  Each test provisions a real Azure
resource, sends a request through pg_durable's background worker, and
verifies a successful HTTP response.

## Domain Coverage

The `http-allow-azure-domains` feature allows 20 domain suffixes.  This
test suite covers them as follows:

| Status | Service | Domain Suffix | Test |
|--------|---------|--------------|------|
| ✅ Impl | Blob Storage | `.blob.core.windows.net` | GET a pre-uploaded blob |
| ✅ Impl | Blob Storage (alt) | `.blob.storage.azure.net` | GET via alternate endpoint |
| ✅ Impl | Queue Storage | `.queue.core.windows.net` | Peek messages from queue |
| ✅ Impl | Table Storage | `.table.core.windows.net` | POST an entity |
| ✅ Impl | File Storage | `.file.core.windows.net` | List share root |
| ✅ Impl | Function App | `.azurewebsites.net` | GET root page (200 OK) |
| ✅ Impl | Key Vault | `.vault.azure.net` | GET a secret |
| ✅ Impl | Service Bus | `.servicebus.windows.net` | Send a message |
| ✅ Impl | Cognitive Services | `.cognitiveservices.azure.com` | Detect language |
| ✅ Impl | Cosmos DB | `.documents.azure.com` | List databases |
| 🔲 Stub | OpenAI | `.openai.azure.com` | Needs model deployment + quota |
| 🔲 Stub | API Management | `.azure-api.net` | 30–60 min provision time |
| 🔲 Stub | Data Explorer | `.kusto.windows.net` | Expensive resource |
| 🔲 Stub | Front Door | `.azurefd.net` | Needs backend configuration |
| 🔲 Stub | CDN | `.azureedge.net` | Needs origin + propagation |
| 🔲 Stub | IoT Hub | `.azure-devices.net` | Specialized device service |
| 🔲 Stub | Traffic Manager | `.trafficmanager.net` | Needs backend endpoints |
| 🔲 Stub | Cloud App | `.cloudapp.azure.com` | Needs VM or container |
| ⬜ N/A | Redis Cache | `.redis.cache.windows.net` | Not HTTP (RESP protocol) |
| ⬜ N/A | SQL Database | `.database.windows.net` | Not HTTP (TDS protocol) |

## Prerequisites

1. **Azure CLI** (`az`) installed and logged in: `az login`
2. **pg_durable** built with `http-allow-azure-domains` or `http-allow-test-domains`
3. **PostgreSQL server** running with pg_durable loaded
4. **psql** available (system or pgrx path)

The extension must be built with HTTP support.  Both `http-allow-azure-domains`
and `http-allow-test-domains` (which implies it) work.  The standard
`./scripts/test-e2e-local.sh` flow uses `http-allow-test-domains`.

## Usage

### 1. Provision Azure resources

```bash
cd examples/azure-http-domains

# Provision all implemented services (~15 min, one shared resource group)
./scripts/provision.sh

# Or provision a single service
./scripts/provision.sh storage-account
./scripts/provision.sh key-vault
```

### 2. Run tests

```bash
# Run all tests (assumes pg_durable server is running)
./scripts/run-test.sh

# Run a single service test
./scripts/run-test.sh storage-account
./scripts/run-test.sh key-vault

# Custom PostgreSQL connection
./scripts/run-test.sh -h localhost -p 28817 -d postgres -U postgres storage-account
```

### 3. Cleanup

```bash
# Delete the resource group and all resources
./scripts/cleanup.sh -y

# Or without -y to get a confirmation prompt
./scripts/cleanup.sh
```

## Directory Structure

```
examples/azure-http-domains/
├── README.md                           # This file
├── .gitignore                          # Ignore .env files
├── scripts/
│   ├── common.sh                       # Shared helpers (env file, naming, psql)
│   ├── provision.sh                    # Provision one or all services
│   ├── run-test.sh                     # Run SQL tests via psql
│   ├── cleanup.sh                      # Delete resource group
│   └── smoke_check.sh                  # Offline syntax validation
└── services/
    ├── storage-account/                # .blob/.queue/.table/.file.core.windows.net
    │   ├── provision.sh
    │   └── test.sql
    ├── key-vault/                      # .vault.azure.net
    │   ├── provision.sh
    │   └── test.sql
    ├── function-app/                   # .azurewebsites.net
    │   ├── provision.sh
    │   └── test.sql
    ├── service-bus/                    # .servicebus.windows.net
    │   ├── provision.sh
    │   └── test.sql
    ├── cognitive-services/             # .cognitiveservices.azure.com
    │   ├── provision.sh
    │   └── test.sql
    └── cosmos-db/                      # .documents.azure.com
        ├── provision.sh
        └── test.sql
```

## How Each Test Works

1. **Provision** creates the Azure resource and writes endpoints + credentials
   to `.azure-http-domains.env`.
2. **run-test.sh** reads the env file, fetches fresh Azure AD tokens where
   needed, exports everything as environment variables, and runs each
   service's `test.sql` via `psql`.
3. Each **test.sql** uses `\getenv` to load variables, calls `df.setvar()`,
   then `df.start()` with `df.http()` targeting the service endpoint.
4. The test polls `df.wait_for_completion()` and asserts the HTTP response.
5. **cleanup.sh** deletes the entire resource group.

## Estimated Cost

With prompt cleanup, total cost is negligible:

| Service | Approx. Cost | Notes |
|---------|-------------|-------|
| Storage Account | ~$0 | Minimal operations |
| Key Vault | ~$0 | Free tier operations |
| Function App | ~$0 | Consumption plan free tier |
| Service Bus | ~$0.05 | Basic tier |
| Cognitive Services | ~$0 | Free tier (5K calls/month) |
| Cosmos DB | ~$0.80/hr | Serverless, delete promptly |

**Always run `./scripts/cleanup.sh` after testing.**

## Adding a New Service

1. Create `services/<name>/provision.sh` — provision the resource, write
   endpoints and credentials to the env file using `upsert_env_var`.
2. Create `services/<name>/test.sql` — use `\getenv` to load values,
   `df.setvar()` to set them, `df.http()` to test, assert the response.
3. Add the service name to `IMPLEMENTED_SERVICES` in `scripts/common.sh`.
4. Update the coverage table in this README.

## Relationship to E2E Tests

The existing E2E tests in `tests/e2e/sql/06_http_and_ssrf.sql` test
`df.http()` against `httpbingo.org` (allowed via `http-allow-test-domains`).
Those tests validate HTTP functionality (GET, POST, headers, sequences, etc.).

This example suite is complementary — it validates that each **Azure domain
suffix** is reachable through the allowlist with a real Azure service.
