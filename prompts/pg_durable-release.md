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
4. Drives the **tag → draft GitHub Release → publish → GHCR image + PGXN**
   automation.
5. Opens the **next-development-cycle** PR.

> **This prompt owns a per-release tracking issue.** The prompt is the *procedure*
> (static, reusable); the issue titled "Release vX.Y.Z" is the *state + audit
> trail* for one release — a checklist of gates plus links (changelog PR, tag,
> draft Release, GHCR and PGXN runs) and who approved tag/publish. Step 0 creates it from
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
| Stable Release **published** | **PGXN Publish** (`.github/workflows/pgxn-publish.yml`) | Checks out the exact `vX.Y.Z` tag, generates and validates `META.json`, builds `make pgxn-zip`, validates the ZIP and uploads it to PGXN. Prereleases are excluded. Runs independently of Docker Publish. |
| Pull request | **CI** (`.github/workflows/ci.yml`), **Package Release** (PR validation), **Upgrade tests** | fmt/clippy, unit + E2E, `.deb` build validation, and `scripts/test-upgrade.sh`. |

Key consequences:

- **Tagging is the action that builds the draft Release** — you don't create it
  by hand. You fill in its notes and click **Publish**.
- **Publishing is a manual gate for both GHCR and PGXN.** Until you publish,
  neither registry workflow uploads anything, so a botched tag is still recoverable
  (see "If the tag run fails").
