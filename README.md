# ci-workflows

Reusable GitHub Actions workflows shared across [fluence-eu](https://github.com/fluence-eu) Ruby gem projects.

**Scope:** **Ruby gem** projects only (`fluence-gateway-client`, `fluence-gateway-auth`, `mosaic-sdk`). The `gateway` application has a different CI shape and keeps its own workflows.

## Phase 1: release pipeline

Three chained workflows handle the entire release flow. Consumers call only the top-level `ruby-gem-release.yml`; it chains to the other two.

```
ruby-gem-release.yml         ← consumer entry point
├── prepare (on dispatch)    ← bump version, generate changelog, open release PR
├── tag (on push to main)    ← detect release merge, create git tag
└── publish (on tag)
    └── ruby-gem-github-release.yml   ← create GitHub release, extract changelog
        └── ruby-gem-publish.yml      ← build gem, push to GitHub Packages, attach asset
```

## Usage

In each consumer repo, replace the entire `release.yml` + `github-release.yml` + `publish.yml` trio with a single thin file:

### `.github/workflows/release.yml`

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      bump:
        description: Version bump type
        required: true
        type: choice
        options:
          - patch
          - minor
          - major
  # Only trigger on pushes that touch the version file. Without this
  # paths filter, the workflow fires on every merge to main and shows
  # in the Actions UI with all jobs skipped for non-release commits.
  push:
    branches: [main]
    paths:
      - lib/my/gem/version.rb

jobs:
  release:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-release.yml@main
    with:
      gem_name: my-gem-name                               # must match `<gem_name>.gemspec`
      version_file: lib/my/gem/version.rb                 # path to file with `VERSION = '...'`
      bump: ${{ inputs.bump }}
    secrets: inherit
    permissions:
      contents: write
      packages: write
```

### Standalone manual republish

If a release was created but the gem push was skipped or failed, dispatch `ruby-gem-publish.yml` **directly from this repo** (not the consumer):

1. Go to [Actions → Ruby Gem — Publish to GitHub Packages](https://github.com/fluence-eu/ci-workflows/actions/workflows/ruby-gem-publish.yml) on this repo.
2. Run workflow with `tag` = `v0.12.0` (for instance) and `gem_name` = `fluence-gateway-client`.

## Required secrets and vars

Each consumer repo must expose:

| Kind | Name | Purpose |
|---|---|---|
| secret | `RELEASE_APP_PRIVATE_KEY` | Private key of the GitHub App that opens release PRs |
| secret | `GITHUB_TOKEN` | Provided automatically by Actions |
| var | `RELEASE_APP_ID` | GitHub App ID |

## Pinning policy

The examples above pin to `@main`. For stricter control, pin to a tag once a `v1` release of this repo exists (e.g. `@v1`). Main is stable on purpose — breaking changes go on `v2/`, `v3/`… branches.

## Phase 2 (future)

Not yet centralised (variations are still too wide across projects):

- `main.yml` — Ruby matrix. `fluence-gateway-auth` needs an Appraisal+Rails matrix; the others a plain Ruby matrix.
- `docs.yml` — YARD + yardstick. Differs on `ruby-version` and upload-pages action versions.
