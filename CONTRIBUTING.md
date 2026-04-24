# Contributing

Thanks for contributing! This repo hosts reusable GitHub Actions workflows shared across [fluence-eu](https://github.com/fluence-eu) projects. Every change is consumed automatically by those repos once `@v1` moves, so small mistakes have a wide blast radius.

1. Open an issue to discuss the proposed change
2. Create a branch from `main`
3. Implement the change
4. Test it end-to-end from a consumer PR (see below)
5. Open a pull request targeting `main`

---

## Repo layout

```
.github/
  workflows/
    ruby-gem-*.yml           # Ruby gem pipeline (semver, build + package push)
    app-*.yml                # Rolling-release app pipeline (timestamp tag + mirror)
  scripts/
    coverage_report.rb       # Helpers fetched via sidecar checkout by PR workflows
    yardstick_report.rb
    rubocop_report.rb
README.md                    # Consumer-facing usage docs
```

Two family prefixes:
- `ruby-gem-*` — semver-released Ruby gems with `.gemspec` + GitHub Packages push.
- `app-*` — rolling-release apps (any language): timestamp tag, changelog auto-merged on `develop`, force-push mirror to `main`.

If you need a new family, coordinate on the issue first — consumers already pin `@v1` across both.

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
| `RELEASE_APP_PRIVATE_KEY` | `ruby-gem-prepare-release.yml`, `app-prepare-release.yml`, `app-release.yml` |
| `FLUENCE_CI_BOT_PRIVATE_KEY` | `ruby-gem-docs-pr.yml`, `ruby-gem-coverage-pr.yml`, `ruby-gem-rubocop-pr.yml` |

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

GitHub auto-generates nice step display names from each action's `action.yml` metadata (`actions/checkout@v6` → "Checkout", `ruby/setup-ruby@v1` → "Setup Ruby"). Adding `name: Checkout code` on such steps is noise — skip it unless the name adds information:

- Disambig (e.g. `Checkout consumer repo` vs `Checkout ci-workflows`)
- Qualifying context (e.g. `Generate CI bot token (read-only access to ci-workflows)`)
- Run scripts (no auto-name exists)

### 6. Helper scripts via sidecar checkout

Ruby helpers (`coverage_report.rb`, `yardstick_report.rb`, `rubocop_report.rb`) live in `.github/scripts/` of this repo and are fetched at runtime by PR workflows using `actions/checkout` with the `FLUENCE_CI_BOT` GitHub App token. Consumers don't keep local copies.

When you add a helper:
- Put it in `.github/scripts/`
- Reference it from the reusable workflow via `_ci_workflows_/.github/scripts/<file>.rb` (the sidecar checkout path)
- Make it resilient to partial inputs (`rescue` / nil-guard missing artifacts — the baseline may be absent on the very first run)

---

## Versioning

### `@v1` is mobile

The `v1` tag is force-moved to every new commit on `main`. Consumers pin `@v1` and pick up non-breaking changes automatically. When you merge to main, also move the tag:

```bash
git tag -f v1
git push origin v1 --force
```

### What counts as breaking

Cut a new `@v2` (and leave `@v1` frozen at the last non-breaking commit) when:
- You rename or remove an input
- You require a new `secrets:` entry consumers weren't already forwarding
- You change the semantics of an existing input
- You remove an output downstream jobs might rely on

**Not breaking** (safe for `@v1`):
- Adding a new input with a default
- Adding a new output
- Adding a new step that doesn't change the contract
- Bug fixes, performance improvements, comment cleanups
- Adding a new workflow file

When in doubt, cut `@v2`. Rollback costs more than a tag.

### Pinning in a consumer PR during development

Temporarily pin consumers to a branch while iterating:

```yaml
uses: fluence-eu/ci-workflows/.github/workflows/ruby-gem-docs-pr.yml@refactor/my-branch
```

Move back to `@v1` before merging either side.

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

3. **Main merge + tag move.** Only once the consumer PR goes green, merge your ci-workflows PR and move `@v1`. Repin the consumer PR to `@v1`, confirm it still passes, then merge.

---

## Commit convention

Conventional Commits, same as the Ruby gem repos:

```
<type>(<scope>): <description>

[body explaining *why* the change is needed]
```

Types we use here: `feat`, `fix`, `refactor`, `chore`, `docs`, `ci`. Scope is usually the reusable short name (`docs-pr`, `coverage-measure`, `app-release`) or `scripts` for the `.github/scripts/` helpers.

Do not include `Co-Authored-By:` trailers or any AI attribution.

---

## Pull request checklist

- [ ] YAML parses (`gh workflow view --yaml` or local `yamllint`)
- [ ] No `if: github.event_name == ...` guards added
- [ ] No `secrets: inherit`
- [ ] Every new input has a `description:` and a default (or is genuinely required and documented)
- [ ] `github.event.*` / user-controllable values go through `env:`, not inline `${{ }}` in `run:`
- [ ] Tested from at least one consumer PR with a branch pin
- [ ] Decided whether this is a `@v1` move or a `@v2` cut
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
