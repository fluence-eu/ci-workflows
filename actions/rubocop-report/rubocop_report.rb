# frozen_string_literal: true

# Build a Markdown summary of the rubocop run for the PR comment job.
# Mirrors the visual language of coverage_report.rb and yardstick_report.rb:
# header with delta vs baseline, status line, per-file breakdown of offenses
# (for files changed in the PR), and a collapsible section listing every
# offense with a GitHub blob link.

require 'json'

status           = ARGV[0] || 'success' # "success" or "failure"
base_ref         = ARGV[1] || 'origin/main'
pr_report_path   = ARGV[2] || 'rubocop-pr/rubocop.json'
base_report_path = ARGV[3] # optional baseline from latest main run

# Parse a rubocop --format json report into { files: { short_path => [offenses] },
# total: Integer, inspected: Integer }. Returns nil if the file is missing so
# callers can render "no baseline".
def parse_rubocop(path)
  return nil unless path && File.exist?(path) && !File.empty?(path)

  data = JSON.parse(File.read(path))
  files = {}
  data.fetch('files', []).each do |entry|
    raw_path = entry.fetch('path', '')
    short    = raw_path.sub(%r{.*/(?=lib/|spec/|test/|app/|config/)}, '')
    offenses = entry.fetch('offenses', []).map do |off|
      {
        cop:      off.fetch('cop_name', 'Unknown'),
        message:  off.fetch('message', ''),
        severity: off.fetch('severity', 'warning'),
        line:     off.dig('location', 'start_line') || off.dig('location', 'line') || 0
      }
    end
    files[short] = offenses unless offenses.empty?
  end

  summary = data.fetch('summary', {})
  {
    files:     files,
    total:     summary.fetch('offense_count', files.values.sum(&:size)),
    inspected: summary.fetch('inspected_file_count', files.size)
  }
rescue JSON::ParserError, StandardError => e
  warn "Could not parse rubocop report at #{path}: #{e.class}: #{e.message}"
  nil
end

pr   = parse_rubocop(pr_report_path)
base = parse_rubocop(base_report_path)

abort 'rubocop report missing — nothing to comment' unless pr

have_baseline = !base.nil?

pr_total   = pr[:total]
base_total = base&.dig(:total)
delta      = have_baseline ? pr_total - base_total : nil

def format_count_delta(diff)
  return '—' if diff.nil?
  return '`±0`' if diff.zero?

  diff.positive? ? ":red_circle: `+#{diff}`" : ":green_circle: `#{diff}`"
end

# Changed files in this PR (any Ruby-ish file).
changed    = `git diff --name-only #{base_ref}...HEAD`.split("\n").map(&:strip)
changed_rb = changed.select { |p| p.end_with?('.rb') || p.end_with?('.gemspec') || p == 'Rakefile' }

md = +''

# Header
header_icon  = status == 'failure' ? ':rotating_light:' : ':shield:'
title_suffix = if have_baseline
                 sign = delta.positive? ? '+' : ''
                 " (#{sign}#{delta})"
               else
                 ''
               end
md << "## #{header_icon} RuboCop: #{pr_total} offense#{pr_total == 1 ? '' : 's'}#{title_suffix}\n\n"

# Totals table
if have_baseline
  md << "| | Base | PR | Δ |\n"
  md << "|---|---:|---:|---:|\n"
  md << "| **Offenses** | #{base_total} | #{pr_total} | #{format_count_delta(delta)} |\n\n"
end

# Status line
md << if status == 'failure'
        ":x: **RuboCop offenses detected** — see the Run rubocop step.\n\n"
      else
        ":white_check_mark: **No RuboCop offenses.**\n\n"
      end

# Per-file breakdown for changed files (if any have offenses).
def lookup_offenses(files_map, path)
  files_map[path] || files_map.find { |k, _| k.end_with?(path) || path.end_with?(k) }&.last || []
end

if changed_rb.any?
  rows = changed_rb.map do |path|
    pr_offs   = lookup_offenses(pr[:files], path)
    base_offs = have_baseline ? lookup_offenses(base[:files], path) : []
    delta_f   = pr_offs.size - base_offs.size

    icon = if pr_offs.empty?
             ':green_circle:'
           elsif pr_offs.size <= 3
             ':yellow_circle:'
           else
             ':red_circle:'
           end
    {
      name:      path,
      icon:      icon,
      count:     pr_offs.size,
      delta:     have_baseline ? delta_f : nil,
      sort_key: -pr_offs.size
    }
  end.select { |r| r[:count].positive? }

  if rows.any?
    md << "### Changed files\n\n"
    if have_baseline
      md << "| File | Offenses | Δ vs base |\n"
      md << "|:-----|-------:|--------:|\n"
      rows.sort_by { |r| r[:sort_key] }.each do |r|
        md << "| #{r[:icon]} `#{r[:name]}` | **#{r[:count]}** | #{format_count_delta(r[:delta])} |\n"
      end
    else
      md << "| File | Offenses |\n"
      md << "|:-----|-------:|\n"
      rows.sort_by { |r| r[:sort_key] }.each do |r|
        md << "| #{r[:icon]} `#{r[:name]}` | **#{r[:count]}** |\n"
      end
    end
    md << "\n"
  end
end

# Collapsed list of all offenses in the PR, grouped by file.
repo = ENV.fetch('GITHUB_REPOSITORY', nil)
sha  = ENV.fetch('GITHUB_SHA', nil)

if pr_total.positive?
  total_files = pr[:files].count { |_, offs| offs.any? }
  md << "<details><summary>:mag: #{pr_total} offense"
  md << 's' if pr_total != 1
  md << " across #{total_files} file"
  md << 's' if total_files != 1
  md << "</summary>\n\n"

  pr[:files].sort_by { |_, offs| -offs.size }.each do |file, file_offs|
    next if file_offs.empty?

    md << "### `#{file}` (#{file_offs.size})\n\n"
    md << "| Line | Cop | Message |\n"
    md << "|---:|:---|:---|\n"
    file_offs.sort_by { |o| o[:line] }.each do |o|
      line_cell = if repo && sha
                    "[#{o[:line]}](https://github.com/#{repo}/blob/#{sha}/#{file}#L#{o[:line]})"
                  else
                    o[:line].to_s
                  end
      md << "| #{line_cell} | `#{o[:cop]}` | #{o[:message]} |\n"
    end
    md << "\n"
  end

  md << "</details>\n"
end

unless have_baseline
  md << "\n_No baseline report available — comparison with main is skipped._\n"
end

print md
