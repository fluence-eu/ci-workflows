# frozen_string_literal: true

require 'bundler/setup'
require 'json'
require 'undercover'

status = ARGV[0] # "success" or "failure"
base_ref = ARGV[1] || 'origin/main'
coverage_path = ARGV[2] || 'coverage/.resultset.json'
base_coverage_path = ARGV[3] # optional baseline resultset (from latest main run)

# The undercover gem expects the flat JSON produced by
# SimpleCov::Formatter::Undercover, not the standard SimpleCov resultset.
# Both files live side-by-side in coverage/.
undercover_path = File.join(File.dirname(coverage_path), 'coverage.json')

# Build the same Undercover::Report the CI "Check coverage" step computes,
# mirroring the CLI flags from .github/workflows/main.yml:
#   --compare origin/<base_ref> --include-files 'lib/**/*.rb' --simplecov coverage/coverage.json
# Any deviation from those options would produce a report inconsistent with
# the actual coverage gate.
undercover_flagged = []
if File.exist?(undercover_path)
  begin
    opts = Undercover::Options.new
    opts.simplecov_resultset = undercover_path
    opts.compare = base_ref
    opts.glob_allow_filters = ['lib/**/*.rb']

    adapter = File.open(undercover_path) do |file|
      Undercover::SimplecovResultAdapter.parse(file, opts)
    end
    changeset = Undercover::Changeset.new(File.join(opts.path, opts.git_dir), opts.compare)
    report = Undercover::Report.new(changeset, opts, adapter).build
    undercover_flagged = report.flagged_results
  rescue StandardError => e
    warn "Could not compute undercover report: #{e.class}: #{e.message}"
  end
end

# Parse a SimpleCov resultset into a { short_path => { covered:, relevant: } } hash.
# Defensive against missing keys and unexpected types: the baseline is optional
# and may be partial, corrupted, or in a format produced by a different SimpleCov
# version (the gem has no Gemfile.lock, so versions can drift between runs).
# Returns {} on any parse error and warns to stderr so the PR comment step
# never crashes because of a malformed resultset.
def parse_resultset(path)
  return {} unless path && File.exist?(path)

  data = JSON.parse(File.read(path))
  files = {}
  data.each_value do |group|
    next unless group.is_a?(Hash)

    coverage = group['coverage']
    next unless coverage.is_a?(Hash)

    coverage.each do |file, info|
      next unless info.is_a?(Hash)

      lines = info['lines']
      next unless lines.is_a?(Array)

      relevant = lines.compact
      next if relevant.empty?

      covered = relevant.count { |l| l.is_a?(Integer) && l.positive? }
      short = file.sub(%r{.*/(?=lib/)}, '')
      files[short] = { covered: covered, relevant: relevant.size }
    end
  end
  files
rescue JSON::ParserError, StandardError => e
  warn "Could not parse resultset at #{path}: #{e.class}: #{e.message}"
  {}
end

pr_files = parse_resultset(coverage_path)
base_files = parse_resultset(base_coverage_path)
have_baseline = !base_files.empty?

def totals(files)
  covered = files.values.sum { |f| f[:covered] }
  relevant = files.values.sum { |f| f[:relevant] }
  pct = relevant.zero? ? 0.0 : (covered.to_f / relevant * 100).round(2)
  { covered: covered, relevant: relevant, pct: pct }
end

pr_totals = totals(pr_files)
base_totals = have_baseline ? totals(base_files) : nil
total_delta = have_baseline ? (pr_totals[:pct] - base_totals[:pct]).round(2) : nil

# Per-file percentage
def file_pct(stats)
  return 0.0 if stats.nil? || stats[:relevant].zero?

  (stats[:covered].to_f / stats[:relevant] * 100).round(2)
end

# Format a delta with sign and color (returns markdown string).
def format_delta(delta)
  return '—' if delta.nil?
  return '`±0%`' if delta.zero?

  if delta.positive?
    ":green_circle: `+#{delta}%`"
  else
    ":red_circle: `#{delta}%`"
  end
end

# Changed files in this PR (paths from `git diff --name-only`).
changed = `git diff --name-only #{base_ref}...HEAD`.split("\n").map(&:strip)
changed_lib = changed.select { |p| p.start_with?('lib/') && p.end_with?('.rb') }

