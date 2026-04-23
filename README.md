# ci-workflows

Reusable GitHub Actions workflows shared across [fluence-eu](https://github.com/fluence-eu) Ruby gem projects.

**Scope:** **Ruby gem** projects only (`fluence-gateway-client`, `fluence-gateway-auth`, `mosaic-sdk`). The `gateway` application has a different CI shape and keeps its own workflows.

## Design: one trigger, one workflow run

Each reusable workflow is bound to **a single event type**. Consumers declare matching thin workflow files in their own repo — no `if:` conditions on jobs, no ghost skipped runs in the Actions UI.

| Central workflow | Consumer file | Trigger | Role |
|---|---|---|---|
| `ruby-gem-prepare-release.yml` | `prepare-release.yml` | `workflow_dispatch` | Bump version, regenerate `CHANGELOG.md`, open release PR |
| `ruby-gem-release.yml` | `release.yml` | `push` on the version file | Tag, GitHub Release, build & attach the `.gem` asset |
| `ruby-gem-publish.yml` | `publish.yml` | `release: published` (+ optional `workflow_dispatch`) | Download the `.gem` asset from the release and push it to GitHub Packages |
| `ruby-gem-docs-deploy.yml` | `docs-deploy.yml` | `push main` (+ optional `workflow_dispatch`) | Build YARD site, deploy to GitHub Pages |
| `ruby-gem-docs-pr.yml` | `docs-pr.yml` | `pull_request` | Build YARD + yardstick, diff against main, post sticky PR comment |
| `ruby-gem-coverage-pr.yml` | (called from `main.yml` `coverage` job) | inherited from caller (`pull_request`) | Download coverage artifact, run undercover vs main baseline, post sticky PR comment, fail on regression |

## Pinning: `@v1`

All workflow references below pin to `@v1`. This tag is kept mobile — it points at the latest backward-compatible commit of `main`. Bug fixes are picked up by consumers automatically on the next run. Breaking changes (e.g. removed input) cut a new `@v2` and consumers upgrade explicitly.

Use `@main` only for active central-workflow development, when you want the cutting edge.

## Release flow

```
Operator dispatches "Prepare Release PR"
  └── ruby-gem-prepare-release.yml — opens release/vX.Y.Z PR

Release PR merges → push on version file
  └── ruby-gem-release.yml — tags, creates GitHub Release, attaches .gem

GitHub Release is published (automatic signal from the above)
  └── ruby-gem-publish.yml — downloads the .gem asset, pushes to GitHub Packages
```

Publishing is decoupled from building: the `.gem` file shipped to the registry is literally the one attached to the GitHub Release, so the two sources of truth can't drift. Re-publishing is as simple as re-publishing the GitHub Release, or dispatching `ruby-gem-publish.yml` manually with a `tag`.

## Docs flow

```
Push to main
  └── ruby-gem-docs-deploy.yml — build + deploy to GitHub Pages

Pull request
  └── ruby-gem-docs-pr.yml     — build + yardstick diff + sticky PR comment
```

The yardstick report helper (`yardstick_report.rb`) lives in this repo at `.github/scripts/`. `ruby-gem-docs-pr.yml` fetches it via a sidecar checkout so consumers don't keep a local copy.

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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-prepare-release.yml@v1
    with:
      gem_name: my-gem-name                          # must match `<gem_name>.gemspec`
      version_file: lib/my/gem/version.rb            # file the new version is sed-written to
      bump: ${{ inputs.bump }}
      # ruby_version: '3.2'                          # optional, default '4.0'
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
```

> Secrets are forwarded nominatively (least-privilege). `secrets: inherit` would also work but would expose every secret of the consumer repo to this workflow. Only `RELEASE_APP_PRIVATE_KEY` is required; `GITHUB_TOKEN` is auto-provided in every called workflow.

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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-release.yml@v1
    with:
      gem_name: my-gem-name
      # ruby_version: '3.2'                          # optional, default '4.0'
    permissions:
      contents: write
```

> The release workflow reads the version via `Gem::Specification.load('<gem_name>.gemspec').version` — the same source of truth `gem build` uses. No assumption on the file path, the constant name, or the quote style. Only `gem_name` is needed.

### `.github/workflows/publish.yml`

```yaml
name: Publish Gem

on:
  release:
    types: [published]

jobs:
  publish:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-publish.yml@v1
    with:
      gem_name: my-gem-name
      # ruby_version: '3.2'                          # optional, default '4.0'
    permissions:
      contents: read
      packages: write
```

No `tag` input — the workflow reads it from the `release` event directly.

### `.github/workflows/docs-deploy.yml`

```yaml
name: Docs Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  docs:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-deploy.yml@v1
    with:
      # ruby_version: '3.2'                          # optional, default '4.0'
    permissions:
      contents: read
      pages: write
      id-token: write
```

### Coverage PR comment (`main.yml` coverage job)

Unlike the other flows, coverage needs the build matrix's `coverage` artifact from the SAME workflow run, so it lives inside the consumer's existing `main.yml` as a downstream job rather than in its own file. Keep your build matrix local, and replace the coverage job with a thin delegation:

```yaml
jobs:
  build:
    # ... your project's Ruby/Rails matrix ...
    # last step uploads `coverage` artifact on one Ruby version
    ...

  coverage:
    needs: build
    if: github.event_name == 'pull_request'
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-coverage-pr.yml@v1
    with:
      # ruby_version: '3.2'                          # optional, default '4.0'
      # workflow_file: 'main.yml'                    # optional, default 'main.yml'
    permissions:
      contents: read
      pull-requests: write
      actions: read
```

The central workflow handles: artifact download, undercover run, baseline fetch from main, sticky PR comment, fail-on-regression. The `coverage_report.rb` helper lives centrally in `.github/scripts/` and is fetched via sidecar checkout.

### `.github/workflows/docs-pr.yml`

```yaml
name: Docs PR Check

on:
  pull_request:

jobs:
  docs:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-pr.yml@v1
    with:
      # ruby_version: '3.2'                          # optional, default '4.0'
    permissions:
      contents: read
      pull-requests: write
      actions: read
```

### Manual republish (standalone)

If a release tag already exists with the `.gem` attached but the gem push step failed or was skipped, dispatch `ruby-gem-publish.yml` **directly on this repo**:

1. Go to [Actions → Ruby Gem — Publish to GitHub Packages](https://github.com/fluence-eu/ci-workflows/actions/workflows/ruby-gem-publish.yml).
2. Run workflow with `tag` = `v0.12.0` (for example) and `gem_name` = your gem name.

The workflow downloads the `.gem` asset from that release and pushes it.

### Monorepo note

`gem_name` is always explicit. In a repo that ships multiple gems, declare one `publish.yml` per gem and gate each with a tag pattern:

```yaml
on:
  release:
    types: [published]

jobs:
  publish:
    if: startsWith(github.event.release.tag_name, 'gem-a-')
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-publish.yml@v1
    with:
      gem_name: gem-a
    ...
```

## Required secrets and vars

Each consumer repo must expose:

| Kind | Name | Purpose |
|---|---|---|
| secret | `RELEASE_APP_PRIVATE_KEY` | Private key of the GitHub App that opens release PRs |
| secret | `GITHUB_TOKEN` | Provided automatically by Actions |
| var | `RELEASE_APP_ID` | GitHub App ID |

## Phase 2 (future)

Not yet centralised — variations are still too wide across projects:

- `main.yml` — Ruby matrix. `fluence-gateway-auth` needs an Appraisal+Rails matrix; the others a plain Ruby matrix.
