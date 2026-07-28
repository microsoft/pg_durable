# Audio Round Trip

A workflow that speaks a phrase, transcribes the audio back to text, and checks
whether it survived the trip — entirely inside PostgreSQL.

```
phrase (text)
   │
   ├─ df.http            → Azure OpenAI /audio/speech       → MP3 (audio/mpeg)
   │
   ├─ df.http_multipart  → Azure OpenAI /audio/transcriptions → {"text": "..."}
   │
   └─ SQL                → store transcript, compare, record verdict
```

## Why this example exists

Most HTTP examples move JSON between steps. This one moves **binary** between
steps, which is where composition actually gets tested:

- The speech call returns `audio/mpeg`. pg_durable detects a non-textual
  `Content-Type`, base64-encodes the bytes into the response envelope, and sets
  `encoding` to `base64`. Decoding it as UTF-8 instead would silently replace
  every invalid byte sequence with `U+FFFD` and destroy the MP3.
- The transcription call uploads that audio as `multipart/form-data`, taking the
  payload straight from the previous response:

  ```sql
  'data_b64', '$speech.body'
  ```

  The audio never passes through a SQL node. No query string ever contains it,
  and it is never widened by SQL quoting.

- The form carries three parts, not just the file: `model` and an optional
  Whisper `prompt` ride alongside the binary `file`. The `prompt` text is 75
  bytes, and `encode(..., 'base64')` wraps anything over 57 bytes onto multiple
  lines — so that part also demonstrates that wrapped base64 is accepted.

- The workflow verifies itself. A silent corruption produces a wrong transcript,
  not a green run.

## Prerequisites

- pg_durable built with the `http-allow-azure-domains` feature
- The `df` role permissions to use HTTP:
  ```sql
  SELECT df.grant_usage('your_role', include_http => true);
  ```
- Azure CLI, logged in (`az login`)

## Setup

```bash
cd examples/audio-roundtrip

# Creates a resource group, an Azure OpenAI account, and the two deployments,
# then writes .audio-roundtrip.env (mode 600, git-ignored).
./scripts/provision_azure.sh

# Optional: confirm the live API behaves as the example assumes.
./scripts/live_smoke_check.sh

set -a && source .audio-roundtrip.env && set +a

psql -d postgres -f sql/01_schema.sql
psql -d postgres -f sql/02_set_vars.sql
psql -d postgres -f sql/03_seed_phrases.sql
psql -d postgres -f sql/04_start_workflow.sql
```

Then watch it run, and check the result:

```bash
psql -d postgres -f sql/05_monitor.sql   # re-run while it works
psql -d postgres -f sql/06_verify.sql    # raises an exception if it did not work
```

To run it again: `psql -d postgres -f sql/07_reset.sql`, then re-run
`04_start_workflow.sql`.

To tear down Azure: `./scripts/cleanup_azure.sh`.

## Region

The account must be in a region offering **both** `tts` and `whisper`. Fewer
regions do than you might expect:

| Region | `tts` | `whisper` |
|---|---|---|
| `northcentralus` (default) | yes | yes |
| `swedencentral` (alternative) | yes | yes |
| `westeurope` | no | yes |
| `eastus2` | only `gpt-4o-mini-tts` (GlobalStandard) | yes |

To use the alternative:

```bash
LOCATION=swedencentral ./scripts/provision_azure.sh
```

Check any other region before trying it:

```bash
az cognitiveservices model list -l <region> \
  --query "[?model.name=='tts' || model.name=='whisper'].model.name" -o tsv
```

## Things this example had to account for

**Whisper does not return your phrase verbatim, or even consistently.** Sending
`pg durable makes workflows durable` returned `PgDurable makes workflows
durable.` on one run and `PG Durable makes workflows durable.` on the next —
same input, same deployment, different word boundaries. Adding the `prompt`
part shifted it again, to `pg durable makes workflows durable.` Add to that the
casing change and the trailing period, and comparing raw strings would report a
*correct* transcription as a failure. `demo.audio_normalize()` reduces both
sides to letters and digits before comparing. Exact-match verification here
would be flaky, not strict.

**Whisper is limited to 3 requests per minute** on a Standard deployment, and
the quota is granted per *subscription*, not per deployment. The workflow paces
itself with `df.sleep(20)` between phrases. That is a durable timer: the worker
is free during the wait, and the delay survives a restart.

**A 429 is not an error, as far as the activity is concerned.** pg_durable
returns `Err` only for 5xx; every 4xx comes back as a *completed* activity
carrying `ok: false`. Without handling, a rate-limited run would report
`completed` while transcribing nothing. The workflow branches on
`$speech.ok` and records `speech_status` / `transcribe_status`, so a throttled
run is visibly different from a clean one.

**Phrases cannot contain `"` or `\`.** The phrase is substituted into a JSON
request body, and `df.http` performs raw substitution without JSON escaping. A
`CHECK` constraint in `01_schema.sql` rejects those characters at insert time
rather than letting the workflow fail later against an upstream 400.

## The API reference is wrong about `/audio/speech`

For `2025-04-01-preview`, the request-body table says `multipart/form-data`
while the worked example immediately below it posts JSON. They imply different
DSL calls.

JSON is correct — verified against a live deployment, and re-verifiable with
`./scripts/live_smoke_check.sh`. That is why the speech step uses `df.http`
rather than `df.http_multipart`.

## Files

| File | Purpose |
|---|---|
| `sql/01_schema.sql` | Tables and the normalization function |
| `sql/02_set_vars.sql` | Build request URLs, store the key via `df.setvar` |
| `sql/03_seed_phrases.sql` | Insert the phrases |
| `sql/04_start_workflow.sql` | The workflow |
| `sql/05_monitor.sql` | Progress |
| `sql/06_verify.sql` | Assertions; raises on failure |
| `sql/07_reset.sql` | Reset for another run |
| `scripts/provision_azure.sh` | Create Azure resources, write the env file |
| `scripts/cleanup_azure.sh` | Delete them |
| `scripts/smoke_check.sh` | Offline, CI-safe checks |
| `scripts/live_smoke_check.sh` | Live API probe |

## Cost

Pay-per-use with no idle charge: TTS bills per character, Whisper per
audio-minute. The three seeded phrases are short, so a full run costs a
fraction of a cent. `cleanup_azure.sh` removes everything.
