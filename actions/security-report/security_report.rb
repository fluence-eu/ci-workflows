# frozen_string_literal: true

# Build a Markdown summary of brakeman + bundler-audit findings for
# the sticky PR comment. Mirrors the visual language of the other
# *_report.rb scripts: header with totals, status line, per-tool
# details collapsed in <details>.

require 'json'

brakeman_outcome = ARGV[0] || 'success'
audit_outcome    = ARGV[1] || 'success'
brakeman_path    = ARGV[2] || 'brakeman.json'
audit_path       = ARGV[3] || 'audit.txt'

# Parse brakeman's JSON report. Returns nil if the file is missing
# or malformed so the markdown gracefully degrades to "no detail
# available" instead of crashing the workflow step.
def parse_brakeman(path)
  return nil unless path && File.exist?(path) && !File.empty?(path)

  data = JSON.parse(File.read(path))
  warnings = data.fetch('warnings', [])
  errors   = data.fetch('errors', [])
  {
    warnings: warnings,
    errors:   errors,
    count:    warnings.size
  }
rescue JSON::ParserError, StandardError => e
  warn "Could not parse brakeman report at #{path}: #{e.class}: #{e.message}"
  nil
end

# Read bundler-audit's text output as-is. The format is human-readable
# but not stable enough across versions to parse reliably; we dump it
# inside a code block in the comment.
def read_audit(path)
  return '' unless path && File.exist?(path)

  File.read(path)
rescue StandardError => e
  warn "Could not read bundler-audit output at #{path}: #{e.class}: #{e.message}"
  ''
end

brakeman   = parse_brakeman(brakeman_path)
audit_text = read_audit(audit_path)

brakeman_count   = brakeman&.dig(:count) || 0
brakeman_failed  = brakeman_outcome == 'failure'
audit_failed     = audit_outcome == 'failure'
any_failure      = brakeman_failed || audit_failed

md = +''

# Header
icon = any_failure ? ':rotating_light:' : ':shield:'
title_suffix = brakeman_count.positive? ? " — #{brakeman_count} brakeman warning#{brakeman_count == 1 ? '' : 's'}" : ''
md << "## #{icon} Security Scan#{title_suffix}\n\n"

# Per-tool status table
md << "| Tool | Result |\n"
md << "|---|---|\n"
md << "| Brakeman | #{brakeman_failed ? ":x: #{brakeman_count} warning#{brakeman_count == 1 ? '' : 's'}" : ':white_check_mark: clean'} |\n"
md << "| Bundler-audit | #{audit_failed ? ':x: vulnerabilities found' : ':white_check_mark: clean'} |\n\n"

# Status line
md << if any_failure
        ":x: **Security findings detected** — see details below.\n\n"
      else
        ":white_check_mark: **No security findings.**\n\n"
      end

# Brakeman details — table of warnings, with GitHub blob links when
# the workflow exposes GITHUB_REPOSITORY + GITHUB_SHA.
repo = ENV.fetch('GITHUB_REPOSITORY', nil)
sha  = ENV.fetch('GITHUB_SHA', nil)

if brakeman && brakeman[:warnings].any?
  md << "<details><summary>:mag: Brakeman: #{brakeman_count} warning#{brakeman_count == 1 ? '' : 's'}</summary>\n\n"
  md << "| Check | Confidence | File | Line | Message |\n"
  md << "|---|---|---|---:|---|\n"

  brakeman[:warnings].sort_by { |w| [w['confidence'].to_s, w['check_name'].to_s] }.each do |w|
    file       = w['file'] || ''
    line       = w['line'] || ''
    short_file = file.sub(%r{^.*?/(?=app/|lib/|config/)}, '')
    line_cell  = if repo && sha && !file.empty? && !line.to_s.empty?
                   "[#{line}](https://github.com/#{repo}/blob/#{sha}/#{file}#L#{line})"
                 else
                   line.to_s
                 end
    message    = (w['message'] || '').to_s.gsub("\n", ' ').gsub('|', '\\|')
    md << "| `#{w['check_name']}` | #{w['confidence']} | `#{short_file}` | #{line_cell} | #{message} |\n"
  end
  md << "\n</details>\n\n"
end

# Brakeman parse errors (rare but worth surfacing if they happen).
if brakeman && brakeman[:errors].any?
  md << "<details><summary>:warning: Brakeman scan errors</summary>\n\n"
  md << "```\n"
  brakeman[:errors].each do |e|
    md << "#{e['error']}#{e['location'] ? " (#{e['location']})" : ''}\n"
  end
  md << "```\n\n</details>\n\n"
end

# Bundler-audit raw output. Dumped as-is to preserve the original
# CVE links and version requirements bundler-audit prints.
if audit_failed && !audit_text.empty?
  md << "<details><summary>:mag: Bundler-audit findings</summary>\n\n"
  md << "```\n#{audit_text.strip}\n```\n\n"
  md << "</details>\n\n"
end

# Soft warning when neither tool produced any output (could indicate
# a misconfigured Gemfile or a brakeman crash).
if !any_failure && brakeman.nil? && audit_text.empty?
  md << "_No tool output captured — verify brakeman and bundler-audit are installed in the consumer's Gemfile._\n"
end

print md
