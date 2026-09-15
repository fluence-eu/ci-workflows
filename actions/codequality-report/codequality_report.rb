# frozen_string_literal: true

# Build a Markdown summary of reek + flog + flay findings for the
# sticky PR comment. Mirrors the visual language of the other
# *_report.rb scripts: header with delta vs baseline, per-tool
# status table and a prominent "new findings" section (reek).
#
# Advisory mode — the workflow this composite is wired into does
# NOT fail on findings. The comment surfaces deltas and trends so
# devs can act on the worst regressions without a hard gate.
#
# Diff strategy:
# - Reek: identify smells by (source, context, smell_type) tuple —
#   reek doesn't ship a fingerprint field but those three together
#   are stable enough across runs (line numbers shift, so we ignore
#   them).
# - Flog: parse the "X.Y: flog total" line, compare deltas as numbers.
# - Flay: parse the "Total score ... = X" line, same.

require 'json'
require 'set'

# Linux caps any single environment string at MAX_ARG_STRLEN (128 KiB)
# and the runner hands this body to bash through the environment: at
# 716 smells the unbounded render hit 134_071 bytes and died on E2BIG.
NEW_SMELLS_SHOWN   = 50
FLOG_ENTRIES_SHOWN = 25
FLAY_BLOCKS_SHOWN  = 10

reek_path      = ARGV[0] || 'reek.json'
flog_path      = ARGV[1] || 'flog.txt'
flay_path      = ARGV[2] || 'flay.txt'
base_reek_path = ARGV[3]
base_flog_path = ARGV[4]
base_flay_path = ARGV[5]

# Empty strings (the GitHub Actions default for unset string inputs)
# are treated the same as nil — "no baseline".
base_reek_path = nil if base_reek_path.nil? || base_reek_path.empty?
base_flog_path = nil if base_flog_path.nil? || base_flog_path.empty?
base_flay_path = nil if base_flay_path.nil? || base_flay_path.empty?

# Parse a reek --format json report. Returns nil if the file is
# missing or malformed so the markdown gracefully degrades.
def parse_reek(path)
  return nil unless path && File.exist?(path) && !File.empty?(path)

  smells = JSON.parse(File.read(path))
  smells = [] unless smells.is_a?(Array)
  identities = smells.map { |s| [s['source'], s['context'], s['smell_type']] }.to_set
  {
    smells:     smells,
    count:      smells.size,
    identities: identities
  }
rescue JSON::ParserError, StandardError => e
  warn "Could not parse reek report at #{path}: #{e.class}: #{e.message}"
  nil
end

# Parse flog's text output. Pulls the "XX.X: flog total" header line,
# returns the score as a Float.
def parse_flog_score(path)
  return nil unless path && File.exist?(path) && !File.empty?(path)

  text = File.read(path)
  match = text.match(/^\s*([\d.]+):\s+flog\s+total/m)
  match ? match[1].to_f : nil
rescue StandardError => e
  warn "Could not parse flog report at #{path}: #{e.class}: #{e.message}"
  nil
end

# Parse flay's text output. Pulls the "Total score (lower is better) = X"
# line, returns the score as an Integer.
def parse_flay_score(path)
  return nil unless path && File.exist?(path) && !File.empty?(path)

  text = File.read(path)
  match = text.match(/^Total score.*=\s+(\d+)/)
  match ? match[1].to_i : nil
rescue StandardError => e
  warn "Could not parse flay report at #{path}: #{e.class}: #{e.message}"
  nil
end

def format_count_delta(diff)
  return '`±0`' if diff.zero?

  diff.positive? ? ":red_circle: `+#{diff}`" : ":green_circle: `#{diff}`"
end

def format_score_delta(diff)
  # Round first, *then* check for zero. `diff` is the result of a
  # Float subtraction and IEEE-754 noise routinely yields tiny
  # non-zero values (e.g. 1e-15) that round to 0.0 — checking
  # `diff.zero?` before rounding would let those through and emit
  # a misleading green/red delta like "+0.0".
  rounded = diff.round(1)
  return '`±0.0`' if rounded.zero?

  rounded.positive? ? ":red_circle: `+#{rounded}`" : ":green_circle: `#{rounded}`"
end

def truncation_note(total, shown, noun)
  return '' if total <= shown

  "_Showing the first #{shown} of #{total} #{noun}._\n\n"
end

def truncate_flog(text)
  lines   = text.strip.lines.map(&:chomp)
  entries = lines.drop(2).reject(&:empty?)

  [(lines.first(2) + [''] + entries.first(FLOG_ENTRIES_SHOWN)).join("\n"), entries.size]
end

def truncate_flay(text)
  # Cutting by line would leave a duplication without the files it points at.
  total, *blocks = text.strip.split(/\n{2,}/)

  [([total] + blocks.first(FLAY_BLOCKS_SHOWN)).join("\n\n"), blocks.size]
end

def reek_table(smells, limit)
  rows = +''
  rows << "| Smell | File | Context | Lines | Message |\n"
  rows << "|---|---|---|---|---|\n"
  smells.sort_by { |s| [s['smell_type'].to_s, s['source'].to_s, s['context'].to_s] }.first(limit).each do |s|
    source  = s['source'] || ''
    short   = source.sub(%r{^.*?/(?=lib/|app/)}, '')
    context = (s['context'] || '').to_s.gsub('|', '\\|')
    lines   = Array(s['lines']).join(', ')
    message = (s['message'] || '').to_s.gsub("\n", ' ').gsub('|', '\\|')
    rows << "| `#{s['smell_type']}` | `#{short}` | `#{context}` | #{lines} | #{message} |\n"
  end
  rows
