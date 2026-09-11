# Docker Publish Sequencing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent Docker Publish from failing when a GitHub release is published before its Debian package assets are uploaded.

**Architecture:** Add a small, testable shell preparation layer that resolves the release tag and decides whether publication is ready. Trigger Docker Publish from both release publication and successful Package Release completion so either event order converges on one publication path without bypassing the draft-release gate.

**Tech Stack:** GitHub Actions YAML, Bash, GitHub CLI

## Global Constraints

- Preserve the existing manual `workflow_dispatch` recovery path.
- Do not publish images while the GitHub release is still a draft.
- Accept automatic `workflow_run` events only from successful tag-push Package Release runs.
- Treat missing assets after a successful Package Release as an error.
- Keep the existing image build, smoke test, tag protection, provenance, and SBOM behavior.

---

### Task 1: Add a tested publication readiness resolver

**Files:**
- Create: `scripts/prepare-docker-publish.sh`
- Create: `scripts/test-prepare-docker-publish.sh`
- Modify: `.github/workflows/ci.yml:47-55`

**Interfaces:**
- Consumes: `EVENT_NAME`, `INPUT_REF`, `RELEASE_TAG`, `WORKFLOW_RUN_TAG`, `WORKFLOW_RUN_EVENT`, `WORKFLOW_RUN_CONCLUSION`, `GITHUB_REPOSITORY`, and `GITHUB_OUTPUT`.
- Produces: GitHub Actions outputs `tag`, `version`, and `ready`.

- [ ] **Step 1: Write the failing shell regression test**

Create `scripts/test-prepare-docker-publish.sh` with a temporary fake `gh` executable and cases asserting:

```bash
run_case manual env \
    EVENT_NAME=workflow_dispatch INPUT_REF=v0.2.8 \
    "$resolver"
assert_output tag v0.2.8
assert_output version 0.2.8
assert_output ready true

run_case draft env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=success WORKFLOW_RUN_TAG=v0.2.8 \
    GH_TEST_DRAFT=true GH_TEST_ASSETS="$all_assets" \
    "$resolver"
assert_output ready false

run_case early_release env \
    EVENT_NAME=release RELEASE_TAG=v0.2.8 \
    GH_TEST_DRAFT=false GH_TEST_ASSETS="" \
    "$resolver"
assert_output ready false

run_case package_complete env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=success WORKFLOW_RUN_TAG=v0.2.8 \
    GH_TEST_DRAFT=false GH_TEST_ASSETS="$all_assets" \
    "$resolver"
assert_output ready true
```

Also assert that a failed upstream run yields `ready=false`, while a successful upstream run for a published release with a missing PG17 or PG18 package exits nonzero.

- [ ] **Step 2: Run the regression test to verify it fails**

Run:

```bash
bash scripts/test-prepare-docker-publish.sh
```

Expected: FAIL because `scripts/prepare-docker-publish.sh` does not exist.

- [ ] **Step 3: Implement the minimal resolver**

Create `scripts/prepare-docker-publish.sh` that:

```bash
case "$EVENT_NAME" in
    workflow_dispatch) tag="$INPUT_REF" ;;
    release) tag="$RELEASE_TAG" ;;
    workflow_run)
        if [ "$WORKFLOW_RUN_EVENT" != push ] || [ "$WORKFLOW_RUN_CONCLUSION" != success ]; then
            write_outputs "" "" false
            exit 0
        fi
        tag="$WORKFLOW_RUN_TAG"
        ;;
    *) echo "unsupported event: $EVENT_NAME" >&2; exit 2 ;;
esac
```

Validate the `v*` tag, emit `tag` and `version`, and return `ready=true` immediately for manual dispatch. For automatic events, query:

```bash
is_draft="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)"
assets="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name')"
```

For a draft release, emit `ready=false`. Require package names matching both `pg-durable-postgresql-17_*_amd64.deb` and `pg-durable-postgresql-18_*_amd64.deb`. On a release event, missing assets emit `ready=false`; after a successful Package Release event, missing assets exit nonzero.

- [ ] **Step 4: Run the resolver regression test**

Run:

```bash
bash scripts/test-prepare-docker-publish.sh
```

Expected: PASS with each named event-ordering case reported.

- [ ] **Step 5: Add the regression test to CI**

Add this step to the `make_install_smoke` job in `.github/workflows/ci.yml`:

```yaml
      - name: Test release workflow sequencing
        run: ./scripts/test-prepare-docker-publish.sh
```

- [ ] **Step 6: Commit the resolver and tests**

