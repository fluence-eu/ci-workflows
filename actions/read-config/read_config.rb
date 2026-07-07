# frozen_string_literal: true

# Resolves per-project options from the consumer's .fluence-ci.yml.
# Driven by env (see action.yml): KEYS (one `<key>=<dot.path>[=<default>]`
# spec per line), REQUIRED (space-separated keys that must come from the
# file), FILE (config path). Writes a single-line JSON object to the
# `values` output — JSON keeps multiline values (e.g. package_paths)
# safe to transport through GITHUB_OUTPUT.

require "json"
require "yaml"

file = ENV.fetch("FILE")
config = File.exist?(file) ? YAML.safe_load_file(file) || {} : {}
required = ENV.fetch("REQUIRED", "").split

values = {}
missing = []

ENV.fetch("KEYS").each_line(chomp: true) do |line|
  next if line.strip.empty?

  key, path, default = line.split("=", 3)
  raw = config.dig(*path.split("."))
  if raw.nil?
    missing << "#{key} (#{path})" if required.include?(key)
    values[key] = default.to_s
  else
    values[key] = raw.to_s
  end
end

unless missing.empty?
  warn "::error::#{file} must define: #{missing.join(", ")}"
  exit 1
end

File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |f| f.puts "values=#{JSON.generate(values)}" }
