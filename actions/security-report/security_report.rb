# frozen_string_literal: true

# Build a Markdown summary of brakeman + bundler-audit + ruby-audit
# findings for the sticky PR comment. Mirrors the visual language of
# the other *_report.rb scripts: header with delta vs baseline, status
# line, per-tool status table, prominent "new findings" sections and
# collapsed "all findings" sections.
#
# Diff strategy:
# - Brakeman: compare warnings by their stable `fingerprint` field.
#   New = present on PR but not on base. Resolved = present on base
#   but not on PR.
# - Bundler-audit: compare advisory IDs (CVE-XXXX-NNNN) extracted via
#   regex from the text output. Same set-difference logic.
# - Ruby-audit: outcome-based only (the tool exposes no machine-readable
#   format). No diff; we surface PR-side ✅/❌ and dump the full text
#   in a <details> when it fails.
#
# When no baseline is provided (first run, missing artifact), falls
# back to a current-state-only view, matching the prior single-mode
# behaviour.

require 'json'
require 'set'

brakeman_outcome     = ARGV[0] || 'success'
audit_outcome        = ARGV[1] || 'success'
ruby_audit_outcome   = ARGV[2] || 'success'
brakeman_path        = ARGV[3] || 'brakeman.json'
audit_path           = ARGV[4] || 'audit.txt'
ruby_audit_path      = ARGV[5] || 'ruby_audit.txt'
base_brakeman_path   = ARGV[6]
base_audit_path      = ARGV[7]
base_ruby_audit_path = ARGV[8]

# Empty strings (the GitHub Actions default for unset string inputs)
# are treated the same as nil — "no baseline".
base_brakeman_path   = nil if base_brakeman_path.nil? || base_brakeman_path.empty?
base_audit_path      = nil if base_audit_path.nil? || base_audit_path.empty?
base_ruby_audit_path = nil if base_ruby_audit_path.nil? || base_ruby_audit_path.empty?

# Parse a brakeman --format json report. Returns nil if the file is
# missing or malformed so the markdown gracefully degrades.
def parse_brakeman(path)
  return nil unless path && File.exist?(path) && !File.empty?(path)

  data = JSON.parse(File.read(path))
  warnings = data.fetch('warnings', [])
  errors   = data.fetch('errors', [])
  {
    warnings:     warnings,
    errors:       errors,
    count:        warnings.size,
    fingerprints: warnings.map { |w| w['fingerprint'] }.compact.to_set
  }
rescue JSON::ParserError, StandardError => e
  warn "Could not parse brakeman report at #{path}: #{e.class}: #{e.message}"
  nil
end

# Read bundler-audit's text output as-is — its format is human-readable
# but not stable enough across versions to fully parse. We only
# extract CVE IDs via regex for diffing.
def read_audit(path)
  return '' unless path && File.exist?(path)

  File.read(path)
rescue StandardError => e
  warn "Could not read bundler-audit output at #{path}: #{e.class}: #{e.message}"
  ''
end

def extract_advisories(text)
  return Set.new if text.nil? || text.empty?

  text.scan(/^Advisory:\s+(\S+)/).flatten.to_set
end

def format_count_delta(diff)
  return '`±0`' if diff.zero?

  diff.positive? ? ":red_circle: `+#{diff}`" : ":green_circle: `#{diff}`"
end

# Render a Markdown table of brakeman warnings. `repo` and `sha` are
# pulled from the workflow env (GITHUB_REPOSITORY / GITHUB_SHA) so
# each row links to the offending source line on the PR head.
def brakeman_table(warnings, repo, sha)
  rows = +''
  rows << "| Check | Confidence | File | Line | Message |\n"
  rows << "|---|---|---|---:|---|\n"
  warnings.sort_by { |w| [w['confidence'].to_s, w['check_name'].to_s] }.each do |w|
    file       = w['file'] || ''
    line       = w['line'] || ''
    short_file = file.sub(%r{^.*?/(?=app/|lib/|config/)}, '')
    line_cell  = if repo && sha && !file.empty? && !line.to_s.empty?
                   "[#{line}](https://github.com/#{repo}/blob/#{sha}/#{file}#L#{line})"
                 else
                   line.to_s
                 end
    message    = (w['message'] || '').to_s.gsub("\n", ' ').gsub('|', '\\|')
    rows << "| `#{w['check_name']}` | #{w['confidence']} | `#{short_file}` | #{line_cell} | #{message} |\n"
  end
  rows