```bash
git add scripts/prepare-docker-publish.sh scripts/test-prepare-docker-publish.sh .github/workflows/ci.yml
git commit -m "Test Docker publish readiness"
```

### Task 2: Sequence Docker publication across both event orders

**Files:**
- Modify: `.github/workflows/docker-publish.yml`
- Modify: `prompts/pg_durable-release.md:33-49`
- Modify: `prompts/pg_durable-release.md:306-321`

**Interfaces:**
- Consumes: Task 1 outputs `tag`, `version`, and `ready`.
- Produces: A release workflow that publishes only when the release is public and both Debian packages exist.

- [ ] **Step 1: Add the Package Release completion trigger**

Keep `release: types: [published]` and `workflow_dispatch`, and add:

```yaml
  workflow_run:
    workflows: ['Package Release']
    types: [completed]
```

Use one tag-based concurrency key for all event types and enable cancellation so simultaneous release and completion events converge on the newest run:

```yaml
concurrency:
  group: docker-publish-${{ github.event.release.tag_name || github.event.workflow_run.head_branch || github.event.inputs.ref }}
  cancel-in-progress: true
```

- [ ] **Step 2: Add the preparation job**

Create a non-matrix `prepare` job that checks out release tooling from the default branch for automatic events, runs `scripts/prepare-docker-publish.sh`, and exposes its three outputs. Pass the event fields explicitly:

```yaml
env:
  EVENT_NAME: ${{ github.event_name }}
  INPUT_REF: ${{ github.event.inputs.ref }}
  RELEASE_TAG: ${{ github.event.release.tag_name }}
  WORKFLOW_RUN_TAG: ${{ github.event.workflow_run.head_branch }}
  WORKFLOW_RUN_EVENT: ${{ github.event.workflow_run.event }}
  WORKFLOW_RUN_CONCLUSION: ${{ github.event.workflow_run.conclusion }}
```

- [ ] **Step 3: Gate and simplify the matrix publish job**

Set:

```yaml
needs: prepare
if: github.repository == 'microsoft/pg_durable' && needs.prepare.outputs.ready == 'true'
```

Replace the existing version-resolution step with a package-download-only step using `${{ needs.prepare.outputs.tag }}`. Replace all `${{ steps.pkg.outputs.version }}` references with `${{ needs.prepare.outputs.version }}`.

- [ ] **Step 4: Update the release procedure**

Document that Docker Publish listens to both release publication and successful Package Release completion, but publishes only when the release is public and package assets exist. Explain that either event order is supported and that manual dispatch remains the recovery path.

- [ ] **Step 5: Run targeted validation**

Run:

```bash
bash -n scripts/prepare-docker-publish.sh scripts/test-prepare-docker-publish.sh
bash scripts/test-prepare-docker-publish.sh
git diff --check
```

Expected: both scripts parse, all resolver cases pass, and the diff has no whitespace errors.

- [ ] **Step 6: Commit the workflow change**

```bash
git add .github/workflows/docker-publish.yml prompts/pg_durable-release.md
git commit -m "Sequence Docker publish after package assets"
```

### Task 3: Verify recovery and open the draft pull request

**Files:**
- Verify: `.github/workflows/docker-publish.yml`
- Verify: GitHub Actions run `34625193749`

**Interfaces:**
- Consumes: Completed implementation and the rerun v0.2.8 Docker Publish workflow.
- Produces: Published v0.2.8 images and a draft PR containing the permanent fix.

- [ ] **Step 1: Confirm the v0.2.8 recovery run**

Run:

```bash
gh run watch 34625193749 --repo microsoft/pg_durable --exit-status
gh run view 34625193749 --repo microsoft/pg_durable --json status,conclusion,jobs,url
```

Expected: PG17 and PG18 image jobs succeed.

- [ ] **Step 2: Verify release assets and image tags**

Run:

```bash
gh release view v0.2.8 --repo microsoft/pg_durable --json assets,url
gh api /orgs/microsoft/packages/container/pg_durable/versions --paginate
```

Expected: both Debian packages and source archives are attached, and v0.2.8 image versions are present.

- [ ] **Step 3: Push and create a draft PR**

```bash
git push -u origin fix/docker-publish-sequencing
gh pr create --repo microsoft/pg_durable --draft \
  --title "Fix Docker publish release ordering" \
  --body $'Publishes Docker images only after the GitHub release is public and both Debian package assets exist.\n\nHandles both event orders by listening for release publication and successful Package Release completion, while retaining manual dispatch for recovery.\n\nValidation: shell regression tests for manual, draft, early-publication, success, and invalid-asset cases.'
```

Expected: a draft pull request targeting `main`.
