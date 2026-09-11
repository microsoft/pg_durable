# Docker Publish Sequencing

## Problem

Publishing a GitHub release starts Docker Publish immediately. Package Release
runs separately from the tag push and has not yet uploaded the Debian packages,
so Docker Publish fails with `no assets to download`.

## Design

Trigger Docker Publish when the Package Release workflow completes, while
retaining `workflow_dispatch` for recovery and operator-controlled reruns.

Automatic publication will run only when Package Release:

- completed successfully;
- was triggered by a tag push; and
- ran in `microsoft/pg_durable`.

For automatic runs, use `workflow_run.head_branch` as the release tag. Manual
runs continue using the required `ref` input. The existing package download,
image build, smoke test, immutable-tag protection, and GHCR publication steps
remain unchanged.

## Failure Handling

An unsuccessful Package Release will not start Docker Publish. A successful
upstream run with missing package assets remains a hard failure, preserving the
existing diagnostic rather than hiding an invalid release state.

Operators can recover an existing release by manually dispatching Docker
Publish after its package assets are available.

## Validation

Validate the workflow syntax and event conditions locally. After the v0.2.8
Package Release finishes, manually dispatch Docker Publish as a dry run against
`v0.2.8` to confirm package download, image build, and smoke testing.
