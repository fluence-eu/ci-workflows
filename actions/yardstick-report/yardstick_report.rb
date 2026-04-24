# frozen_string_literal: true

# Build a Markdown summary of the yardstick documentation-quality run
# for the PR comment job. Mirrors the visual language of
# coverage_report.rb: overall score + progress bar, Base/PR/Δ totals
# table, a status line, and a per-file breakdown limited to the files
# touched by the PR.

status             = ARGV[0] || 'success' # "success" or "failure"
base_ref           = ARGV[1] || 'origin/main'
pr_report_path     = ARGV[2] || 'yardstick-pr/yardstick_report.txt'
base_report_path   = ARGV[3] # optional baseline from latest main run

VIOLATION_RE = /\A(?<file>[^:]+?):(?<line>\d+):\s+(?<method>.+?):\s+(?<rule>.+)\z/
FOOTER_RE    = /\AYARD-Coverage:\s+(?<pct>\S+?)%\s+Success:\s+(?<success>\d+)\s+Failed:\s+(?<failed>\d+)\s+Total:\s+(?<total>\d+)/

# Parse a yardstick report. Returns nil when the file is missing or
# empty so callers can decide how to render "no baseline".
def parse_yardstick(path)
  return nil unless path && File.exist?(path) && !File.empty?(path)

  violations = []
  summary = { coverage: 0.0, success: 0, failed: 0, total: 0 }

  File.foreach(path) do |raw|
    line = raw.strip
    next if line.empty?

    if (m = FOOTER_RE.match(line))
      summary[:coverage] = m[:pct].to_f
      summary[:success]  = m[:success].to_i
      summary[:failed]   = m[:failed].to_i
      summary[:total]    = m[:total].to_i
    elsif (m = VIOLATION_RE.match(line))
      violations << { file: m[:file], line: m[:line].to_i, method: m[:method], rule: m[:rule] }
    end
  end

  { violations: violations, summary: summary }
rescue StandardError => e
  warn "Could not parse yardstick report at #{path}: #{e.class}: #{e.message}"
  nil
end

pr   = parse_yardstick(pr_report_path)
base = parse_yardstick(base_report_path)

abort 'yardstick report missing — nothing to comment' unless pr

have_baseline = !base.nil?

# Unique failing method count per file. One method can trigger several
# rules; we count the method once so "failing items" aligns with
# "methods needing attention".
def failing_methods_by_file(parsed)
  return {} unless parsed

  parsed[:violations]
    .group_by { |v| v[:file] }
    .transform_values { |vs| vs.map { |v| [v[:line], v[:method]] }.uniq.size }
end

pr_failing   = failing_methods_by_file(pr)
base_failing = failing_methods_by_file(base)

pr_pct    = pr[:summary][:coverage]
base_pct  = base&.dig(:summary, :coverage)
delta     = have_baseline ? (pr_pct - base_pct).round(2) : nil

# Progress bar (20 chars wide) on the PR percentage.
filled = (pr_pct / 5).round
bar    = ("\u2588" * filled) + ("\u2591" * (20 - filled))

def format_delta(delta)
  return '—' if delta.nil?
  return '`±0%`' if delta.zero?

  if delta.positive?
    ":green_circle: `+#{delta}%`"
  else
    ":red_circle: `#{delta}%`"
  end
end

def format_count_delta(pr_count, base_count)
  return '—' if base_count.nil?

  diff = pr_count - base_count
  return '`±0`' if diff.zero?

  diff.positive? ? ":red_circle: `+#{diff}`" : ":green_circle: `#{diff}`"
end

# Changed files under lib/ (the only path yardstick scans).
changed     = `git diff --name-only #{base_ref}...HEAD`.split("\n").map(&:strip)
changed_lib = changed.select { |p| p.start_with?('lib/') && p.end_with?('.rb') }

changed_rows = changed_lib.map do |path|
  pr_count   = pr_failing[path] || 0
  base_count = base_failing ? (base_failing[path] || 0) : nil

  icon = if pr_count.zero?
           ':green_circle:'
         elsif pr_count <= 3
           ':yellow_circle:'
         else
           ':red_circle:'
         end

  {
    name: path,
    icon: icon,
    failing: pr_count,
    failing_str: pr_count.zero? ? '**0**' : "**#{pr_count}**",
    delta_str: format_count_delta(pr_count, base_count),
    sort_key: -pr_count
  }
end

md = +''

# Header
header_icon   = status == 'failure' ? ':rotating_light:' : ':shield:'
title_suffix  = if have_baseline
                  sign = delta.positive? ? '+' : ''
                  " (#{sign}#{delta}%)"
                else
                  ''
                end
