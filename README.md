# ci-workflows

Reusable GitHub Actions workflows shared across [fluence-eu](https://github.com/fluence-eu) Ruby projects — **gems** (semver release + packages push) and **apps** (rolling release + main mirror).

Workflow families:

| Prefix | Pattern | Used by |
|---|---|---|
| `ruby-gem-*` | Semver bump, `.gemspec` build, attach to GitHub Release, push to GitHub Packages | `fluence-gateway-client`, `fluence-gateway-auth`, `mosaic-sdk` |
| `app-*` | Timestamp tag, git-cliff changelog auto-merged on `develop`, force-push mirror to `main` | `gateway` |
| `rails-*` | Rails-app-specific checks (brakeman, bundler-audit, etc.) | `gateway` |

For contributor guidelines and design principles, see [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## Catalog

### Release

| Central workflow | Consumer file | Trigger | Role |
|---|---|---|---|
| `ruby-gem-prepare-release.yml` | `prepare-release.yml` | `workflow_dispatch` | Bump version, regenerate `CHANGELOG.md`, open release PR |
| `ruby-gem-release.yml` | `release.yml` | `push` on the version file | Tag, GitHub Release, build & attach the `.gem` asset |
| `ruby-gem-publish.yml` | `publish.yml` | `release: published` (+ optional `workflow_dispatch`) | Download the `.gem` asset from the release and push it to GitHub Packages |
| `app-prepare-release.yml` | `prepare-release.yml` | `workflow_dispatch` | Generate timestamp tag, run git-cliff, open + auto-merge release PR |
| `app-release.yml` | `release.yml` | `push` on the working branch + `paths: CHANGELOG.md` | Verify bot author, create tag + GitHub Release, force-push working→released branch |

### Quality gates (docs, coverage, lint, security)

Each gate follows the same **measure + PR** pattern. The `*-measure.yml` reusable produces a baseline artifact on push to the working branch; the `*-pr.yml` reusable re-measures the PR head via nested reusable, downloads the baseline via workflow-runs API, and posts a sticky PR comment comparing the two.

| Central workflow | Consumer file | Trigger | Role |
|---|---|---|---|
| `ruby-gem-docs-measure.yml` | `docs-measure.yml` | `push main` | yardstick measure + verify (soft), upload `yardstick-report` baseline |
| `ruby-gem-docs-pr.yml` | `docs-pr.yml` | `pull_request` | Measure PR head + compare with baseline, sticky comment, fail on threshold miss |
| `ruby-gem-coverage-measure.yml` | `coverage-measure.yml` | `push main` | Run test task, upload `coverage` baseline |
| `ruby-gem-coverage-pr.yml` | `coverage-pr.yml` | `pull_request` | Measure PR head + run undercover vs baseline, sticky comment, fail on regression |
| `ruby-gem-rubocop-measure.yml` | `rubocop-measure.yml` | `push main` | Run rubocop `--format json`, upload `rubocop-report` baseline |
| `ruby-gem-rubocop-pr.yml` | `rubocop-pr.yml` | `pull_request` | Measure PR head + diff offenses vs baseline, sticky comment, fail if any offense |
| `rails-security-measure.yml` | `security-measure.yml` | `push` working branch | Run brakeman + bundler-audit, upload `security-report` baseline (`brakeman.json` + `audit.txt`) |
| `rails-security-pr.yml` | `security-pr.yml` | `pull_request` | Measure PR head + diff vs baseline (brakeman fingerprints + CVE IDs), sticky comment, fail on findings |

### Docs deploy

| Central workflow | Consumer file | Trigger | Role |
|---|---|---|---|
| `ruby-gem-docs-deploy.yml` | `docs-deploy.yml` | `push main` + optional `workflow_dispatch` | Build YARD site, deploy to GitHub Pages |

---

## Pinning: `@v1`

All workflow references pin to `@v1`. This tag is kept mobile — it points at the latest backward-compatible commit of `main`. Bug fixes are picked up by consumers automatically on the next run. Breaking changes (removed input, new required secret, changed semantics) cut `@v2`; see [CONTRIBUTING.md](./CONTRIBUTING.md#versioning) for the rules.

Use `@main` only for active central-workflow development.

---

## Gem release flow

```
Operator dispatches "Prepare Release PR"
  └── ruby-gem-prepare-release.yml — opens release/vX.Y.Z PR

Release PR merges → push on version file
  └── ruby-gem-release.yml — tags, creates GitHub Release, attaches .gem

GitHub Release is published (automatic signal from the above)
  └── ruby-gem-publish.yml — downloads the .gem asset, pushes to GitHub Packages
```

Publishing is decoupled from building: the `.gem` shipped to the registry is literally the file attached to the GitHub Release, so the two sources of truth can't drift. Re-publishing is as simple as re-publishing the GitHub Release, or dispatching `ruby-gem-publish.yml` manually with a `tag`.

## App release flow

```
Operator dispatches "Prepare Release PR"
  └── app-prepare-release.yml
        ├── Generate timestamp tag (vYYYY.MM.DD.HHMMSS)
        ├── git-cliff --unreleased --prepend CHANGELOG.md
        └── Create release/vX PR on develop, auto-merge (squash)

Auto-merge lands "release: vX" commit on develop, touching CHANGELOG.md
  └── app-release.yml (triggered by paths: CHANGELOG.md)
        ├── Verify commit author is the release bot
        ├── Extract tag from commit message
        ├── Create tag + GitHub Release (release notes from CHANGELOG section)
        └── Force-push develop → main (main mirrors the released snapshot)
```

The `main` branch is treated as a read-only mirror. Direct commits to it are overwritten on the next release.

## Docs flow

```
Push to main
  ├── ruby-gem-docs-deploy.yml  — build + deploy YARD to GitHub Pages
  └── ruby-gem-docs-measure.yml — upload yardstick-report baseline

Pull request
  └── ruby-gem-docs-pr.yml      — re-measure PR head + sticky comment with diff
```

## Coverage flow

```
Push to main
  └── ruby-gem-coverage-measure.yml — run tests, upload coverage baseline

Pull request
  └── ruby-gem-coverage-pr.yml      — re-measure PR head + undercover diff + sticky comment
```

## RuboCop flow

```
Push to main
  └── ruby-gem-rubocop-measure.yml  — run rubocop --format json, upload baseline

Pull request
  └── ruby-gem-rubocop-pr.yml       — re-measure PR head + offenses diff + sticky comment
```

Helper scripts (`coverage_report.rb`, `yardstick_report.rb`, `rubocop_report.rb`) are wrapped as **composite actions** under `actions/{name}-report/`. The PR workflows call them via `uses: fluence-eu/ci-workflows/actions/{name}-report@v1` — no sidecar checkout, no additional GitHub App.

---

## Consumer templates

### Ruby gem

The three release-side thin callers:

```yaml
# .github/workflows/prepare-release.yml
name: Prepare Release PR

on:
  workflow_dispatch:
    inputs:
      bump:
        description: Version bump type
        required: true
        type: choice
        options: [patch, minor, major]

jobs:
  prepare:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-prepare-release.yml@v1
    with:
      gem_name: my-gem-name                 # must match <gem_name>.gemspec
      version_file: lib/my/gem/version.rb
      bump: ${{ inputs.bump }}
      # ruby_version: '3.2'                 # optional, default '4.0'
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
```

```yaml
# .github/workflows/release.yml
name: Release

on:
  # Only fires on pushes that touch the version file — i.e. when the
  # release PR merges. Feature merges don't match, no ghost runs.
  push:
    branches: [main]
    paths:
      - lib/my/gem/version.rb

jobs:
  release:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-release.yml@v1
    with:
      gem_name: my-gem-name
    permissions:
      contents: write
```

```yaml
# .github/workflows/publish.yml
name: Publish Gem

on:
  release:
    types: [published]

jobs:
  publish:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-publish.yml@v1
    with:
      gem_name: my-gem-name
    permissions:
      contents: read
      packages: write
```

The release workflow reads the version via `Gem::Specification.load('<gem_name>.gemspec').version` — same source of truth `gem build` uses. Only `gem_name` is required.

The publish workflow reads the tag from the `release` event directly — no `tag` input.

### Rolling-release app

Two thin callers, one per trigger:

```yaml
# .github/workflows/prepare-release.yml
name: Prepare Release PR

on:
  workflow_dispatch:

jobs:
  prepare:
    uses: fluence-eu/ci-workflows/.github/workflows/app-prepare-release.yml@v1
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
```

```yaml
# .github/workflows/release.yml
name: Release

on:
  # Only fires on pushes that touch CHANGELOG.md — i.e. when the
  # auto-merged release PR lands on develop. No ghost runs.
  push:
    branches: [develop]
    paths:
      - CHANGELOG.md

jobs:
  release:
    uses: fluence-eu/ci-workflows/.github/workflows/app-release.yml@v1
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: write
```

Optional inputs if your repo uses different branch names:

```yaml
with:
  develop_branch: 'main'     # default: 'develop'
  main_branch:    'release'  # default: 'main'  (app-release.yml only)
  tag_format:     '%Y%m%d'   # default: '%Y.%m.%d.%H%M%S'  (app-prepare-release.yml only)
```

### Docs

```yaml
# .github/workflows/docs-deploy.yml
name: Docs Deploy
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  docs:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-deploy.yml@v1
    with:
      # ruby_version: '3.2'                 # optional, default '4.0'
    permissions:
      contents: read
      pages: write
      id-token: write
```

```yaml
# .github/workflows/docs-measure.yml
name: Docs Measure (baseline)
on:
  push:
    branches: [main]
jobs:
  measure:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-measure.yml@v1
    permissions:
      contents: read
```

```yaml
# .github/workflows/docs-pr.yml
name: Docs PR Check
on:
  pull_request:
jobs:
  docs:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-pr.yml@v1
    permissions:
      contents: read
      pull-requests: write
      actions: read
```

### Coverage

```yaml
# .github/workflows/coverage-measure.yml
name: Coverage Measure (baseline)
on:
  push:
    branches: [main]
jobs:
  measure:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-coverage-measure.yml@v1
    # with:
    #   rake_task: 'test'                   # default 'spec' — override for minitest projects
    permissions:
      contents: read
```

```yaml
# .github/workflows/coverage-pr.yml
name: Coverage PR Check
on:
  pull_request:
jobs:
  coverage:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-coverage-pr.yml@v1
    # with:
    #   rake_task:     'test'
    #   exclude_files: 'lib/my/gem/version.rb'  # undercover --exclude-files glob
    permissions:
      contents: read
      pull-requests: write
      actions: read
```

### RuboCop

```yaml
# .github/workflows/rubocop-measure.yml
name: RuboCop Measure (baseline)
on:
  push:
    branches: [main]
jobs:
  measure:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-rubocop-measure.yml@v1
    permissions:
      contents: read
```

```yaml
# .github/workflows/rubocop-pr.yml
name: RuboCop PR Check
on:
  pull_request:
jobs:
  rubocop:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-rubocop-pr.yml@v1
    permissions:
      contents: read
      pull-requests: write
      actions: read
```

---

## Required repo config

Each consumer repo must expose:

| Kind | Name | Used by |
|---|---|---|
| var | `RELEASE_APP_ID` | `ruby-gem-prepare-release.yml`, `app-prepare-release.yml`, `app-release.yml` |
| secret | `RELEASE_APP_PRIVATE_KEY` | same |

`GITHUB_TOKEN` is auto-provided by Actions — never declared in `secrets:`.

`RELEASE_APP_*` is the write-capable app that opens release PRs, tags releases, and force-pushes mirrors. No second GitHub App is required — PR workflows pull their helper scripts via composite actions (`actions/*-report/`) which inherit the org's Actions access level.

---

## Manual republish

If a release tag already exists with the `.gem` attached but the package push step failed or was skipped, dispatch `ruby-gem-publish.yml` **directly on this repo**:

1. Go to [Actions → Ruby Gem — Publish to GitHub Packages](https://github.com/fluence-eu/ci-workflows/actions/workflows/ruby-gem-publish.yml)
2. Run workflow with `tag` = `v0.12.0` (for example) and `gem_name` = your gem name

The workflow downloads the `.gem` asset from that release and pushes it.

## Monorepo note

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
