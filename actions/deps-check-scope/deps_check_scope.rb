# frozen_string_literal: true

require "json"

base = File.read(ARGV.fetch(0)).strip

def show(rev, path)
  content = IO.popen(["git", "show", "#{rev}:#{path}"], err: File::NULL, &:read)
  content if $?.success?
end

def gems(lockfile) = lockfile.to_s[/^DEPENDENCIES\n(.*?)(?:\n\n|\z)/m, 1].to_s.scan(/^  ([^\s!(]+)/).flatten

def packages(json)
  return [] unless json

  %w[dependencies devDependencies optionalDependencies peerDependencies].flat_map { |key| JSON.parse(json).fetch(key, {}).keys }
end

def listing(names) = names.empty? ? "none" : names.join(", ")

before = gems(show(base, "Gemfile.lock")) + packages(show(base, "package.json"))
after = gems(show("HEAD", "Gemfile.lock")) + packages(show("HEAD", "package.json"))
added = after - before
removed = before - after
exit 0 if added.empty? && removed.empty?

warn "::error::The bump changed the project's direct dependencies (added: #{listing(added)}; removed: #{listing(removed)}). Only the constraints of the group's dependencies may change."
exit 1
