# frozen_string_literal: true

require "json"

outdated_path, package_path, scope = ARGV
wanted_names = scope.to_s.split

package = JSON.parse(File.read(package_path))
specs = %w[dependencies devDependencies optionalDependencies peerDependencies]
        .flat_map { |key| package.fetch(key, {}).to_a }.to_h
local_source = /\A(git[+:]|github:|file:|link:|workspace:)|\A[^@\/\s]+\/[^\/\s]+(#.*)?\z/

outdated = JSON.parse(File.read(outdated_path))
# Registry/auth failures also exit 1, with the error as the JSON body.
abort "::error::npm outdated failed: #{outdated["error"]["summary"]}" if outdated["error"].is_a?(Hash) && outdated["error"].key?("code")

gems = []
ignored = []
outdated.each do |name, entry|
  next unless wanted_names.empty? || wanted_names.include?(name)

  if specs[name].to_s.match?(local_source)
    ignored << { name:, reason: "git/path source" }
  elsif entry["current"].nil?
    ignored << { name:, reason: "not installed" }
  else
    gems << { name:, installed: entry["current"], newest: entry["latest"], requested: specs[name].to_s, wanted: entry["wanted"] }
  end
end

seen = (gems + ignored).map { |entry| entry[:name] }
(wanted_names - seen).each { |name| ignored << { name:, reason: "not outdated or unknown" } }

puts JSON.generate(gems:, ignored:)
