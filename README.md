# ci-workflows

Reusable GitHub Actions workflows shared across [fluence-eu](https://github.com/fluence-eu) Ruby projects — **gems** (semver release + packages push) and **apps** (rolling release + main mirror).

Workflow families:

| Prefix | Pattern | Used by |
|---|---|---|
| `ruby-gem-*` | Semver bump, `.gemspec` build, attach to GitHub Release, push to GitHub Packages | `fluence-gateway-client`, `fluence-gateway-auth`, `mosaic-sdk` |
| `app-*` | Timestamp tag, git-cliff changelog auto-merged on `develop`, force-push mirror to `main` | `gateway` |
| `rails-*` | Rails-app-specific checks (brakeman, bundler-audit, etc.) | `gateway` |
| `claude-*` | Language-agnostic AI gates backed by `anthropics/claude-code-action` against a Pro/Max OAuth token | (any consumer) |

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

### Quality gates (docs, coverage, lint, security, codequality)

Each gate follows the same **measure + PR** pattern. The `*-measure.yml` reusable produces a baseline artifact on push to the working branch; the `*-pr.yml` reusable re-measures the PR head via nested reusable, downloads the baseline via workflow-runs API, and posts a sticky PR comment comparing the two.

Most gates are **strict** — the PR fails when findings are introduced. The codequality gate is **advisory** — reek / flog / flay are surfaced as deltas and trends, no fail.

| Central workflow | Consumer file | Trigger | Mode | Role |
|---|---|---|---|---|
| `ruby-gem-docs-measure.yml` | `docs-measure.yml` | `push main` | strict | yardstick measure + verify (soft), upload `yardstick-report` baseline |
| `ruby-gem-docs-pr.yml` | `docs-pr.yml` | `pull_request` | strict | Measure PR head + compare with baseline, sticky comment, fail on threshold miss |
| `ruby-gem-coverage-measure.yml` | `coverage-measure.yml` | `push main` | strict | Run test task, upload `coverage` baseline |
| `ruby-gem-coverage-pr.yml` | `coverage-pr.yml` | `pull_request` | strict | Measure PR head + run undercover vs baseline, sticky comment, fail on regression |
| `ruby-gem-rubocop-measure.yml` | `rubocop-measure.yml` | `push main` | strict | Run rubocop `--format json`, upload `rubocop-report` baseline |
| `ruby-gem-rubocop-pr.yml` | `rubocop-pr.yml` | `pull_request` | strict | Measure PR head + diff offenses vs baseline, sticky comment, fail if any offense |
| `rails-security-measure.yml` | `security-measure.yml` | `push` working branch | strict | Run brakeman + bundler-audit + ruby-audit, upload `security-report` baseline (`brakeman.json` + `audit.txt` + `ruby_audit.txt`) |
| `rails-security-pr.yml` | `security-pr.yml` | `pull_request` | strict | Measure PR head + diff vs baseline (brakeman fingerprints + CVE IDs; ruby-audit outcome-only, no diff), sticky comment, fail on findings |
| `ruby-gem-codequality-measure.yml` | `codequality-measure.yml` | `push main` | advisory | Run reek + flog + flay, upload `codequality-report` baseline (`reek.json` + `flog.txt` + `flay.txt`) |
| `ruby-gem-codequality-pr.yml` | `codequality-pr.yml` | `pull_request` | advisory | Measure PR head + diff vs baseline (reek smells + flog/flay scores), sticky comment, **never fails** |

### AI review (Claude)

Language-agnostic. Auth flows through `CLAUDE_CODE_OAUTH_TOKEN` (generated locally via `claude setup-token`), so runs bill against a Claude Pro/Max subscription instead of metered API credits. Release PRs (head_ref `release/v*` authored by the release App) are skipped when `RELEASE_APP_PRIVATE_KEY` is forwarded.

| Central workflow | Consumer file | Trigger | Mode | Role |
|---|---|---|---|---|
| `claude-review-pr.yml` | `claude-review-pr.yml` | `pull_request` | advisory | Sticky summary + inline review comments via `anthropics/claude-code-action@v1`. Never fails the PR — Claude is one reviewer among others, not a gate. |

Minimal consumer:

```yaml
name: Claude review

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read

jobs:
  review:
    uses: fluence-eu/ci-workflows/.github/workflows/claude-review-pr.yml@v3
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}  # optional — skips release PRs
```

### Docs deploy

| Central workflow | Consumer file | Trigger | Role |
|---|---|---|---|
| `ruby-gem-docs-deploy.yml` | `docs-deploy.yml` | `push main` + optional `workflow_dispatch` | Build YARD site, deploy to GitHub Pages |

---

## Pinning: `@v3`

All workflow references pin to the current major (`@v3` as of writing — `v1` and `v2` are frozen at their last commits). The active major tag is kept mobile: it points at the latest backward-compatible commit of `main`. Bug fixes are picked up by consumers automatically on the next run. Breaking changes (removed input, new required secret, changed semantics) cut a new major (next would be `@v4`); see [CONTRIBUTING.md](./CONTRIBUTING.md#versioning) for the rules.

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

Helper scripts (`coverage_report.rb`, `yardstick_report.rb`, `rubocop_report.rb`) are wrapped as **composite actions** under `actions/{name}-report/`. The PR workflows call them via `uses: fluence-eu/ci-workflows/actions/{name}-report@v3` — no sidecar checkout, no additional GitHub App.

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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-prepare-release.yml@v3
    with:
      gem_name: my-gem-name                 # must match <gem_name>.gemspec
      version_file: lib/my/gem/version.rb
      bump: ${{ inputs.bump }}
      # ruby_version: '3.2'                 # optional, default '4.0'
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
      packages: read
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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-release.yml@v3
    with:
      gem_name: my-gem-name
    secrets:
      # Forwarded so `gh release create` runs with the App's installation
      # token. App-issued release events trigger downstream `publish.yml` —
      # `secrets.GITHUB_TOKEN` does not (GitHub anti-loop rule).
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: write
      packages: read
```

```yaml
# .github/workflows/publish.yml
name: Publish Gem

on:
  release:
    types: [published]

jobs:
  publish:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-publish.yml@v3
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
    uses: fluence-eu/ci-workflows/.github/workflows/app-prepare-release.yml@v3
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
      packages: read
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
    uses: fluence-eu/ci-workflows/.github/workflows/app-release.yml@v3
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: write
      packages: read
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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-deploy.yml@v3
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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-measure.yml@v3
    permissions:
      contents: read
      packages: read
```

```yaml
# .github/workflows/docs-pr.yml
name: Docs PR Check
on:
  pull_request:
jobs:
  docs:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-pr.yml@v3
    secrets:
      FLUENCE_CI_BOT_PRIVATE_KEY: ${{ secrets.FLUENCE_CI_BOT_PRIVATE_KEY }}
      RELEASE_APP_PRIVATE_KEY:    ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
      pull-requests: write
      actions: read
      packages: read
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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-coverage-measure.yml@v3
    # with:
    #   rake_task: 'test'                   # default 'spec' — override for minitest projects
    permissions:
      contents: read
      packages: read
```

```yaml
# .github/workflows/coverage-pr.yml
name: Coverage PR Check
on:
  pull_request:
jobs:
  coverage:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-coverage-pr.yml@v3
    # with:
    #   rake_task:     'test'
    #   exclude_files: 'lib/my/gem/version.rb'  # undercover --exclude-files glob
    secrets:
      FLUENCE_CI_BOT_PRIVATE_KEY: ${{ secrets.FLUENCE_CI_BOT_PRIVATE_KEY }}
      RELEASE_APP_PRIVATE_KEY:    ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
      pull-requests: write
      actions: read
      packages: read
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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-rubocop-measure.yml@v3
    permissions:
      contents: read
      packages: read
```

```yaml
# .github/workflows/rubocop-pr.yml
name: RuboCop PR Check
on:
  pull_request:
jobs:
  rubocop:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-rubocop-pr.yml@v3
    secrets:
      FLUENCE_CI_BOT_PRIVATE_KEY: ${{ secrets.FLUENCE_CI_BOT_PRIVATE_KEY }}
      RELEASE_APP_PRIVATE_KEY:    ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
      pull-requests: write
      actions: read
      packages: read
```

### Code Quality

```yaml
# .github/workflows/codequality-measure.yml
name: Code Quality Measure (baseline)
on:
  push:
    branches: [main]
jobs:
  measure:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-codequality-measure.yml@v3
    with:
      paths: 'app lib'                       # default 'lib'
    permissions:
      contents: read
      packages: read
```

```yaml
# .github/workflows/codequality-pr.yml
name: Code Quality PR Check
on:
  pull_request:
jobs:
  codequality:
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-codequality-pr.yml@v3
    with:
      paths: 'app lib'
    secrets:
      FLUENCE_CI_BOT_PRIVATE_KEY: ${{ secrets.FLUENCE_CI_BOT_PRIVATE_KEY }}
      RELEASE_APP_PRIVATE_KEY:    ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
      pull-requests: write
      actions: read
      packages: read
```

### Security (Rails)

```yaml
# .github/workflows/security-measure.yml
name: Security Measure (baseline)
on:
  push:
    branches: [main]
jobs:
  measure:
    uses: fluence-eu/ci-workflows/.github/workflows/rails-security-measure.yml@v3
    permissions:
      contents: read
      packages: read
```

```yaml
# .github/workflows/security-pr.yml
name: Security PR Check
on:
  pull_request:
jobs:
  security:
    uses: fluence-eu/ci-workflows/.github/workflows/rails-security-pr.yml@v3
    secrets:
      FLUENCE_CI_BOT_PRIVATE_KEY: ${{ secrets.FLUENCE_CI_BOT_PRIVATE_KEY }}
      RELEASE_APP_PRIVATE_KEY:    ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
    permissions:
      contents: read
      pull-requests: write
      actions: read
      packages: read
```

---

## Required repo config

### GitHub App credentials

| Kind | Name | Used by |
|---|---|---|
| var | `RELEASE_CLIENT_ID` | `ruby-gem-prepare-release.yml`, `app-prepare-release.yml`, `app-release.yml`, all `*-pr.yml` reusables (skip-on-release-PR detection) |
| secret | `RELEASE_APP_PRIVATE_KEY` | same |
| var | `FLUENCE_CI_CLIENT_ID` | `*-pr.yml` reusables (sticky-comment author) |
| secret | `FLUENCE_CI_BOT_PRIVATE_KEY` | same |

`GITHUB_TOKEN` is auto-provided by Actions — never declared in `secrets:`.

`RELEASE_APP_*` is the write-capable app that opens release PRs, tags releases, and force-pushes mirrors. `FLUENCE_CI_BOT_*` is the read-only app that authors sticky PR comments so they show up as a verified bot rather than `github-actions[bot]`.

All four entries above are configured at the **`fluence-eu` organisation level** and automatically inherited by every repo in the org — a new consumer in `fluence-eu` does **not** need to copy them into its own Secrets / Variables. Repos outside the org must declare them per-repo.

### Gemfile dependency

PR-side reusables (`ruby-gem-rubocop-pr`, `ruby-gem-coverage-pr`, `ruby-gem-codequality-pr`, `rails-security-pr`, `ruby-gem-docs-pr`) and their `*-measure` counterparts run `bundle install` then invoke `rubocop`, `reek`, `flog`, `flay`, `brakeman`, `bundler-audit`, `ruby_audit`, `yard`, `yardstick`, `simplecov`, `undercover`. The consumer repo must therefore ship those tools in its bundle.

Add the [`fluence-ci-tools`](https://github.com/fluence-eu/fluence-ci-tools) meta-gem to the `Gemfile`:

```ruby
source 'https://rubygems.pkg.github.com/fluence-eu' do
  gem 'fluence-ci-tools', require: false
end
```

It pulls in all the tools above with the version pins the centralised workflows expect. Bumping a tool is `bundle update fluence-ci-tools`.

Because `fluence-ci-tools` lives on GitHub Packages (private), each consumer workflow that runs `bundle install` must:

- Grant `packages: read` on the calling job's `permissions:` block.
- Set `BUNDLE_RUBYGEMS__PKG__GITHUB__COM: ${{ github.actor }}:${{ secrets.GITHUB_TOKEN }}` as workflow-level env so Bundler can authenticate against the registry.
- **Be allow-listed on the package itself.** Per-package access is not org-inherited — open each private package's settings (e.g. https://github.com/orgs/fluence-eu/packages/rubygems/package/fluence-ci-tools/settings) → **Manage Actions access** → **Add repository** → select the new consumer repo → Role: **Read**. Repeat for every entry inside the `source 'https://rubygems.pkg.github.com/fluence-eu' do … end` block of the Gemfile (`mosaic-sdk`, `money-fluence-exchange`, `fluence-gateway-auth`, …). Without this, `bundle install` fails with `authentication is required` even when `packages: read` and the `BUNDLE_…` env var are set correctly.

The reusables in this repo already declare `packages: read` at the workflow level — consumers just need to forward the permission via their wrapper (see the templates above).

### Local CI orchestration (optional)

Since v0.3.0, `fluence-ci-tools` also ships a Rails generator and a `fluence-ci` CLI that scaffold a local `bin/ci` orchestration mirroring this catalog of reusables. Useful for devs who want to run the same checks pre-push without waiting for CI.

**Rails app** — generator integrated with Rails 8's native `bin/ci` (`ActiveSupport::ContinuousIntegration`):
```bash
bin/rails generate fluence_ci:install   # injects extend + all() into config/ci.rb
bin/ci                                    # runs Rails defaults + Fluence catalog
```

**Pure gem** — Thor CLI generates a Rake task:
```bash
bundle exec fluence-ci install            # writes lib/tasks/fluence_ci.rake
bundle exec rake fluence_ci:check         # runs the whole catalog
bundle exec rake fluence_ci:codequality   # or any single group
```

The generator's injected `all` call uses dynamic dispatch over `Fluence::Ci::Tools::Steps` — when the gem ships a new step group (e.g. `accessibility`), consumers pick it up via `bundle update fluence-ci-tools` without editing their `config/ci.rb` or rake task. Per-group args are overridable: `all(codequality: { paths: 'custom' })`.

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
    uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-publish.yml@v3
    with:
      gem_name: gem-a
    ...
```
