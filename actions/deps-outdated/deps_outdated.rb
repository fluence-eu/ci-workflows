# frozen_string_literal: true

require "bundler"
require "json"

outdated_path, lockfile_path, scope = ARGV
wanted = scope.to_s.split

line_format = /\A(?<name>\S+) \(newest (?<newest>[^,]+), installed (?<installed>[^,)]+)(?:, requested (?<requested>[^)]+))?\)\z/
non_rubygems = Bundler::LockfileParser.new(File.read(lockfile_path)).specs
                                      .reject { |spec| spec.source.is_a?(Bundler::Source::Rubygems) }
                                      .map(&:name)

gems = []
ignored = []
File.foreach(outdated_path, chomp: true) do |line|
  match = line_format.match(line.strip) or next
  name = match[:name]
  next unless wanted.empty? || wanted.include?(name)

  if non_rubygems.include?(name)
    ignored << { name:, reason: "git/path source" }
  else
    gems << { name:, installed: match[:installed], newest: match[:newest], requested: match[:requested].to_s }
  end
end

seen = (gems + ignored).map { |entry| entry[:name] }
(wanted - seen).each { |name| ignored << { name:, reason: "not outdated or unknown" } }

puts JSON.generate(gems:, ignored:)