# Build a row per changed file. A file may be:
#   - present in pr_files (measured)
#   - absent from pr_files (not loaded by any spec)
# In either case, also look up its baseline coverage to compute the delta.
def lookup(files, path)
  files.find { |k, _| k == path || k.end_with?(path) || path.end_with?(k) }&.last
end

changed_rows = changed_lib.map do |path|
  pr_stats = lookup(pr_files, path)
  base_stats = lookup(base_files, path)

  if pr_stats
    pr_p = file_pct(pr_stats)
    base_p = base_stats ? file_pct(base_stats) : nil
    delta = base_p ? (pr_p - base_p).round(2) : nil
    icon = if pr_p >= 90
             ':green_circle:'
           elsif pr_p >= 70
             ':yellow_circle:'
           else
             ':red_circle:'
           end
    {
      name: path, icon: icon, pct_str: "**#{pr_p}%**",
      lines_str: "#{pr_stats[:covered]}/#{pr_stats[:relevant]}",
      delta_str: have_baseline ? format_delta(delta) : '—', sort_key: pr_p
    }
  else
    # Not measured by SimpleCov on the PR. Could be a Railtie, generator, etc.
    {
      name: path, icon: ':red_circle:', pct_str: '**not measured**',
      lines_str: '—',
      delta_str: have_baseline ? '—' : '—', sort_key: -1
    }
  end
end

# Progress bar (20 chars wide) on the PR percentage.
filled = (pr_totals[:pct] / 5).round
bar = ("\u2588" * filled) + ("\u2591" * (20 - filled))

# Build markdown
md = +''

# Header — include the global delta in the title when we have a baseline.
icon = status == 'failure' ? ':rotating_light:' : ':shield:'
title_suffix = if have_baseline
                 sign = total_delta.positive? ? '+' : ''
                 " (#{sign}#{total_delta}%)"
               else
                 ''
               end
md << "## #{icon} Coverage Report: #{pr_totals[:pct]}%#{title_suffix}\n\n"

# Progress bar
md << "> `#{bar}` **#{pr_totals[:pct]}%** — #{pr_totals[:covered]}/#{pr_totals[:relevant]} lines covered\n\n"

# Base / PR / Δ totals table (only when we have a baseline)
if have_baseline
  md << "| | Base | PR | Δ |\n"
  md << "|---|---:|---:|---:|\n"
  md << "| **Total** | #{base_totals[:pct]}% | #{pr_totals[:pct]}% | #{format_delta(total_delta)} |\n\n"
end

# Status line
md << if status == 'failure'
        ":x: **Untested changes detected** — some modified code is not covered by tests.\n\n"
      else
        ":white_check_mark: **All changes are tested.**\n\n"
      end

# Untested code blocks flagged by undercover. Same source of truth as the
# CI "Check coverage" gate.
if undercover_flagged.any?
  md << "### :warning: Untested changes\n\n"
  md << "| File | Lines | Block | Coverage |\n"
  md << "|:-----|:------|:------|--------:|\n"
  undercover_flagged.each do |result|
    short = result.file_path.sub(%r{.*/(?=lib/)}, '')
    lines = if result.first_line == result.last_line
              "L#{result.first_line}"
            else
              "L#{result.first_line}–#{result.last_line}"
            end
    pct = (result.coverage_f * 100).round(2)
    md << "| `#{short}` | #{lines} | `#{result.name}` | **#{pct}%** |\n"
  end
  md << "\n"
end

# Changed files table — every file in the PR's diff under lib/, with their
# per-file coverage and delta vs base. Files not loaded by any spec appear
# as "not measured".
if changed_rows.any?
  md << "### Changed files\n\n"
  if have_baseline
    md << "| File | Coverage | Δ vs base | Lines |\n"
    md << "|:-----|-------:|--------:|------:|\n"
    changed_rows.sort_by { |r| r[:sort_key] }.each do |r|
      md << "| #{r[:icon]} `#{r[:name]}` | #{r[:pct_str]} | #{r[:delta_str]} | #{r[:lines_str]} |\n"
    end
  else
    md << "| File | Coverage | Lines |\n"
    md << "|:-----|-------:|------:|\n"
    changed_rows.sort_by { |r| r[:sort_key] }.each do |r|
      md << "| #{r[:icon]} `#{r[:name]}` | #{r[:pct_str]} | #{r[:lines_str]} |\n"
    end
  end
  md << "\n"
end

unless have_baseline
  md << "_No baseline coverage available — comparison with main is skipped._\n"
end

print md
