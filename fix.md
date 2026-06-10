# Docker → GHCR Publishing: Triage

Review scope: the combined GHCR-publishing work (commits #218 + #222) plus the
current unstaged README edits. Covers
[.github/workflows/docker-publish.yml](.github/workflows/docker-publish.yml),
[Dockerfile.release](Dockerfile.release), and the Docker/Packages docs in
[README.md](README.md). The local-dev Docker CI
([Dockerfile](Dockerfile), [.github/workflows/docker.yml](.github/workflows/docker.yml))
is out of scope except where docs blur the two.

Severity reflects user/operational impact. Priority reflects suggested order of
work. Status tracks remediation.

## 1. Docker Publish workflow / `Dockerfile.release`

| # | Severity | Priority | Status | Item |
|---|----------|----------|--------|------|
| 1 | High | P1 | Addressed | **`POSTGRES_DB` mismatch footgun.** The init script in [Dockerfile.release](Dockerfile.release) creates the extension in `$POSTGRES_DB`, but the config hardcodes `pg_durable.database = 'postgres'`. If an evaluator runs `-e POSTGRES_DB=myapp`, the extension lands in `myapp` while the worker targets `postgres` — durable functions silently never execute. **Decision: pin the init script to the `postgres` DB.** |
| 2 | Medium | P2 | Addressed | **`dpkg -i` doesn't resolve dependencies.** [Dockerfile.release](Dockerfile.release) manually installs `libssl3`/`ca-certificates` then `dpkg -i`. If the `.deb` ever declares another dependency, the build breaks. Prefer `apt-get install -y /tmp/pg_durable.deb` (apt resolves declared deps automatically). |
| 3 | Medium | P2 | Open | **Manual dispatch pushes by default.** `dry_run` defaults to `false`, so an ad-hoc `workflow_dispatch` immediately mutates GHCR (including floating `latest`/`pg<major>`). Consider defaulting `dry_run: true` for the manual path so pushing is a deliberate choice. |
| 4 | Medium | P2 | Open | **`gh release list` default limit (30).** The "highest stable release" computation in the `meta` step relies on `gh release list` without `--limit`, which defaults to 30. Once the project exceeds 30 releases, the floating-tag guard could mis-resolve. Add an explicit `--limit 1000` (or similar). |
| 5 | Low | P3 | Open | **Floating immutable tags can be overwritten.** GHCR permits overwriting; re-running the workflow for an already-published tag re-pushes the "immutable" `X.Y.Z-pg<major>` tags. **Decision: add a workflow input `overwrite` (default `false`) to control this behavior** — skip pushing an already-published tag digest unless `overwrite` is set. |
| 6 | Low | P3 | Open | **No provenance/SBOM attestation.** `build-push-action` can emit provenance + SBOM (`provenance: true`, `sbom: true`). Cheap supply-chain hygiene for a public Microsoft image. |
| 7 | Low | P3 | Open | **Actions pinned to floating major tags** (`@v4`, `@v3`, `@v6`). Pinning to commit SHAs is the hardening best practice for publish workflows with `packages: write`. (Repo-wide convention, not unique to this PR.) |
| 8 | Low | P3 | Open | **Smoke test is version-only.** It verifies `CREATE EXTENSION` + `df.version()` but never starts a durable function, so the `POSTGRES_DB`/worker mismatch in item 1 wouldn't be caught. A minimal `df.start(...)` + poll would catch worker-config regressions. |
| 9 | Low | P3 | Addressed | **No image `HEALTHCHECK`.** Optional, but useful for an eval image people may `docker run` casually. |

## 2. Documentation

| # | Severity | Priority | Status | Item |
|---|----------|----------|--------|------|
| 10 | Medium | P2 | Open | **Stale "production Dockerfile" claim.** [docs/http-security.md](docs/http-security.md#L37) says *"The production `Dockerfile` uses `http-allow-azure-domains`."* That's inaccurate now: [Dockerfile](Dockerfile) builds with `http-allow-test-domains`, and the published image ([Dockerfile.release](Dockerfile.release)) inherits whatever the `.deb` was built with. Update to reference the released package / `Dockerfile.release`. |
| 11 | Medium | P2 | Open | **Published eval image lives under "Development Installation."** The GHCR run instructions sit at [README.md](README.md#L165) under *Development Installation → Other environments*, but the image is explicitly *not* for development (it's the prebuilt eval/learning artifact). An evaluator looking for "just run it" reads the dev-setup section. Consider surfacing the `docker run` near *Packages* / a Quickstart, and keeping only the from-source `test-e2e-docker.sh` flow under Development. |
| 12 | Low | P3 | Open | **Two images, one section, easy to conflate.** [README.md](README.md#L165) references both the GHCR images and `test-e2e-docker.sh` (which builds the source [Dockerfile](Dockerfile)). A one-line explicit contrast ("GHCR image = released `.deb` on official postgres; `Dockerfile` = source build for CI/dev") would remove all ambiguity. |
| 13 | Low | P3 | Open | **`deploy-acr.sh` mention adds noise.** The ACR line under Docker references a third, unrelated distribution path (custom baked-in image). For an eval-focused section it's a distraction; consider moving it to a contributor/ops doc. |
| 14 | Low | P3 | Open | **Run examples use floating tags only.** Both Packages and Docker examples show `latest`/`pg17`/`pg18`. A note that immutable `X.Y.Z-pg<major>` tags exist for reproducible/pinned use would help readers who want a fixed digest for evaluation. **Depends on #5:** once the `overwrite` input enforces immutability, the docs can state immutable tags are *guaranteed* stable rather than merely existing — which downgrades the urgency of this item. |
| 15 | Medium | P2 | Open | **`POSTGRES_DB` is ignored (new, follows from #1).** After #1 pins the init script to the `postgres` database, the README/Packages warning must state explicitly that **`POSTGRES_DB` is ignored — the extension always installs into `postgres`**. The current unstaged README examples imply `POSTGRES_DB` is freely settable, which contradicts the fixed behavior. |
| 16 | Low | P3 | Open | **No maintainer runbook for the publish workflow (new, follows from #3 + #5).** The `dry_run` (#3) and `overwrite` (#5) inputs add operator-facing knobs with no home: today the only Docker-publish docs are end-user-facing in the README. Add a maintainer/release runbook covering the `workflow_dispatch` inputs (`ref`, `dry_run`, `overwrite`) — when to set each and the expected push behavior. |

## Suggested order

1. **#1** (worker/DB mismatch) — real functional footgun in the shipped eval image.
2. **#2, #3, #4** — robustness of the publish pipeline.
3. **#10, #11** — doc accuracy and placement.
4. Remaining low-severity hardening/polish.
