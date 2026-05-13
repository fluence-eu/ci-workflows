# frozen_string_literal: true

# Build a Markdown summary of the vitest run for the PR comment job.
# Vitest --reporter=json output shape:
#   {
#     numTotalTests, numFailedTests, numPassedTests, numPendingTests,
#     testResults: [
#       { name: "/abs/path/file.test.ts", status: "failed",
#         assertionResults: [{ ancestorTitles, title, status,
#                              failureMessages: [...] }, ...] }
#     ]
#   }

require 'json'

status           = ARGV[0] || 'success'
base_ref         = ARGV[1] || 'origin/develop'
pr_report_path   = ARGV[2]
base_report_path = ARGV[3]

def parse_vitest(path)
  return nil unless path && !path.empty? && File.exist?(path) && !File.empty?(path)

  data = JSON.parse(File.read(path))
  files = {}
  data.fetch('testResults', []).each do |file|
    raw   = file.fetch('name', '')
    short = raw.sub(%r{.*/(?=src/|tests?/|app/|lib/|components/)}, '')
    failed = file.fetch('assertionResults', []).select { |a| a['status'] == 'failed' }.map do |a|
      {
        title:   [a.fetch('ancestorTitles', []), a.fetch('title', '')].flatten.join(' > '),
        message: (a['failureMessages'] || []).first.to_s.lines.first.to_s.strip
      }
    end
    files[short] = failed unless failed.empty?
  end

  {
    files:      files,
    total:      data.fetch('numTotalTests', 0),
    failed:     data.fetch('numFailedTests', 0),
    passed:     data.fetch('numPassedTests', 0),
    pending:    data.fetch('numPendingTests', 0)
  }
rescue JSON::ParserError, StandardError => e
  warn "Could not parse vitest report at #{path}: #{e.class}: #{e.message}"
  nil
end

pr   = parse_vitest(pr_report_path)
base = parse_vitest(base_report_path)
abort 'vitest report missing — nothing to comment' unless pr

have_baseline = !base.nil?
pr_failed     = pr[:failed]
base_failed   = base&.dig(:failed)
delta         = have_baseline ? pr_failed - base_failed : nil

def format_count_delta(diff)
  return '—' if diff.nil?
  return '`±0`' if diff.zero?

  diff.positive? ? ":red_circle: `+#{diff}`" : ":green_circle: `#{diff}`"
end

md = +''
header_icon  = status == 'failure' ? ':rotating_light:' : ':test_tube:'
md << "## #{header_icon} Vitest: #{pr[:total]} test#{pr[:total] == 1 ? '' : 's'}, #{pr_failed} failure#{pr_failed == 1 ? '' : 's'}\n\n"

md << "| | Base | PR | Δ |\n|---|---:|---:|---:|\n"
if have_baseline
  md << "| Total | #{base[:total]} | #{pr[:total]} | #{format_count_delta(pr[:total] - base[:total])} |\n"
  md << "| Passed | #{base[:passed]} | #{pr[:passed]} | #{format_count_delta(pr[:passed] - base[:passed])} |\n"
  md << "| **Failed** | #{base_failed} | #{pr_failed} | #{format_count_delta(delta)} |\n"
  md << "| Pending | #{base[:pending]} | #{pr[:pending]} | — |\n"
else
  md << "| Total | — | #{pr[:total]} | — |\n"
  md << "| Passed | — | #{pr[:passed]} | — |\n"
  md << "| **Failed** | — | #{pr_failed} | — |\n"
  md << "| Pending | — | #{pr[:pending]} | — |\n"
end
md << "\n"

md << if status == 'failure' || pr_failed.positive?
        ":x: **#{pr_failed} test failure#{pr_failed == 1 ? '' : 's'}** — see details below or the Run vitest step.\n\n"
      else
        ":white_check_mark: **All tests passing.**\n\n"
      end

if pr[:files].any?
  md << "<details><summary>:mag: Failures across #{pr[:files].size} file#{pr[:files].size == 1 ? '' : 's'}</summary>\n\n"
  pr[:files].sort_by { |_, offs| -offs.size }.each do |file, fails|
    md << "### `#{file}` (#{fails.size})\n\n"
    md << "| Test | Failure |\n|:---|:---|\n"
    fails.each do |f|
      md << "| #{f[:title]} | #{f[:message]} |\n"
    end
    md << "\n"
  end
  md << "</details>\n"
end

md << "\n_No baseline report available — comparison with the base branch is skipped._\n" unless have_baseline

print md
