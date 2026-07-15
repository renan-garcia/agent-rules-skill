# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "json"
require "open3"

# Base for the sync-agent-config tests.
#
# Each test builds a temporary fixture project with a canonical source in
# .agents/, copies the real script from templates/ into bin/ and runs it for
# real, validating the adapters generated under .cursor/, .claude/ and .codex/.
class SyncTestCase < Minitest::Test
  SKILL_ROOT   = File.expand_path("..", __dir__)
  SYNC_ON_EDIT = File.join(SKILL_ROOT, "templates", "sync-on-edit.sh")

  # The suite runs against each language port so they stay in behavioural
  # parity. Select one with SYNC_RUNTIME=ruby|python|node|bun (default: ruby).
  # Bun runs the Node port; the installer rewrites the shebang to bun, mirrored
  # here in setup.
  RUNTIMES = {
    "ruby"   => { interpreter: "ruby",    template: "sync-agent-config",    update_template: "sync-agent-update" },
    "python" => { interpreter: "python3", template: "sync-agent-config.py", update_template: "sync-agent-update.py" },
    "node"   => { interpreter: "node",    template: "sync-agent-config.js", update_template: "sync-agent-update.js" },
    "bun"    => { interpreter: "bun",     template: "sync-agent-config.js", update_template: "sync-agent-update.js",
                  shebang: "#!/usr/bin/env bun" }
  }.freeze

  def runtime
    RUNTIMES.fetch(ENV.fetch("SYNC_RUNTIME", "ruby"))
  end

  def setup
    @project = Dir.mktmpdir("ars-test-")
    FileUtils.mkdir_p(File.join(@project, "bin"))
    FileUtils.mkdir_p(File.join(@project, ".agents", "rules"))
    FileUtils.mkdir_p(File.join(@project, ".agents", "agents"))
    FileUtils.mkdir_p(File.join(@project, ".agents", "hooks"))
    source = File.join(SKILL_ROOT, "templates", runtime[:template])
    target = File.join(@project, "bin", "sync-agent-config")
    FileUtils.cp(source, target)
    if runtime[:shebang]
      lines = File.readlines(target)
      lines[0] = "#{runtime[:shebang]}\n"
      File.write(target, lines.join)
    end
    FileUtils.chmod(0o755, target)

    # The suite overrides HOME to isolate the global installer config from
    # platform resolution. On machines that manage interpreters with a
    # version manager rooted at $HOME (e.g. asdf), that override would stop
    # the interpreter from resolving. Bridge the real toolchain into the fake
    # home so python3/node/ruby still run. Harmless where it does not exist.
    fake_home = File.join(@project, ".home")
    FileUtils.mkdir_p(fake_home)
    real_home = Dir.home
    %w[.asdf .tool-versions].each do |entry|
      real = File.join(real_home, entry)
      FileUtils.ln_s(real, File.join(fake_home, entry)) if File.exist?(real)
    end
  end

  def teardown
    FileUtils.remove_entry(@project) if @project && Dir.exist?(@project)
  end

  # ── Fixture builders ───────────────────────────────────────────────────────

  def write_rule(name, frontmatter:, body: "rule content\n")
    write_markdown(File.join(".agents", "rules", "#{name}.md"), frontmatter, body)
  end

  def write_agent(name, frontmatter:, body: "agent instructions\n")
    write_markdown(File.join(".agents", "agents", "#{name}.md"), frontmatter, body)
  end

  def write_overlay(adapter, kind, name, content)
    write_project(File.join(".agents", "adapters", adapter, kind, "#{name}.md"), content)
  end

  def add_sync_hook
    FileUtils.cp(SYNC_ON_EDIT, File.join(@project, ".agents", "hooks", "sync-on-edit.sh"))
  end

  def add_linter_hook(name: "linter-autocorrect.sh")
    write_project(File.join(".agents", "hooks", name), "#!/bin/bash\necho linting\n")
    FileUtils.chmod(0o755, File.join(@project, ".agents", "hooks", name))
  end

  def write_project(relative_path, content)
    full = File.join(@project, relative_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  # ── Execution ──────────────────────────────────────────────────────────────

  def run_sync(*args, env: {}, stdin: "")
    # Isolate the environment so the machine's global config / env vars never
    # leak into the platform resolution chain (keeps the suite hermetic).
    base = { "HOME" => File.join(@project, ".home"), "AGENT_PLATFORMS" => nil }
    Open3.capture3(base.merge(env), runtime[:interpreter], "bin/sync-agent-config", *args, chdir: @project, stdin_data: stdin)
  end

  # ── Generated artifact readers ─────────────────────────────────────────────

  def generated(relative_path)
    File.read(File.join(@project, relative_path))
  end

  def generated?(relative_path)
    File.exist?(File.join(@project, relative_path))
  end

  def generated_json(relative_path)
    JSON.parse(generated(relative_path))
  end

  private

  def write_markdown(relative_path, frontmatter, body)
    front = frontmatter.map { |k, v| "#{k}: #{v}" }.join("\n")
    write_project(relative_path, "---\n#{front}\n---\n\n#{body}")
  end
end