- **Publishing a stable GitHub Release authorizes the PGXN upload too.** There
  is no second manual upload step. Explain this when asking for publish approval.
  Publishing a draft in the GitHub UI (or with an authenticated maintainer's
  `gh release edit vX.Y.Z --draft=false`) emits `release: published`. Do not use
  an Actions job's `GITHUB_TOKEN` to publish: events generated with that token
  do not start these downstream release workflows. The draft created by Package
  Release is not itself a publish event.
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
- [ ] PGXN credentials configured (secret names only; never record values)
- [ ] CI green on tag commit (<sha>)
- [ ] Tagged vX.Y.Z → draft Release (run #…, release: …)
- [ ] Release published (approved by: …)
- [ ] GHCR images confirmed (run #…)
- [ ] PGXN release confirmed (run #…, distribution: …; N/A for prerelease)
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
3. Review the section as user-facing release history, even if it is already
   complete. Propose edits when entries are wordy, implementation-focused, or
   more detailed than users need. Remove pure CI/infrastructure work, expected
   behavior of a newly added feature, and bugs introduced and fixed within the
   same unreleased cycle. Keep operationally important compatibility, migration,
   and security guidance, but link to detailed docs instead of reproducing them.
4. **If the section is missing, empty, or needs the editorial fixes above**,
   draft or revise it:
   ```bash
   # Merged, user-facing changes since the previous tag
   git log --oneline --no-merges vX.Y.<prev>..main
   # Resolve a squashed commit to its PR when the number isn't in the subject
   gh api repos/microsoft/pg_durable/commits/<sha>/pulls --jq '.[].number'
   ```
    Curate into user-facing entries with PR references. Verify dependency lines
    against `Cargo.toml` (don't claim a `duroxide`/`duroxide-pg` bump that didn't
    happen).
5. Open a PR with the changelog (and any docs sweep from Step 2), get it merged
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
- `META.json.in` is present and `make META.json` renders the release
  version. The PGXN metadata is generated from `Cargo.toml`, so there is no
  separate version to bump. Stable releases require `release_status: stable`
  and an exact `vX.Y.Z` tag matching the crate and provided extension version.
- Before a stable release, verify the repository Actions secrets
  `PGXN_USERNAME` and `PGXN_PASSWORD` have been configured as described in
  Step 6b. Never ask for the password in chat or put its value in the tracking
  issue. Secret presence can be checked with
  `gh secret list --repo microsoft/pg_durable`; this does not reveal values.

> **Update the tracking issue:** tick **Version/upgrade-script sanity**.
> Tick **PGXN credentials configured** after confirming setup (N/A for prerelease).

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

The Package Release run creates the draft with placeholder notes. Write a brief,
punchy release summary as a **separate editorial exercise** from the changelog,
then add an **Acknowledgements** credit and GitHub's auto-generated **New
Contributors** section. The changelog is the complete user-facing history; the
GitHub Release should help readers scan the release's value and upgrade impact.

Use the committed changelog as source material, but do not copy it verbatim:

- Prefer one short sentence per item and combine closely related changes.
- Lead with headline capabilities and meaningful behavior changes.
- Keep breaking, migration, security, and operational warnings concise but
  prominent; link to detailed documentation.
- Omit routine dependencies, documentation-only changes, internal refactors,
  and CI/infrastructure work unless they materially affect users.
- Omit expected details of a newly introduced feature and bugs introduced and
  fixed within the same release cycle.
- Aim for substantially fewer words than the corresponding changelog section.

Draft the summary in a throwaway temp file. Do **not** create or commit a
separate `release-notes-*.md`; the durable detailed record remains
`CHANGELOG.md`.

```bash
# 1. Extract the changelog section as source material and seed a separate draft.
#    Rewrite the draft editorially before continuing; do not leave it as a copy.
awk '/^## \[X\.Y\.Z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md > /tmp/changelog-X.Y.Z.md
cp /tmp/changelog-X.Y.Z.md /tmp/release-summary-X.Y.Z.md

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

# 5. Assemble: concise release summary + Acknowledgements + trimmed auto notes,
#    then set the release body
{
  cat /tmp/release-summary-X.Y.Z.md
  printf '\n---\n\n## Acknowledgements\n\nThanks to everyone who contributed to this release: %s.\n\n' "$contributors"
  cat /tmp/auto-notes-X.Y.Z.md
} > /tmp/release-body-X.Y.Z.md
gh release edit vX.Y.Z --notes-file /tmp/release-body-X.Y.Z.md
```

- The temp files are transient (e.g. under `/tmp`); they are **not** part of any
  PR and the Package Release workflow never reads them. `CHANGELOG.md` remains
  the durable detailed record; the GitHub Release is its concise editorial
  companion.
- `--notes-file` sets **only the GitHub Release body** — it does not touch
  `CHANGELOG.md`.
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
and ordered sensibly, then **Publish** (ask the user before publishing, explicitly
including the automatic PGXN upload for stable releases). For a
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

## Step 6b: Confirm automated PGXN publication

Publishing a **stable** GitHub Release automatically starts **PGXN Publish**.
Pushing a tag, creating/editing a draft, or editing an already-published release
does not trigger it. Releases marked as prereleases are skipped; tags with
prerelease/build suffixes are rejected even if incorrectly marked stable.
The workflow must be merged to `main` before cutting the next release tag.

The workflow checks out the exact release tag separately from its current
release tooling, then runs `make -B META.json`, `pgxn validate-meta META.json`,
and `make pgxn-zip` using a digest-pinned PGXN tools image. It verifies the tag,
crate and metadata versions, stable status, provided extension, documentation,
and archive layout. `make pgxn-zip` explicitly includes the generated,
gitignored metadata at `pg_durable-X.Y.Z/META.json`; do not replace it with a
bare `git archive` or `pgxn-bundle` that omits that file.

The ZIP and `PGXN-SHA256SUMS` are retained for 30 days in the workflow's Actions
artifact (not added to the GitHub Release's existing `SHA256SUMS`). A separate
job downloads that artifact, verifies its checksum, and sends the exact ZIP to
PGXN Manager using `pgxn-release`. Only that final step receives PGXN secrets.
No PostgreSQL compilation or schema migration is involved.

### One-time credentials setup

In [repository Actions secrets](https://github.com/microsoft/pg_durable/settings/secrets/actions),
choose **New repository secret** and register:

| Name | Value |
|------|-------|
| `PGXN_USERNAME` | `Pino` |
| `PGXN_PASSWORD` | The password for the PGXN Manager account `Pino` |

Alternatively, from a trusted terminal authenticated to GitHub with repository
secret-management permission:

```bash
gh secret set PGXN_USERNAME --repo microsoft/pg_durable --body "Pino"
gh secret set PGXN_PASSWORD --repo microsoft/pg_durable
```

The second command prompts for the password with hidden input. Do **not** put
the password in `--body`, an environment file, chat, logs, or a committed file.
These are **repository Actions secrets**, not Dependabot or Codespaces secrets.
The account must be allowed to release the existing `pg_durable` distribution
and provided extension on PGXN. GitHub's `GITHUB_TOKEN` is not a PGXN credential.
To rotate the password, update the same secret; no code change is needed.
Missing/empty secrets cause a clear failure, not a silently skipped upload.

### Dry run and recovery

Before publishing, run against the draft Release created by Package Release:

```bash
gh workflow run pgxn-publish.yml --repo microsoft/pg_durable --ref main \
  -f tag=vX.Y.Z -f dry_run=true
```

Dry runs prepare, validate, and retain the bundle without PGXN credentials or
upload. Relevant PRs also exercise bundle preparation without uploading.
For an actual upload, the GitHub Release must already be published and stable,
and a manual run must use `main` in `microsoft/pg_durable`.

```bash
gh run list --repo microsoft/pg_durable --workflow pgxn-publish.yml --limit 5
gh run watch <run-id> --repo microsoft/pg_durable --exit-status
```

Confirm the run's tag, PGXN acceptance in its summary, and the version at
`https://pgxn.org/dist/pg_durable/X.Y.Z/`. Indexing may lag upload acceptance;
also check that the README and documentation render.

If the workflow fails, the GitHub Release and GHCR publication are not rolled
back. Fix the reported problem, then re-run failed jobs, or, with explicit user
approval, dispatch with `-f tag=vX.Y.Z -f dry_run=false`. This also supports
backfilling a previously published release whose tag contains PGXN packaging.
Do not republish the GitHub Release just to retry PGXN.

**Never blindly retry an ambiguous upload failure.** Check PGXN Manager and the
public version page first: PGXN might have accepted the upload before the
connection failed. Existing versions are not overwritten; a duplicate upload
is an error, not a successful no-op. If the version already exists, verify it
and record that outcome rather than uploading again. Use a new release version
for changed source or metadata; never move a published tag.

> **Update the tracking issue:** link the PGXN run and version page and tick
> **PGXN release confirmed** (N/A for a prerelease).

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
- Manually dispatching a live PGXN upload (`dry_run=false`)
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