end

repo = ENV.fetch('GITHUB_REPOSITORY', nil)
sha  = ENV.fetch('GITHUB_SHA', nil)

pr_brakeman          = parse_brakeman(brakeman_path)
pr_audit_text        = read_audit(audit_path)
pr_ruby_audit_text   = read_audit(ruby_audit_path)
base_brakeman        = parse_brakeman(base_brakeman_path)
base_audit_text      = read_audit(base_audit_path)
base_ruby_audit_text = read_audit(base_ruby_audit_path)

have_baseline = !base_brakeman.nil? || !base_audit_text.empty? || !base_ruby_audit_text.empty?

# Brakeman diff via fingerprints.
pr_brakeman_fps   = pr_brakeman&.dig(:fingerprints) || Set.new
base_brakeman_fps = base_brakeman&.dig(:fingerprints) || Set.new
new_brakeman      = pr_brakeman ? pr_brakeman[:warnings].reject { |w| base_brakeman_fps.include?(w['fingerprint']) } : []
resolved_brakeman_count = base_brakeman ? (base_brakeman_fps - pr_brakeman_fps).size : 0

# Bundler-audit diff via advisory IDs.
pr_advisories       = extract_advisories(pr_audit_text)
base_advisories     = extract_advisories(base_audit_text)
new_advisories      = pr_advisories - base_advisories
resolved_advisories = base_advisories - pr_advisories

# Totals.
brakeman_count      = pr_brakeman&.dig(:count) || 0
base_brakeman_count = base_brakeman&.dig(:count) || 0
audit_count         = pr_advisories.size
base_audit_count    = base_advisories.size

brakeman_failed   = brakeman_outcome == 'failure'
audit_failed      = audit_outcome == 'failure'
ruby_audit_failed = ruby_audit_outcome == 'failure'
any_failure       = brakeman_failed || audit_failed || ruby_audit_failed

md = +''

# Header — include a short summary in the title when something is failing.
icon = any_failure ? ':rotating_light:' : ':shield:'
title_suffix = +''
if any_failure
  parts = []
  parts << "#{brakeman_count} brakeman warning#{brakeman_count == 1 ? '' : 's'}" if brakeman_failed
  parts << "#{audit_count} CVE#{audit_count == 1 ? '' : 's'}" if audit_failed
  parts << 'ruby-audit findings' if ruby_audit_failed
  title_suffix << " — #{parts.join(', ')}"
end
md << "## #{icon} Security Scan#{title_suffix}\n\n"

# Per-tool status table.
if have_baseline
  md << "| Tool | Base | PR | Δ |\n"
  md << "|---|---:|---:|---:|\n"
  md << "| Brakeman | #{base_brakeman_count} | #{brakeman_count} | #{format_count_delta(brakeman_count - base_brakeman_count)} |\n"
  md << "| Bundler-audit | #{base_audit_count} | #{audit_count} | #{format_count_delta(audit_count - base_audit_count)} |\n"
  # Ruby-audit has no machine-readable format, so we can't show counts
  # or a delta. Surface PR-side outcome only with em-dashes elsewhere.
  ruby_pr_cell = ruby_audit_failed ? ':x: vulnerabilities found' : ':white_check_mark: clean'
  md << "| Ruby-audit | — | #{ruby_pr_cell} | — |\n\n"
else
  md << "| Tool | Result |\n"
  md << "|---|---|\n"
  md << "| Brakeman | #{brakeman_failed ? ":x: #{brakeman_count} warning#{brakeman_count == 1 ? '' : 's'}" : ':white_check_mark: clean'} |\n"
  md << "| Bundler-audit | #{audit_failed ? ':x: vulnerabilities found' : ':white_check_mark: clean'} |\n"
  md << "| Ruby-audit | #{ruby_audit_failed ? ':x: vulnerabilities found' : ':white_check_mark: clean'} |\n\n"
