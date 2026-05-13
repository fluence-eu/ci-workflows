# frozen_string_literal: true

require 'set'
# Build a Markdown summary of the prettier --check run for the PR
# comment job. Prettier emits one `[warn] path/to/file` line per
# unformatted file, no line numbers. Aggregate per file.

status           = ARGV[0] || 'success'
base_ref         = ARGV[1] || 'origin/develop'
pr_report_path   = ARGV[2]
base_report_path = ARGV[3]

# Prettier sometimes emits ANSI color escapes even when piped through
# tee (false TTY detection), producing lines like
# `\e[33m[warn]\e[39m path/file` instead of `[warn] path/file`. Strip
# the escapes before matching so the parser doesn't silently count
# zero offences while the run report shows nine.
ANSI_ESCAPE = /\e\[[\d;]*[a-zA-Z]/
WARN_LINE = /^\[warn\]\s+(.+)$/

def parse_prettier(path)
  return nil unless path && !path.empty? && File.exist?(path) && !File.empty?(path)

  files = []
  File.foreach(path) do |line|
    clean = line.chomp.gsub(ANSI_ESCAPE, '')
    if (m = clean.match(WARN_LINE))
      raw = m[1]
      # Skip prettier's own summary lines.
      next if raw.start_with?('Code style issues')
      next if raw == 'Forgot to run Prettier?'

      short = raw.sub(%r{.*/(?=src/|tests?/|app/|lib/|components/)}, '')
      files << short
    end
  end
  { files: files.uniq, total: files.uniq.size }
rescue StandardError => e
  warn "Could not parse prettier report at #{path}: #{e.class}: #{e.message}"
  nil
end

pr   = parse_prettier(pr_report_path)
base = parse_prettier(base_report_path)
abort 'prettier report missing — nothing to comment' unless pr

have_baseline = !base.nil?
pr_total      = pr[:total]
base_total    = base&.dig(:total)
delta         = have_baseline ? pr_total - base_total : nil

def format_count_delta(diff)
  return '—' if diff.nil?
  return '`±0`' if diff.zero?

  diff.positive? ? ":red_circle: `+#{diff}`" : ":green_circle: `#{diff}`"
end

md = +''
header_icon  = status == 'failure' ? ':rotating_light:' : ':nail_care:'
title_suffix = have_baseline ? " (#{delta.positive? ? '+' : ''}#{delta})" : ''
md << "## #{header_icon} Prettier: #{pr_total} unformatted file#{pr_total == 1 ? '' : 's'}#{title_suffix}\n\n"

if have_baseline
  md << "| | Base | PR | Δ |\n|---|---:|---:|---:|\n"
  md << "| **Unformatted** | #{base_total} | #{pr_total} | #{format_count_delta(delta)} |\n\n"
end

md << if status == 'failure'
        ":x: **Prettier formatting issues** — run `prettier --write` locally.\n\n"
      else
        ":white_check_mark: **All files formatted.**\n\n"
      end

# Per-file breakdown. Prettier doesn't have line numbers so we just
# list the unformatted files with the delta direction (added /
# resolved compared to baseline).
if pr_total.positive? || (have_baseline && base_total.positive?)
  base_set = have_baseline ? base[:files].to_set : Set.new
  pr_set   = pr[:files].to_set

  added     = (pr_set - base_set).sort
  resolved  = (base_set - pr_set).sort
  unchanged = (pr_set & base_set).sort

  if added.any?
    md << "### :red_circle: Added (#{added.size})\n\n"
    added.each { |f| md << "- `#{f}`\n" }
    md << "\n"
  end
  if resolved.any?
    md << "### :green_circle: Resolved (#{resolved.size})\n\n"
    resolved.each { |f| md << "- `#{f}`\n" }
    md << "\n"
  end
  if unchanged.any? && !have_baseline
    md << "### Unformatted (#{unchanged.size})\n\n"
    unchanged.each { |f| md << "- `#{f}`\n" }
    md << "\n"
  end
end

md << "\n_No baseline report available — comparison with the base branch is skipped._\n" unless have_baseline

print md

# Set is autoloaded in Ruby 3.2+; older system Rubies need it required.
