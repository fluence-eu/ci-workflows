# frozen_string_literal: true

require "json"
require "rubygems"

plan_path, outdated_path, allow_major, summary_path = ARGV
allow_major = allow_major == "true"
outdated = JSON.parse(File.read(outdated_path))
known = outdated["gems"].to_h { |gem| [gem["name"], gem] }

def invalid!(message)
  warn "::error::deps-plan-guard: #{message}"
  exit 1
end

plan = JSON.parse(File.read(plan_path))
invalid!("plan must be an object with a `groups` array") unless plan.is_a?(Hash) && plan["groups"].is_a?(Array)

plan["groups"].each_with_index do |group, index|
  where = "groups[#{index}]"
  invalid!("#{where} must be an object") unless group.is_a?(Hash)
  invalid!("#{where}.slug must match [a-z0-9-], max 51 chars") unless group["slug"].to_s.match?(/\A[a-z0-9][a-z0-9-]{0,50}\z/)
  %w[name rationale].each { |key| invalid!("#{where}.#{key} must be a string") unless group[key].is_a?(String) }
  invalid!("#{where}.risk must be patch, minor or major") unless %w[patch minor major].include?(group["risk"])
  invalid!("#{where}.skip_reason must be a string or null") unless group["skip_reason"].nil? || group["skip_reason"].is_a?(String)
  gems_valid = group["gems"].is_a?(Array) && group["gems"].any? &&
               group["gems"].all? { |gem| gem.is_a?(Hash) && gem["name"].is_a?(String) && gem["target"].is_a?(String) }
  invalid!("#{where}.gems must be a non-empty array of {name, target} strings") unless gems_valid
end

def target_in_range?(target, installed, newest)
  Gem::Version.correct?(target) &&
    Gem::Version.new(target) > Gem::Version.new(installed) &&
    Gem::Version.new(target) <= Gem::Version.new(newest)
end

def needs_major?(gem, target)
  major_change = Gem::Version.new(target).segments.first != Gem::Version.new(gem["installed"]).segments.first
  requirement = gem["requested"].empty? ? Gem::Requirement.default : Gem::Requirement.new(*gem["requested"].split(", "))
  major_change || !requirement.satisfied_by?(Gem::Version.new(target))
end

kept = []
skipped = []
dropped = []
used = []

plan["groups"].each do |group|
  if group["skip_reason"]
    skipped << [group["name"], group["skip_reason"]]
    next
  end
  if kept.any? { |other| other[:slug] == group["slug"] }
    skipped << [group["name"], "duplicate slug #{group["slug"]}"]
    next
  end

  in_group = []
  gems = group["gems"].filter_map do |entry|
    gem = known[entry["name"]]
    reason = if gem.nil? then "not in the outdated list"
             elsif used.include?(entry["name"]) then "already in another group"
             elsif in_group.include?(entry["name"]) then "listed twice in the group"
             elsif !target_in_range?(entry["target"], gem["installed"], gem["newest"]) then "target #{entry["target"]} out of range"
             end
    if reason.nil?
      in_group << entry["name"]
      next { name: entry["name"], installed: gem["installed"], target: entry["target"] }
    end

    dropped << [entry["name"], reason]
    nil
  end

  if gems.empty?
    skipped << [group["name"], "no valid gem left"]
  elsif !allow_major && gems.any? { |gem| needs_major?(known[gem[:name]], gem[:target]) }
    skipped << [group["name"], "major or Gemfile constraint change not allowed"]
  else
    used.concat(gems.map { |gem| gem[:name] })
    kept << { name: group["name"], slug: group["slug"], risk: group["risk"], rationale: group["rationale"], gems: }
  end
end

summary = +"## Deps bump plan\n\n"
summary << "| Group | Gems | Risk | Rationale |\n|---|---|---|---|\n"
kept.each do |group|
  gems = group[:gems].map { |gem| "#{gem[:name]} #{gem[:installed]} → #{gem[:target]}" }.join("<br>")
  summary << "| #{group[:name]} | #{gems} | #{group[:risk]} | #{group[:rationale].tr("\n|", "  ")} |\n"
end
summary << "\n_Nothing to bump._\n" if kept.empty?
rows = skipped.map { |name, reason| "- **#{name}** (group): #{reason}" } +
       dropped.map { |name, reason| "- `#{name}`: #{reason}" } +
       outdated["ignored"].map { |gem| "- `#{gem["name"]}`: #{gem["reason"]}" }
summary << "\n### Skipped\n\n#{rows.join("\n")}\n" if rows.any?
File.write(summary_path, summary)

puts JSON.generate(kept)
