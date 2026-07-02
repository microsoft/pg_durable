# Release Workflow

## Objective

Guide an AI agent or a human through releasing a new version of `pg_durable`. By
the time you reach the tagging step, the code is already merged and tested on
`main` — releasing is mostly **verification + publishing**, not testing. This
prompt therefore:

1. Makes sure the **CHANGELOG is up to date** for the version being released
   (this is the first thing to check, and it may itself require a PR).
2. Confirms the version/upgrade-script metadata is consistent.
3. Confirms the relevant CI workflows already **succeeded on the commit** being
   tagged (no fresh test runs required at tag time).
4. Drives the **tag → draft GitHub Release → publish → GHCR image** automation.
5. Opens the **next-development-cycle** PR.

> **This prompt owns a per-release tracking issue.** The prompt is the *procedure*
> (static, reusable); the issue titled "Release vX.Y.Z" is the *state + audit
> trail* for one release — a checklist of gates plus links (changelog PR, tag,
> draft Release, GHCR run) and who approved tag/publish. Step 0 creates it from
> the checklist in that step, and every step ends by ticking its box. Keep the
> issue to checkboxes + links; it must **not** re-narrate these instructions.

> **Releases are cut from the head of `main`.** All release content (changelog,
> version bump, upgrade script, doc updates) lands via PRs merged to `main`
> first; the `vX.Y.Z` tag is then placed on the tip of `main`. This prompt assumes
> you are operating on an up-to-date `main` (`git checkout main && git pull`),
> not a feature branch.

## The release automation (mental model)

Most of the heavy lifting is already wired into GitHub Actions. Know what fires
when, so you only do by hand what isn't automated:

| Trigger | Workflow | What it does |
|---------|----------|--------------|
| Push tag `v*` | **Package Release** (`.github/workflows/package-release.yml`) | Builds + validates the AMD64 `.deb` for PG 17 and 18, then **creates a *draft* GitHub Release** for the tag and attaches the `.deb` / source tarballs / `SHA256SUMS`. |
| Release **published** | **Docker Publish** (`.github/workflows/docker-publish.yml`) | Builds `ghcr.io/microsoft/pg_durable` from the released `.deb` (PG 17 + 18, amd64) and pushes the immutable `X.Y.Z-pg<major>` tags plus floating `pg<major>`/`latest` when it's the highest stable release. **The `.deb` assets must already be attached before this runs.** |
| Pull request | **CI** (`.github/workflows/ci.yml`), **Package Release** (PR validation), **Upgrade tests** | fmt/clippy, unit + E2E, `.deb` build validation, and `scripts/test-upgrade.sh`. |

Key consequences:

- **Tagging is the action that builds the draft Release** — you don't create it
  by hand. You fill in its notes and click **Publish**.
- **Publishing is a manual gate.** Until you publish, nothing has reached GHCR
  and no consumer has seen the release, so a botched tag is still recoverable
  (see "If the tag run fails").
- **No testing happens at tag time.** Verify the checks were already green on the
  commit you are tagging.

## Step 0: Open the tracking issue and decide the cut line

Create (or reuse) the release tracking issue — this is where you record progress
for the rest of the workflow. It is intentionally **state + links only** (the
procedure lives in this prompt, not the issue):

```bash
# Reuse an existing "Release vX.Y.Z" issue if one is already open
gh issue list --search "Release vX.Y.Z in:title" --state open

# Otherwise, write the checklist and open the issue (substitute X.Y.Z):
cat > /tmp/release-vX.Y.Z-checklist.md <<'EOF'
Tracking issue for the **vX.Y.Z** release. Procedure: `prompts/pg_durable-release.md`.

**Cut line (PRs in this release):** _…_
**Tag commit:** _<sha>_
**Published by:** _…_

- [ ] Cut line confirmed
- [ ] Changelog merged (PR #…)
- [ ] Version/upgrade-script sanity
- [ ] CI green on tag commit (<sha>)
- [ ] Tagged vX.Y.Z → draft Release (run #…, release: …)
- [ ] Release published (approved by: …)
- [ ] GHCR images confirmed (run #…)
- [ ] Next-cycle PR opened (#…)
EOF
gh issue create --title "Release vX.Y.Z" --body-file /tmp/release-vX.Y.Z-checklist.md
```

