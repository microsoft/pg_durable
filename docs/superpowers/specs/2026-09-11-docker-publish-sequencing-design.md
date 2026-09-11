# Docker Publish Sequencing

## Problem

Publishing a GitHub release starts Docker Publish immediately. Package Release
runs separately from the tag push and has not yet uploaded the Debian packages,
so Docker Publish fails with `no assets to download`.

## Design

Trigger Docker Publish both when a release is published and when Package
Release completes, while retaining `workflow_dispatch` for recovery and
operator-controlled reruns. A preparation job will publish only after the
release is public and both PostgreSQL package assets are available.

The two automatic triggers cover either event order:

- In the normal flow, Package Release uploads assets to a draft release and
  does not publish images. Publishing that release then starts Docker Publish.
- If a release is published before its package assets are ready, that run
  defers successfully. The later successful Package Release completion starts
  Docker Publish once the assets are available.

Package-completion events are accepted only for successful tag-push runs in
`microsoft/pg_durable`. Use `workflow_run.head_branch` as their release tag.
Manual runs continue using the required `ref` input. The existing package
download, image build, smoke test, immutable-tag protection, and GHCR
publication steps remain unchanged.

## Failure Handling

An unsuccessful Package Release will not start Docker Publish. A
release-published event with missing package assets defers without failing
because the successful Package Release completion will retry it. A successful
upstream run with missing package assets remains a hard failure, preserving the
existing diagnostic rather than hiding an invalid release state.

Operators can recover an existing release by manually dispatching Docker
Publish after its package assets are available.

## Validation

Add shell regression tests for manual dispatch, normal draft-release ordering,
early release publication, failed upstream runs, and invalid successful
upstream state. Validate the workflow syntax and event conditions locally.
After the v0.2.8 Package Release finishes, rerun Docker Publish against `v0.2.8`
to confirm package download, image build, smoke testing, and publication.
