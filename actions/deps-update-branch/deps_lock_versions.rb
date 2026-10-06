# frozen_string_literal: true

# Usage: deps_lock_versions.rb <lockfile> <base-rev> <pr-rev>
# Prints the dependencies whose locked version the PR changed (base-rev → pr-rev),
# then exits 1 if the working tree's lockfile does not hold those same versions.
require "json"

lockfile, base_rev, pr_rev = ARGV

def content(rev, path)
  return File.read(path) if rev == "WORKTREE"

  text = IO.popen(["git", "show", "#{rev}:#{path}"], err: File::NULL, &:read)
  text if $?.success?
end

def versions(lockfile, text)
  return {} unless text

  if lockfile.end_with?(".json")
    JSON.parse(text).fetch("packages", {}).filter_map { |key, spec| [key.split("node_modules/").last, spec["version"]] if key.include?("node_modules/") }.to_h
  else
    require "bundler"
    Bundler::LockfileParser.new(text).specs.to_h { |spec| [spec.name, spec.version.to_s] }
  end
end

before = versions(lockfile, content(base_rev, lockfile))
wanted = versions(lockfile, content(pr_rev, lockfile)).reject { |name, version| before[name] == version }
now = versions(lockfile, content("WORKTREE", lockfile))
puts wanted.keys
drift = wanted.reject { |name, version| now[name] == version }
exit 0 if drift.empty?

drift.each { |name, version| warn "#{name}: PR has #{version}, regenerated lockfile has #{now[name] || "none"}" }
exit 1