Then confirm which PRs are in vs. out. Anything not merged to `main` before
tagging slips to the next version. Everything below assumes the release commit is
on `main`. Record the cut line in the issue and tick **Cut line confirmed**. Tick
the remaining boxes as you go with `gh issue edit <n> --body-file …` (or in the
UI); each step below names which box to check and what link to drop in.

## Step 1: Is the CHANGELOG up to date?  (do this first)

The changelog is curated prose, not a generated commit dump, so it is authored
here (by the agent or human) and lands via a PR — it is **not** automated.

1. Read the version in `Cargo.toml` (e.g. `0.2.3`).
2. Open `CHANGELOG.md` and check for a complete `## [X.Y.Z]` section for that
   version, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
   (grouped Added / Changed / Fixed / Security / Documentation, plus a Breaking
   Changes callout when relevant).
3. **If the section is missing or empty**, draft it:
   ```bash
   # Merged, user-facing changes since the previous tag
   git log --oneline --no-merges vX.Y.<prev>..main
   # Resolve a squashed commit to its PR when the number isn't in the subject
   gh api repos/microsoft/pg_durable/commits/<sha>/pulls --jq '.[].number'
   ```
   Curate into user-facing entries with PR references. **Exclude** pure CI/infra
   noise (e.g. adding a linter, Dependabot config) — that lives in git history,
   not the changelog. Verify dependency lines against `Cargo.toml` (don't claim a
   `duroxide`/`duroxide-pg` bump that didn't happen).
4. Open a PR with the changelog (and any docs sweep from Step 2), get it merged
   to `main`. **Do not tag until the changelog for the release is on `main`.**

> **Update the tracking issue:** link the changelog PR and tick **Changelog
> merged** once it lands on `main`.

> Dependency updates (`duroxide`/`duroxide-pg`, etc.) and doc updates belong in
> normal PRs merged before the release — not in the tagging step. If a dependency
> bump is still wanted, do it as its own PR first, then reflect it in the
> changelog (see the dependency-update appendix).

## Step 2: Version & upgrade-script sanity

Confirm these are consistent on the release commit:

- `Cargo.toml` `version = "X.Y.Z"` matches the tag you intend to push.
- `pg_durable.control` is consistent.
- The upgrade script `sql/pg_durable--<prev>--X.Y.Z.sql` exists (even if it only
  carries the license header + upgrade stub).
- Any version-stamped `expected/` fixtures are consistent.

> **Update the tracking issue:** tick **Version/upgrade-script sanity**.

## Step 3: Confirm CI is green on the release commit

No new local test runs are required at tag time — just confirm the automation
already passed on the exact commit you're about to tag:

```bash
# Checks on the tip of main (the commit you'll tag)
gh pr checks <last-release-PR>           # or:
gh run list --branch main --limit 10
```

Confirm green: **CI** (fmt/clippy, unit, E2E), **Package Release** PR validation
(the `.deb` builds), and **Upgrade tests** (`scripts/test-upgrade.sh` — Scenario
A == fresh schema, B1 new `.so` vs all previous schemas in the provider line, B2
chain). Only if something looks stale should you re-run locally:

```bash
cargo fmt -p pg_durable -- --check
cargo clippy --features pg17
./scripts/test-unit.sh
./scripts/test-e2e-local.sh
./scripts/test-upgrade.sh
```

> **Update the tracking issue:** record the tag-candidate `<sha>` and tick **CI
> green on tag commit**.

## Step 4: Tag the release (builds the draft Release)

With the changelog merged and checks green, create and push the annotated tag.
**Ask the user before pushing the tag.**

```bash
git checkout main && git pull origin main
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

Pushing the tag triggers **Package Release**, which builds/validates the PG 17 +
PG 18 `.deb` packages and then **creates a draft GitHub Release** with the assets
attached. Watch it:

```bash
gh run watch "$(gh run list --workflow package-release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

> **Update the tracking issue:** link the Package Release run and the draft
> Release, and tick **Tagged → draft Release**.

### If the tag run fails

- **Failure before the final `release` job** (the common case — a `.deb` build or
  validation error): the draft Release is **not** created. Fix forward on `main`,
  then **move the tag** to the new commit (safe while unpublished):
  ```bash
  git tag -f vX.Y.Z <new-commit>
  git push -f origin vX.Y.Z
  ```
  Re-running reuses an existing draft if one was created and just refreshes the
  assets (`--clobber`).
- **Rule:** moving a `v*` tag is only acceptable while the Release is still an
  unpublished draft. Once published, treat the tag as immutable and ship the next
  patch instead.

## Step 5: Fill release notes and publish

The Package Release run creates the draft with placeholder notes. Replace them
with the curated changelog **plus** an **Acknowledgements** credit and GitHub's
auto-generated **New Contributors** section, then publish. The release-body
content already lives in the committed `CHANGELOG.md`, so extract this version's
section on the fly into a throwaway temp file — **do not** create or commit a
separate `release-notes-*.md`.

```bash
# 1. Extract the "## [X.Y.Z]" block from CHANGELOG.md (stops at the next "## [" heading)
awk '/^## \[X\.Y\.Z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md > /tmp/notes-X.Y.Z.md

# 2. Fetch GitHub's auto-generated notes ONCE. `gh release edit` has NO
#    --generate-notes flag (only `gh release create` does), so we generate the
#    block separately and reuse it for both the trimmed notes and the
#    Contributors credit below.
gh api repos/microsoft/pg_durable/releases/generate-notes \
  -f tag_name=vX.Y.Z --jq '.body' > /tmp/gen-notes-X.Y.Z.md

# 3. Keep ONLY the "New Contributors" + "Full Changelog" parts. We deliberately
#    DROP the auto "## What's Changed" PR dump: it just re-lists the PRs the
#    curated CHANGELOG already covers (redundant noise). The awk skips from the
#    "What's Changed" heading until the next "## " heading or the
#    "**Full Changelog**" line.
awk '/^## What.s Changed/{skip=1; next} /^## /{skip=0} /^\*\*Full Changelog\*\*/{skip=0} !skip' \
  /tmp/gen-notes-X.Y.Z.md > /tmp/auto-notes-X.Y.Z.md

# 4. Build an "Acknowledgements" thank-you from EVERY "by @handle" in the
#    generated notes — the "## What's Changed" dump we just dropped is the ONLY
#    place with per-PR authorship. "New Contributors" alone lists only
#    *first-time* contributors, so without this step returning contributors get
#    no credit. Dedupe and strip bots (@dependabot, @github-actions).
#    NOTE: use the heading "Acknowledgements", NOT "Contributors" — GitHub
#    auto-renders its own "Contributors" avatar widget on the release page, so a
#    body heading named "Contributors" produces a confusing duplicate section.
contributors=$(grep -oE 'by @[A-Za-z0-9-]+' /tmp/gen-notes-X.Y.Z.md \
  | sed 's/by //' | sort -u | grep -viE '@(dependabot|github-actions)' | paste -sd ' ' -)

# 5. Assemble: curated changelog + Acknowledgements credit + trimmed auto notes,
#    then set the release body
{
  cat /tmp/notes-X.Y.Z.md
  printf '\n---\n\n## Acknowledgements\n\nThanks to everyone who contributed to this release: %s.\n\n' "$contributors"
  cat /tmp/auto-notes-X.Y.Z.md
} > /tmp/release-body-X.Y.Z.md
gh release edit vX.Y.Z --notes-file /tmp/release-body-X.Y.Z.md
```

- The temp files are transient (e.g. under `/tmp`); they are **not** part of any
  PR and the Package Release workflow never reads them. The single source of
  truth for curated content is the committed `CHANGELOG.md`.
- `--notes-file` sets **only the GitHub Release body** — it does not touch
  `CHANGELOG.md`. The curated text comes from the changelog you already merged.
- The `releases/generate-notes` API returns a "## What's Changed" PR dump, a
  "## New Contributors" section, and a "Full Changelog" link. We **drop**
  "What's Changed" from the body (it re-lists the same PRs the curated changelog
  already describes, just ungrouped) but first **mine it for contributor
  handles** to build the **Acknowledgements** credit — it is the only section
  with per-PR authorship. Name that section **Acknowledgements**, not
  **Contributors**: GitHub auto-renders a native "Contributors" avatar widget on
  the release page, and a body heading of the same name creates a duplicate,
  confusing section. We keep **New Contributors** (first-timers) and the
  **Full Changelog** compare link in the **Release** (not in `CHANGELOG.md` —
  Keep a Changelog groups by change type, not by people). Anyone wanting the
  exhaustive per-PR list with attribution can follow the Full Changelog link.
  If the tag isn't pushed yet, the API can't compute the block — run this after
  Step 4.
- **Acknowledgements credit:** the `## Acknowledgements` line thanks *every*
  human who landed a PR in the release, not just first-timers. It is derived
  from the `by @handle` mentions in the generated notes with bots removed.
  Skipping it (as an earlier version of this prompt did) leaves only "New
  Contributors", which silently drops credit for returning contributors — the
  common case. Do **not** title it "Contributors": GitHub renders its own
  native "Contributors" avatar strip on the release page, so that heading would
  duplicate it.

Review the draft in the GitHub UI, confirm the `.deb`/source assets are attached
and ordered sensibly, then **Publish** (ask the user before publishing). For a
pre-release (e.g. `vX.Y.Z-rc1`), mark it as a pre-release so floating image tags
don't move.

> **Update the tracking issue:** tick **Release published** and record who
> approved publishing (the audit point that matters most).

## Step 6: Confirm GHCR images

Publishing the Release triggers **Docker Publish**. Confirm it pushed the image
tags:

```bash
gh run list --workflow docker-publish.yml --limit 1
```

Verify the tags at
<https://github.com/microsoft/pg_durable/pkgs/container/pg_durable>: immutable
`X.Y.Z-pg17` / `X.Y.Z-pg18`, and floating `pg17`/`pg18`/`latest` if this is the
highest stable release. To verify before publishing, you can dispatch Docker
Publish manually with `ref=vX.Y.Z`, `dry_run=true` (builds + smoke-tests, pushes
nothing).

> **Update the tracking issue:** link the Docker Publish run and tick **GHCR
> images confirmed**.

## Step 7: Open the next development cycle

After the Release is published, open a PR to start the next cycle:

- Bump `Cargo.toml` `X.Y.Z` → `X.Y.(Z+1)` and refresh `Cargo.lock`.
- Create an **empty** upgrade script `sql/pg_durable--X.Y.Z--X.Y.(Z+1).sql`
  (license header + upgrade-comment stub, no DDL yet).
- Optionally add a `## [X.Y.(Z+1)] - Unreleased` placeholder to `CHANGELOG.md`.
- Update `docs/upgrade-testing.md` "Version-Specific Changes" if its convention
  expects a new entry.

> **Update the tracking issue:** link the next-cycle PR, tick **Next-cycle PR
> opened**, and **close the issue** once every box is checked.

## ⚠️ Git operations require user approval

Do **not** perform these without explicit user confirmation, and never use
`--no-verify`:

- Committing or merging to `main`
- Pushing commits or tags (including moving a tag with `-f`)
- Publishing the GitHub Release
- Pushing images / deploying

---

## Appendix: optional pre-publish container check

The release `.deb` and GHCR images are validated by CI and the Docker Publish
smoke test, so a local Docker run is optional. If you want an extra check before
publishing:

```bash
./scripts/test-e2e-docker.sh --rebuild
```

## Appendix: dependency-update reference

Use these when a dependency bump is part of the pre-release PRs (Step 1's note),
not at tag time. Treat `duroxide` and `duroxide-pg` as a **compatible pair** —
check the `duroxide-pg` release notes/compatibility matrix before bumping either.

```bash
# Current pinned versions
grep -E '^(duroxide|duroxide-pg)' Cargo.toml

# Latest published versions
cargo search duroxide --limit 5
cargo search duroxide-pg --limit 5
```

After updating the version(s) in `Cargo.toml`, refresh `Cargo.lock`:

```bash
# If only duroxide-pg changed:
cargo update -p duroxide-pg
# If both changed:
cargo update -p duroxide -p duroxide-pg
```

The background worker's embedded duroxide migrations update automatically via
`include_dir!`; no extension SQL or upgrade-script changes are needed for a
duroxide/duroxide-pg bump alone. Land the bump as its own PR, then reflect it in
the `### Changed` section of the changelog.
