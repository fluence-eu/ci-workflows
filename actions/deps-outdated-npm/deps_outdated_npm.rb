# frozen_string_literal: true

require "json"
require "rubygems"

outdated_path, packages_path, scope = ARGV
wanted_names = scope.to_s.split

# `npm query ':root, .workspace'`: the root and every workspace package.json.
packages = JSON.parse(File.read(packages_path))
specs = packages.flat_map do |package|
  %w[dependencies devDependencies optionalDependencies peerDependencies].flat_map { |key| (package[key] || {}).to_a }
end
local = specs.select { |_, spec| spec.to_s.match?(/\A(git[+:]|github:|file:|link:|workspace:)|\A[^@\/\s]+\/[^\/\s]+(#.*)?\z/) }.map(&:first)
requested = specs.to_h
outdated = JSON.parse(File.read(outdated_path))
# Registry/auth failures also exit 1, with the error as the JSON body.
abort "::error::npm outdated failed: #{outdated["error"]["summary"]}" if outdated["error"].is_a?(Hash) && outdated["error"].key?("code")

gems = []
ignored = []
lowest = ->(versions) { versions.compact.min_by { |version| Gem::Version.new(version) } }

outdated.each do |name, entry|
  next unless wanted_names.empty? || wanted_names.include?(name)

  # A dependency declared by several workspaces comes back as an array.
  entries = [entry].flatten
  installed = lowest.(entries.map { |e| e["current"] })
  if local.include?(name)
    ignored << { name:, reason: "git/path source" }
  elsif installed.nil?
    ignored << { name:, reason: "not installed" }
  else
    gems << { name:, installed:, newest: entries.first["latest"], requested: requested[name].to_s, wanted: lowest.(entries.map { |e| e["wanted"] }) }
  end
end

seen = (gems + ignored).map { |entry| entry[:name] }
(wanted_names - seen).each { |name| ignored << { name:, reason: "not outdated or unknown" } }

puts JSON.generate(gems:, ignored:)
