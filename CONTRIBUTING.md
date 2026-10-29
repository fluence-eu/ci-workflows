# Contributing

Thanks for contributing! This repo hosts reusable GitHub Actions workflows shared across [fluence-eu](https://github.com/fluence-eu) projects. Every change is consumed automatically by those repos once the active major tag (`@v7`) moves, so small mistakes have a wide blast radius.

**Direct push to `main` is forbidden.** All changes — including doc updates and one-line fixes — go through a pull request. The active major tag (`@v7`) is moved by the maintainer who merges the PR, so any drift between `main` and the active major reflects an explicit decision (e.g. cutting the next major).

Standard flow:

1. Open an issue to discuss the proposed change (skip for trivial doc fixes)
2. Create a branch from `main` — naming convention: `<type>/<short-description>` (e.g. `feat/cache-rubocop-yard`, `fix/docs-pr-secret`, `refactor/extract-app-actions`, `chore/contributing`, `docs/update-readme`)
3. Implement the change
4. Test it end-to-end from a consumer PR (see "Testing changes" below)
5. Open a pull request targeting `main`
6. After merge — move the active major tag (`@v7`) to the new main HEAD if the change is non-breaking (see "Versioning" below)

---

## Repo layout

```
.github/
  workflows/
    ruby-gem-*.yml           # Ruby gem pipeline (semver, build + package push)
    app-*.yml                # Rolling-release app pipeline (timestamp tag + mirror)
    rails-*.yml              # Rails-app-specific checks (brakeman, bundler-audit, …)
actions/
  coverage-report/           # Composite actions wrapping Ruby helper scripts
  yardstick-report/          # (action.yml + the .rb script next to it)
  rubocop-report/
  post-sticky-comment/       # Generic sticky-comment poster, dual-mode
                             # (App-authored when secret forwarded, else github-actions[bot])
README.md                    # Consumer-facing usage docs
CONTRIBUTING.md              # This file
```

Family prefixes:
- `ruby-gem-*` — semver-released Ruby gems with `.gemspec` + GitHub Packages push.
- `app-*` — rolling-release apps (any language): timestamp tag, changelog auto-merged on `develop`, force-push mirror to `main`.
- `rails-*` — Rails-app-specific checks (security scan, future test/coverage variants with postgres, etc.). Use this prefix only for reusables that genuinely need Rails (not just Ruby).

If you need a new family, coordinate on the issue first — consumers already pin `@v7` across all three.

---

## Design principles

These aren't optional; breaking them breaks consumers.

### 1. One event per workflow file

Each reusable targets exactly one trigger context in its consumer. No `if:` guards at the job level, no mixed dispatch+push+release jobs. Consumers use **paths filter** on push triggers rather than post-hoc skips — zero ghost "skipped" runs in the Actions UI.

If you catch yourself writing `if: github.event_name == 'X'` inside a job, split the workflow into two files instead.

### 2. Secrets forwarded nominatively

Never use `secrets: inherit` in the reusable declaration. Consumers forward only the secrets each reusable actually declares as `required: true`. Current consumer secrets:

| Secret | Required by |
|---|---|
| `FLUENCE_RELEASE_BOT_PRIVATE_KEY` | `ruby-gem-prepare-release.yml`, `app-prepare-release.yml`, `app-release.yml`, `claude-review-specialists.yml` |
| `FLUENCE_CI_BOT_PRIVATE_KEY` | `ruby-gem-docs-pr.yml`, `ruby-gem-coverage-pr.yml`, `ruby-gem-rubocop-pr.yml` |
| `FLUENCE_DEPS_BOT_PRIVATE_KEY` | `rails-deps-bump.yml`, `ruby-gem-deps-bump.yml`, `vue-app-deps-bump.yml`, `npm-deps-bump.yml`, `deps-merge.yml` |
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude-review-pr.yml`, `claude-review-specialists.yml`, `rails-deps-bump.yml`, `ruby-gem-deps-bump.yml`, `vue-app-deps-bump.yml`, `npm-deps-bump.yml` |

Add a `secrets:` block to your reusable only for secrets you actually consume, and document what they do. `GITHUB_TOKEN` is auto-provided — don't declare it.

### 3. Least-privilege permissions

Declare the minimum at the job level. Top-level workflow `permissions: contents: read` is the default, override per job for `contents: write`, `pull-requests: write`, `pages: write`, `packages: write`, `id-token: write`, `actions: read` as needed.

Any permission you declare must be granted by the caller — mismatches cause `startup_failure` on nested reusable calls.

### 4. Injection-safe shell

Never interpolate `github.event.*`, `github.head_ref`, commit messages, PR titles, or any other user-controllable input directly into `run:` blocks. Pass through `env:` instead:

```yaml
# Wrong — commit message expanded into the shell command line
- run: |
    TAG=$(echo "${{ github.event.head_commit.message }}" | grep -oE 'v[0-9.]+')

# Right — value stays in env, shell reads it from there
- env:
    MSG: ${{ github.event.head_commit.message }}
  run: |
    TAG=$(printf '%s' "$MSG" | grep -oE 'v[0-9.]+')
```

This protects against crafted commit messages that would otherwise be able to execute arbitrary shell.

### 5. Don't name well-known actions

GitHub auto-generates nice step display names from each action's `action.yml` metadata (`actions/checkout@v7` → "Checkout", `ruby/setup-ruby@v1` → "Setup Ruby"). Adding `name: Checkout code` on such steps is noise — skip it unless the name adds information:

- Disambig (e.g. `Checkout consumer repo` vs `Checkout ci-workflows`)
- Qualifying context (e.g. `Generate CI bot token (read-only access to ci-workflows)`)
- Run scripts (no auto-name exists)

### 6. Per-project options come from `.fluence-ci.yml`

`workflow_call` inputs are reserved for **runtime values** (`bump` from a dispatch choice, `tag` from a release event) and **internal wiring** (`measure_workflow_file`). Anything that varies per project — Ruby/Node versions, tool commands, gem/package specs, branch names — is read from the consumer's `.fluence-ci.yml` via the `actions/read-config` composite action, right after the consumer checkout.

This keeps consumer wrapper files byte-identical across the repos of a family. Adding an input that carries a per-project value is a design smell: add a config key instead, with the old default. The full key schema lives in [README.md](./README.md#per-project-configuration-fluence-ciyml).

### 7. Helper scripts via composite actions

Ruby helpers (`coverage_report.rb`, `yardstick_report.rb`, `rubocop_report.rb`) are wrapped as composite actions under `actions/{name}-report/`. Each composite action declares its inputs, calls the Ruby script via `${GITHUB_ACTION_PATH}`, and exposes the Markdown body as an output. The reusable PR workflows consume them via `uses: fluence-eu/ci-workflows/actions/{name}-report@v7` — no sidecar checkout, no dedicated GitHub App.

When you add a helper:
- Create `actions/<name>-report/` with an `action.yml` (declare inputs + `outputs.body.value`) and the Ruby script next to it
- `action.yml` runs `ruby "${GITHUB_ACTION_PATH}/<name>_report.rb" "$ARG1" ...` inside a composite step, passes args through `env:` (never inline `${{ inputs.x }}` in the shell command — see #4)
- Make the script resilient to partial inputs (`rescue` / nil-guard missing artifacts — the baseline may be absent on the very first run)
- Reference the composite action from the consuming reusable PR workflow

---

## Versioning

### Active major tag is mobile

The current major tag (`v7` as of writing — `v1` through `v6` are frozen at their last commits) is force-moved to every new commit on `main`. Consumers pin the active major and pick up non-breaking changes automatically. **The maintainer merging a PR is responsible for moving the tag** — the move is an explicit step that gates the change reaching consumers.

Two ways to do it:

**From the GitHub UI** (preferred):
1. Open *Actions* → *Move major tag* → *Run workflow*.
2. Pass the major tag (`v7` to fast-forward, `v8` to cut the next major) and leave `ref` empty to point at main HEAD.

**Locally**:
```bash
git fetch origin main
git checkout main && git pull
git tag -f v7                # current major
git push origin v7 --force
```

If your PR contains a breaking change (see below), do not move the current major — cut the next one (`v8`) instead.

### What counts as breaking

Cut a new major (and leave the previous one frozen at the last non-breaking commit) when:
- You rename or remove an input
- You require a new `secrets:` entry consumers weren't already forwarding
- You change the semantics of an existing input
- You remove an output downstream jobs might rely on

**Not breaking** (safe to fast-forward the current major):
- Adding a new input with a default
- Adding a new output
- Adding a new step that doesn't change the contract
- Bug fixes, performance improvements, comment cleanups
- Adding a new workflow file

When in doubt, cut a new major. Rollback costs more than a tag.

### Pinning in a consumer PR during development

Temporarily pin consumers to a branch while iterating:

```yaml
uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-pr.yml@refactor/my-branch
```

Move back to `@v7` before merging either side.

---

## Testing changes

This repo has no self-contained test suite — the contract is the consumer pipelines. Validate in order:

1. **Static check.** Ensure the YAML parses and `name:`/`uses:`/`with:` fields are consistent. Preview the rendered workflow:

   ```bash
   gh workflow view <workflow>.yml --yaml --ref <your-branch>
   ```

2. **Consumer PR with branch pin.** Open a throw-away branch on one consumer repo, point the relevant `uses:` at your ci-workflows branch, push, and watch the CI run. Expected outcomes:
   - Every workflow you touched starts (no `startup_failure`)
   - Each job produces the expected artifacts / PR comment / release asset
   - Skipped jobs are truly unused triggers, not masked failures

3. **Main merge + tag move.** Only once the consumer PR goes green, merge your ci-workflows PR and move the active major tag (`@v7`). Repin the consumer PR to `@v7`, confirm it still passes, then merge.

---

## Commit convention

Conventional Commits, same as the Ruby gem repos:

```
<type>(<scope>): <description>

[body explaining *why* the change is needed]
```

Types we use here: `feat`, `fix`, `refactor`, `chore`, `docs`, `ci`. Scope is usually the reusable short name (`docs-pr`, `coverage-measure`, `app-release`) or the composite action short name (`coverage-report`, `yardstick-report`, `rubocop-report`, `post-sticky-comment`).

Do not include `Co-Authored-By:` trailers or any AI attribution.

---

## Pull request checklist

- [ ] YAML parses (`gh workflow view --yaml` or local `yamllint`)
- [ ] No `if: github.event_name == ...` guards added
- [ ] No `secrets: inherit`
- [ ] Every new input carries a runtime value or internal wiring — per-project options go to `.fluence-ci.yml` (principle #6), with a `description:` and a default (or genuinely required and documented)
- [ ] `github.event.*` / user-controllable values go through `env:`, not inline `${{ }}` in `run:`
- [ ] Tested from at least one consumer PR with a branch pin
- [ ] Decided whether this is an active-major fast-forward (`@v7`) or a new major cut (`@v8`)
- [ ] README.md updated if inputs, outputs, or the consumer contract changed

---

## AI-Assisted Contributions

When using AI tools (Claude, Copilot, etc.) to generate commits or PRs:

- **Classify first** — determine if the change is critical, major, minor, or trivial
- **Focus on the "why"** — the diff already shows the "what"
- **Skip boilerplate** — don't add empty sections or placeholder text

The person opening the PR takes full responsibility for the code. Before submitting:

- [ ] I have read and understood every line of code in this PR
- [ ] I can explain why each change was made
- [ ] I have tested the changes from a consumer PR (see "Testing changes" above)

Do **not** add AI co-author lines (`Co-Authored-By`), "Generated with" footers, or any AI attribution in commits or PR descriptions.
