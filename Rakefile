# frozen_string_literal: true

require "rake/testtask"

# Runs the suite against the Ruby reference implementation (SYNC_RUNTIME=ruby).
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/*_test.rb"]
  t.verbose = true
end

# Runs the same suite against every language port so they stay in behavioural
# parity. Skips a runtime when its interpreter is not installed.
namespace :test do
  {
    "ruby"   => "ruby",
    "python" => "python3",
    "node"   => "node",
    "bun"    => "bun"
  }.each do |runtime, interpreter|
    desc "Run the suite against the #{runtime} port"
    task runtime do
      unless system("command -v #{interpreter} >/dev/null 2>&1")
        warn "Skipping #{runtime}: #{interpreter} not found on PATH"
        next
      end
      ENV["SYNC_RUNTIME"] = runtime
      Rake::TestTask.new("__parity_#{runtime}") do |t|
        t.libs << "test"
        t.test_files = FileList["test/*_test.rb"]
        t.verbose = true
      end
      Rake::Task["__parity_#{runtime}"].invoke
    end
  end

  desc "Run the suite against every available port (ruby, python, node, bun)"
  task parity: %w[ruby python node bun]
end

task default: :test
