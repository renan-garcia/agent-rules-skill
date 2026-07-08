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
  SYNC_SCRIPT  = File.join(SKILL_ROOT, "templates", "sync-agent-config")
  SYNC_ON_EDIT = File.join(SKILL_ROOT, "templates", "sync-on-edit.sh")

  def setup
    @project = Dir.mktmpdir("ars-test-")
    FileUtils.mkdir_p(File.join(@project, "bin"))
    FileUtils.mkdir_p(File.join(@project, ".agents", "rules"))
    FileUtils.mkdir_p(File.join(@project, ".agents", "agents"))
    FileUtils.mkdir_p(File.join(@project, ".agents", "hooks"))
    FileUtils.cp(SYNC_SCRIPT, File.join(@project, "bin", "sync-agent-config"))
    FileUtils.chmod(0o755, File.join(@project, "bin", "sync-agent-config"))
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

  def run_sync(*args, env: {})
    # Isolate the environment so the machine's global config / env vars never
    # leak into the platform resolution chain (keeps the suite hermetic).
    base = { "HOME" => File.join(@project, ".home"), "AGENT_PLATFORMS" => nil }
    Open3.capture3(base.merge(env), "ruby", "bin/sync-agent-config", *args, chdir: @project)
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
