# frozen_string_literal: true

# Build a Markdown summary of the eslint run for the PR comment job.
# Mirrors actions/rubocop-report/rubocop_report.rb structure: header
# with delta vs baseline, per-file breakdown for changed files, and a
# collapsible per-offense details section.

require 'json'

status           = ARGV[0] || 'success'
base_ref         = ARGV[1] || 'origin/develop'
pr_report_path   = ARGV[2]
base_report_path = ARGV[3]

def parse_eslint(path)
  return nil unless path && !path.empty? && File.exist?(path) && !File.empty?(path)

  data = JSON.parse(File.read(path))
  files = {}
  data.each do |entry|
    raw_path = entry.fetch('filePath', '')
    short    = raw_path.sub(%r{.*/(?=src/|tests?/|app/|lib/|components/)}, '')
    offenses = entry.fetch('messages', []).select { |m| m['severity'] == 2 }.map do |m|
      {
        rule:    m['ruleId'] || 'unknown',
        message: m['message'] || '',
        line:    m['line'] || 0,
        column:  m['column'] || 0
      }
    end
    files[short] = offenses unless offenses.empty?
  end
  total = files.values.sum(&:size)
  { files: files, total: total, inspected: data.size }
rescue JSON::ParserError, StandardError => e
  warn "Could not parse eslint report at #{path}: #{e.class}: #{e.message}"
  nil
end

pr   = parse_eslint(pr_report_path)
base = parse_eslint(base_report_path)
abort 'eslint report missing — nothing to comment' unless pr

have_baseline = !base.nil?
pr_total      = pr[:total]
base_total    = base&.dig(:total)
delta         = have_baseline ? pr_total - base_total : nil

def format_count_delta(diff)
  return '—' if diff.nil?
  return '`±0`' if diff.zero?

  diff.positive? ? ":red_circle: `+#{diff}`" : ":green_circle: `#{diff}`"
end

changed    = `git diff --name-only #{base_ref}...HEAD`.split("\n").map(&:strip)
changed_js = changed.select { |p| p.match?(/\.(vue|[mc]?[jt]sx?)$/) }

md = +''
header_icon  = status == 'failure' ? ':rotating_light:' : ':broom:'
title_suffix = have_baseline ? " (#{delta.positive? ? '+' : ''}#{delta})" : ''
md << "## #{header_icon} ESLint: #{pr_total} error#{pr_total == 1 ? '' : 's'}#{title_suffix}\n\n"

if have_baseline
  md << "| | Base | PR | Δ |\n"
  md << "|---|---:|---:|---:|\n"
  md << "| **Errors** | #{base_total} | #{pr_total} | #{format_count_delta(delta)} |\n\n"
end

md << if status == 'failure'
        ":x: **ESLint errors detected** — see the Run eslint step.\n\n"
      else
        ":white_check_mark: **No ESLint errors.**\n\n"
      end

def lookup_offenses(files_map, path)
  files_map[path] || files_map.find { |k, _| k.end_with?(path) || path.end_with?(k) }&.last || []
end

if changed_js.any?
  rows = changed_js.map do |path|
    pr_offs   = lookup_offenses(pr[:files], path)
    base_offs = have_baseline ? lookup_offenses(base[:files], path) : []
    icon = pr_offs.empty? ? ':green_circle:' : (pr_offs.size <= 3 ? ':yellow_circle:' : ':red_circle:')
    { name: path, icon: icon, count: pr_offs.size, delta: have_baseline ? pr_offs.size - base_offs.size : nil }
  end.select { |r| r[:count].positive? }

  if rows.any?
    md << "### Changed files\n\n"
    if have_baseline
      md << "| File | Errors | Δ vs base |\n|:-----|-------:|--------:|\n"
      rows.sort_by { |r| -r[:count] }.each do |r|
        md << "| #{r[:icon]} `#{r[:name]}` | **#{r[:count]}** | #{format_count_delta(r[:delta])} |\n"
      end
    else
      md << "| File | Errors |\n|:-----|-------:|\n"
      rows.sort_by { |r| -r[:count] }.each do |r|
        md << "| #{r[:icon]} `#{r[:name]}` | **#{r[:count]}** |\n"
      end
    end
    md << "\n"
  end
end

repo = ENV.fetch('GITHUB_REPOSITORY', nil)
sha  = ENV.fetch('GITHUB_SHA', nil)

if pr_total.positive?
  total_files = pr[:files].count { |_, offs| offs.any? }
  md << "<details><summary>:mag: #{pr_total} error#{pr_total == 1 ? '' : 's'} across #{total_files} file#{total_files == 1 ? '' : 's'}</summary>\n\n"
  pr[:files].sort_by { |_, offs| -offs.size }.each do |file, file_offs|
    next if file_offs.empty?
    md << "### `#{file}` (#{file_offs.size})\n\n"
    md << "| Line | Rule | Message |\n|---:|:---|:---|\n"
    file_offs.sort_by { |o| o[:line] }.each do |o|
      line_cell = (repo && sha) ? "[#{o[:line]}](https://github.com/#{repo}/blob/#{sha}/#{file}#L#{o[:line]})" : o[:line].to_s
      md << "| #{line_cell} | `#{o[:rule]}` | #{o[:message]} |\n"
    end
    md << "\n"
  end
  md << "</details>\n"
end

md << "\n_No baseline report available — comparison with the base branch is skipped._\n" unless have_baseline

print md