end

pr_reek      = parse_reek(reek_path)
pr_flog      = parse_flog_score(flog_path)
pr_flay      = parse_flay_score(flay_path)
base_reek    = parse_reek(base_reek_path)
base_flog    = parse_flog_score(base_flog_path)
base_flay    = parse_flay_score(base_flay_path)

have_baseline = !base_reek.nil? || !base_flog.nil? || !base_flay.nil?

new_reek_smells = if pr_reek && base_reek
                    base_ids = base_reek[:identities]
                    pr_reek[:smells].reject { |s| base_ids.include?([s['source'], s['context'], s['smell_type']]) }
                  else
                    []
                  end

resolved_reek_count = if pr_reek && base_reek
                        pr_ids = pr_reek[:identities]
                        (base_reek[:identities] - pr_ids).size
                      else
                        0
                      end

reek_count      = pr_reek&.dig(:count) || 0
base_reek_count = base_reek&.dig(:count) || 0

flog_delta = pr_flog && base_flog ? pr_flog - base_flog : nil
flay_delta = pr_flay && base_flay ? pr_flay - base_flay : nil

md = +''

md << "## :bar_chart: Code Quality Report\n\n"

md << "| Tool | Base | PR | Δ |\n"
md << "|---|---:|---:|---:|\n"

reek_pr_cell    = pr_reek ? "#{reek_count} smell#{reek_count == 1 ? '' : 's'}" : '—'
reek_base_cell  = base_reek ? base_reek_count.to_s : '—'
reek_delta_cell = if base_reek && pr_reek
                    format_count_delta(reek_count - base_reek_count)
                  else
                    '—'
                  end
md << "| Reek | #{reek_base_cell} | #{reek_pr_cell} | #{reek_delta_cell} |\n"

flog_pr_cell    = pr_flog ? format('%.1f', pr_flog) : '—'
flog_base_cell  = base_flog ? format('%.1f', base_flog) : '—'
flog_delta_cell = flog_delta ? format_score_delta(flog_delta) : '—'
md << "| Flog total | #{flog_base_cell} | #{flog_pr_cell} | #{flog_delta_cell} |\n"

flay_pr_cell    = pr_flay ? pr_flay.to_s : '—'
flay_base_cell  = base_flay ? base_flay.to_s : '—'
flay_delta_cell = flay_delta ? format_count_delta(flay_delta.to_i) : '—'
md << "| Flay total | #{flay_base_cell} | #{flay_pr_cell} | #{flay_delta_cell} |\n\n"

all_pr_missing = pr_reek.nil? && pr_flog.nil? && pr_flay.nil?

# The all-missing case must be handled BEFORE baseline-driven branches
# — otherwise a parse failure on the PR head with a successful baseline
# would silently render ":white_check_mark: No new code-quality findings"
# while the footer simultaneously warns that no tool output was captured.
status_line = if all_pr_missing
                ":warning: **No PR-side tool output captured** — verify reek, flog and flay are installed in the consumer's Gemfile."
              elsif have_baseline && new_reek_smells.any?
                ":mag: **#{new_reek_smells.size} new reek smell#{new_reek_smells.size == 1 ? '' : 's'}** introduced — review below."
              elsif have_baseline && ((flog_delta && flog_delta.positive?) || (flay_delta && flay_delta.positive?))
                ':mag: Complexity / duplication score increased — review the deltas above.'
              elsif have_baseline
                ':white_check_mark: No new code-quality findings.'
              else
                ':information_source: No baseline available — comparison with the base branch is skipped.'
              end
md << "#{status_line}\n\n"

if have_baseline && new_reek_smells.any?
  md << "<details open><summary>:mag: #{new_reek_smells.size} new reek smell#{new_reek_smells.size == 1 ? '' : 's'} introduced by this PR</summary>\n\n"
  md << reek_table(new_reek_smells, NEW_SMELLS_SHOWN)
  md << "\n#{truncation_note(new_reek_smells.size, NEW_SMELLS_SHOWN, 'smells')}"
  md << "</details>\n\n"
end

if have_baseline && resolved_reek_count.positive?
  md << "<details><summary>:white_check_mark: #{resolved_reek_count} reek smell#{resolved_reek_count == 1 ? '' : 's'} resolved by this PR</summary>\n\n"
  md << "_The exact list isn't shown — these smells are gone, that's what matters._\n\n"
  md << "</details>\n\n"
end

if pr_flog && File.exist?(flog_path)
  text, total = truncate_flog(File.read(flog_path))
  md << "<details><summary>:bar_chart: Flog complexity breakdown</summary>\n\n"
  md << "```\n#{text}\n```\n\n"
  md << truncation_note(total, FLOG_ENTRIES_SHOWN, 'methods')
  md << "</details>\n\n"
end

if pr_flay && File.exist?(flay_path)
  text, total = truncate_flay(File.read(flay_path))
  md << "<details><summary>:bar_chart: Flay duplication breakdown</summary>\n\n"
  md << "```\n#{text}\n```\n\n"
  md << truncation_note(total, FLAY_BLOCKS_SHOWN, 'duplications')
  md << "</details>\n\n"
end

if all_pr_missing
  md << "_No tool output captured — verify reek, flog and flay are installed in the consumer's Gemfile._\n"
else
  md << "_Full reek, flog and flay reports: see the `codequality-report` artifact._\n"
end

print md