end

# Status line — distinguish "new in this PR" from "pre-existing" when possible.
md << if any_failure
        if have_baseline && (new_brakeman.any? || new_advisories.any?)
          ":x: **Security regression in this PR** — new findings introduced.\n\n"
        elsif have_baseline
          ":x: **Pre-existing security findings** — already present on the base branch.\n\n"
        else
          ":x: **Security findings present** — see details below.\n\n"
        end
      else
        ":white_check_mark: **No security findings.**\n\n"
      end

# Prominent "new findings" sections (open by default) when baseline available.
if have_baseline && new_brakeman.any?
  md << "<details open><summary>:rotating_light: #{new_brakeman.size} new brakeman warning#{new_brakeman.size == 1 ? '' : 's'} introduced by this PR</summary>\n\n"
  md << brakeman_table(new_brakeman, repo, sha)
  md << "\n</details>\n\n"
end

if have_baseline && new_advisories.any?
  md << "<details open><summary>:rotating_light: #{new_advisories.size} new advisor#{new_advisories.size == 1 ? 'y' : 'ies'} introduced by this PR</summary>\n\n"
  md << "```\n"
  new_advisories.sort.each { |id| md << "#{id}\n" }
  md << "```\n\n"
  md << "</details>\n\n"
end

# Resolved findings (collapsed, celebratory).
if have_baseline && (resolved_brakeman_count.positive? || resolved_advisories.any?)
  parts = []
  parts << "#{resolved_brakeman_count} brakeman" if resolved_brakeman_count.positive?
  parts << "#{resolved_advisories.size} CVE" if resolved_advisories.any?
  md << "<details><summary>:white_check_mark: Resolved by this PR (#{parts.join(', ')})</summary>\n\n"
  if resolved_advisories.any?
    md << "Resolved CVEs: #{resolved_advisories.to_a.sort.join(', ')}\n\n"
  end
  md << "</details>\n\n"
end

# Full current state — always shown when there are findings, even with baseline.
if pr_brakeman && pr_brakeman[:warnings].any?
  summary_text = have_baseline ? "All #{brakeman_count} brakeman warning#{brakeman_count == 1 ? '' : 's'} on this PR" : "Brakeman: #{brakeman_count} warning#{brakeman_count == 1 ? '' : 's'}"
  md << "<details><summary>:mag: #{summary_text}</summary>\n\n"
  md << brakeman_table(pr_brakeman[:warnings], repo, sha)
  md << "\n</details>\n\n"
end

# Brakeman parse errors (rare but worth surfacing).
if pr_brakeman && pr_brakeman[:errors].any?
  md << "<details><summary>:warning: Brakeman scan errors</summary>\n\n"
  md << "```\n"
  pr_brakeman[:errors].each do |e|
    md << "#{e['error']}#{e['location'] ? " (#{e['location']})" : ''}\n"
  end
  md << "```\n\n</details>\n\n"
end

# Full bundler-audit text dump for context (CVE descriptions, links,
# recommended versions). Only when bundler-audit flagged something.
if audit_failed && !pr_audit_text.empty?
  md << "<details><summary>:mag: Bundler-audit findings (full output)</summary>\n\n"
  md << "```\n#{pr_audit_text.strip}\n```\n\n"
  md << "</details>\n\n"
end

# Full ruby-audit text dump. ruby-audit has no machine-readable format,
# so we just surface its full output verbatim when it flags anything.
if ruby_audit_failed && !pr_ruby_audit_text.empty?
  md << "<details><summary>:mag: Ruby-audit findings (full output)</summary>\n\n"
  md << "```\n#{pr_ruby_audit_text.strip}\n```\n\n"
  md << "</details>\n\n"
end

unless have_baseline
  md << "_No baseline report available — comparison with the base branch is skipped._\n"
end

# Soft warning when no tool produced any output.
if !any_failure && pr_brakeman.nil? && pr_audit_text.empty? && pr_ruby_audit_text.empty?
  md << "_No tool output captured — verify brakeman, bundler-audit and ruby_audit are installed in the consumer's Gemfile._\n"
end

print md