md << "## #{header_icon} Documentation Quality: #{pr_pct}%#{title_suffix}\n\n"

# Progress bar
md << "> `#{bar}` **#{pr_pct}%** — #{pr[:summary][:success]}/#{pr[:summary][:total]} checks passing"
md << " (#{pr[:summary][:failed]} failing)" if pr[:summary][:failed].positive?
md << "\n\n"

# Totals table (only when we have a baseline)
if have_baseline
  md << "| | Base | PR | Δ |\n"
  md << "|---|---:|---:|---:|\n"
  md << "| **Coverage** | #{base_pct}% | #{pr_pct}% | #{format_delta(delta)} |\n"
  md << "| **Failing** | #{base[:summary][:failed]} | #{pr[:summary][:failed]} | " \
        "#{format_count_delta(pr[:summary][:failed], base[:summary][:failed])} |\n\n"
end

# Status line
md << if status == 'failure'
        ":x: **Documentation quality below threshold** — see the Run yardstick verify step.\n\n"
      else
        ":white_check_mark: **Documentation quality above threshold.**\n\n"
      end

# Changed files under lib/
if changed_rows.any?
  md << "### Changed files\n\n"
  if have_baseline
    md << "| File | Failing | Δ vs base |\n"
    md << "|:-----|-------:|--------:|\n"
    changed_rows.sort_by { |r| r[:sort_key] }.each do |r|
      md << "| #{r[:icon]} `#{r[:name]}` | #{r[:failing_str]} | #{r[:delta_str]} |\n"
    end
  else
    md << "| File | Failing |\n"
    md << "|:-----|-------:|\n"
    changed_rows.sort_by { |r| r[:sort_key] }.each do |r|
      md << "| #{r[:icon]} `#{r[:name]}` | #{r[:failing_str]} |\n"
    end
  end
  md << "\n"
end

# Strip namespace prefixes for display: 'Foo::Bar::Baz#qux' -> 'Baz#qux'.
def short_method(name)
  if (idx = name.rindex('::'))
    name[(idx + 2)..]
  else
    name
  end
end

# Translate yardstick's verbose rule sentences to short labels. Falls
# back to the raw sentence for anything not in the table — keeps the
# script forward-compatible when new rules are enabled.
RULE_LABELS = {
  'The method summary should be specified' => 'Missing summary',
  'The @return tag should be specified'    => 'Missing `@return`',
  'The @api tag should be specified'       => 'Missing `@api`',
  'The @api tag must be either public, semipublic or private' => 'Invalid `@api` value',
  'The public/semipublic method should have an example specified' => 'Missing `@example`',
  'The method summary should not end in a period' => 'Summary ends with `.`',
  'The method summary should be less than 80 characters in length' => 'Summary too long',
  'The method summary should be a single line' => 'Summary spans multiple lines'
}.freeze

def friendly_rule(rule)
  RULE_LABELS[rule] || rule
end

# Build a GitHub blob link for `path:line`, when repo and sha are
# available. Returns nil so callers can render a plain number instead.
repo = ENV.fetch('GITHUB_REPOSITORY', nil)
sha  = ENV.fetch('GITHUB_SHA', nil)

# Collapsed list of remaining violations, grouped by file.
if pr[:violations].any?
  files = pr[:violations].group_by { |v| v[:file] }
  total_files = files.size
  md << "<details><summary>:mag: #{pr[:violations].size} violation"
  md << 's' if pr[:violations].size != 1
  md << " across #{total_files} file"
  md << 's' if total_files != 1
  md << "</summary>\n\n"

  files.sort_by { |_, vs| -vs.size }.each do |file, file_violations|
    short_file = file.sub(%r{.*/(?=lib/)}, '')
    md << "### `#{short_file}` (#{file_violations.size})\n\n"
    md << "| Line | Method | Issue |\n"
    md << "|---:|:---|:---|\n"
    file_violations.sort_by { |v| v[:line] }.each do |v|
      line_cell = if repo && sha
                    "[#{v[:line]}](https://github.com/#{repo}/blob/#{sha}/#{file}#L#{v[:line]})"
                  else
                    v[:line].to_s
                  end
      md << "| #{line_cell} | `#{short_method(v[:method])}` | #{friendly_rule(v[:rule])} |\n"
    end
    md << "\n"
  end

  md << "</details>\n"
end

unless have_baseline
  md << "\n_No baseline report available — comparison with main is skipped._\n"
end

print md
