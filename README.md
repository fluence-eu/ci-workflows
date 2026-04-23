# ci-workflows

Reusable GitHub Actions workflows shared across [fluence-eu](https://github.com/fluence-eu) Ruby gem projects.

**Scope:** **Ruby gem** projects only (`fluence-gateway-client`, `fluence-gateway-auth`, `mosaic-sdk`). The `gateway` application has a different CI shape and keeps its own workflows.

## Design: one trigger, one workflow run

The release flow is split into **two separate reusable workflows**, each bound to a single event type. Consumers declare two matching workflow files in their own repo — **no job conditions, no ghost skipped runs** in the Actions UI.

| Central workflow | Called by consumer workflow | Trigger |
|---|---|---|
| `ruby-gem-prepare-release.yml` | `.github/workflows/prepare-release.yml` | `workflow_dispatch` |
| `ruby-gem-release.yml` | `.github/workflows/release.yml` | `push` on version file |
| `ruby-gem-publish.yml` *(standalone)* | — | `workflow_dispatch` on this repo (manual republish) |

Flow:

```
Operator dispatches "Prepare Release PR"
  └── ruby-gem-prepare-release.yml
      • bump version
      • regenerate CHANGELOG.md via git-cliff
      • open release/vX.Y.Z PR

Release PR merges to main (touches version file)
  └── ruby-gem-release.yml (single job: Release)
      • read version from version file
      • create git tag
      • create GitHub release with extracted changelog
      • build gem
      • push to GitHub Packages
      • attach gem to release
```

## Consumer usage

### `.github/workflows/prepare-release.yml`

```yaml
name: Prepare Release PR

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

jobs:
  prepare:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-prepare-release.yml@main
    with:
      gem_name: my-gem-name                          # must match `<gem_name>.gemspec`
      version_file: lib/my/gem/version.rb            # file containing `VERSION = '...'`
      bump: ${{ inputs.bump }}
    secrets: inherit
    permissions:
      contents: read
```

### `.github/workflows/release.yml`

```yaml
name: Release

on:
  # Only fires on pushes that touch the version file — i.e. when the
  # release PR merges. No trigger, no run, no Actions UI noise.
  push:
    branches: [main]
    paths:
      - lib/my/gem/version.rb

jobs:
  release:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-release.yml@main
    with:
      gem_name: my-gem-name
    secrets: inherit
    permissions:
      contents: write
      packages: write
```

> The release workflow reads the version via `Gem::Specification.load('<gem_name>.gemspec').version` — the same source of truth `gem build` uses. No assumption on the file path, the constant name, or the quote style. Only `gem_name` is needed.

### Manual republish (standalone)

If a release tag exists but the gem push failed or was skipped, dispatch `ruby-gem-publish.yml` **directly on this repo**:

1. Go to [Actions → Ruby Gem — Publish to GitHub Packages](https://github.com/fluence-eu/ci-workflows/actions/workflows/ruby-gem-publish.yml).
2. Run workflow with `tag` = `v0.12.0` (for example) and `gem_name` = your gem name.

## Required secrets and vars

Each consumer repo must expose:

| Kind | Name | Purpose |
|---|---|---|
| secret | `RELEASE_APP_PRIVATE_KEY` | Private key of the GitHub App that opens release PRs |
| secret | `GITHUB_TOKEN` | Provided automatically by Actions |
| var | `RELEASE_APP_ID` | GitHub App ID |

## Pinning policy

Examples pin to `@main`. For stricter control, pin to a tag once a `v1` tag of this repo exists (e.g. `@v1`). Main is kept stable on purpose — breaking changes go on `v2/`, `v3/`… branches.

## Phase 2 (future)

Not yet centralised — variations are still too wide across projects:

- `main.yml` — Ruby matrix. `fluence-gateway-auth` needs an Appraisal+Rails matrix; the others a plain Ruby matrix.
- `docs.yml` — YARD + yardstick. Differs on `ruby-version` and upload-pages action versions.
