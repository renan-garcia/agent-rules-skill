# frozen_string_literal: true

require_relative "test_helper"

# update.sh refreshes the executables a bootstrapped project copied from the
# skill (bin/sync-agent-config and .agents/hooks/sync-on-edit.sh) from the
# current templates, honoring the configured runtime and leaving project
# sources untouched. The suite runs it against every port via SYNC_RUNTIME.
class UpdateScriptTest < SyncTestCase
  UPDATE_SH = File.join(SKILL_ROOT, "update.sh")

  def expected_sync_content
    content = File.read(File.join(SKILL_ROOT, "templates", runtime[:template]))
    content = content.sub("env node", "env bun") if runtime[:shebang]
    content
  end

  def run_update(*args, env: {})
    base = {
      "HOME"            => File.join(@project, ".home"),
      "XDG_CONFIG_HOME" => File.join(@project, ".home", ".config")
    }
    Open3.capture3(base.merge(env), "bash", UPDATE_SH, @project, *args)
  end

  def write_installer_config(runtime_name)
    config = File.join(@project, ".home", ".config", "agent-rules-skill", "config.json")
    FileUtils.mkdir_p(File.dirname(config))
    File.write(config, JSON.pretty_generate("platforms" => ["cursor"], "runtime" => runtime_name) + "\n")
  end

  def sync_runtime_name
    ENV.fetch("SYNC_RUNTIME", "ruby")
  end

  def test_updates_outdated_sync_script_to_current_template
    write_project(File.join("bin", "sync-agent-config"), "#!/bin/sh\necho outdated\n")

    out, err, status = run_update("--runtime", sync_runtime_name)
    assert status.success?, "update.sh failed: #{err}"

    assert_includes out, "bin/sync-agent-config updated"
    assert_equal expected_sync_content, generated("bin/sync-agent-config")
    assert File.executable?(File.join(@project, "bin", "sync-agent-config")), "must be executable"
  end

  def test_rerun_is_idempotent
    write_project(File.join("bin", "sync-agent-config"), "outdated\n")
    run_update("--runtime", sync_runtime_name)

    out, _err, status = run_update("--runtime", sync_runtime_name)
    assert status.success?
    assert_includes out, "bin/sync-agent-config already up to date"
  end

  def test_updates_sync_on_edit_hook_when_present
    write_project(File.join("bin", "sync-agent-config"), "outdated\n")
    write_project(File.join(".agents", "hooks", "sync-on-edit.sh"), "#!/bin/bash\necho outdated\n")

    out, _err, status = run_update("--runtime", sync_runtime_name)
    assert status.success?

    assert_includes out, ".agents/hooks/sync-on-edit.sh updated"
    assert_equal File.read(SYNC_ON_EDIT), generated(".agents/hooks/sync-on-edit.sh")
  end

  def test_skips_hook_when_project_does_not_use_it
    write_project(File.join("bin", "sync-agent-config"), "outdated\n")

    out, _err, status = run_update("--runtime", sync_runtime_name)
    assert status.success?
    assert_includes out, "sync-on-edit.sh not present — skipped"
    refute generated?(".agents/hooks/sync-on-edit.sh"), "must not create the hook"
  end

  def test_runtime_is_read_from_installer_config
    write_project(File.join("bin", "sync-agent-config"), "outdated\n")
    write_installer_config(sync_runtime_name)

    _out, err, status = run_update
    assert status.success?, "update.sh failed: #{err}"
    assert_equal expected_sync_content, generated("bin/sync-agent-config")
  end

  def test_project_sources_and_options_are_untouched
    write_project(File.join("bin", "sync-agent-config"), "outdated\n")
    write_project("AGENTS.md", "# custom\n")
    options = JSON.pretty_generate("prune" => { "ignored" => [".cursor/rules/old.mdc"] }) + "\n"
    write_project(File.join("bin", "sync-agent-config-options.json"), options)

    _out, _err, status = run_update("--runtime", sync_runtime_name)
    assert status.success?

    assert_equal "# custom\n", generated("AGENTS.md")
    assert_equal options, generated("bin/sync-agent-config-options.json")
  end

  def test_without_path_and_without_tty_defaults_to_current_directory
    write_project(File.join("bin", "sync-agent-config"), "outdated\n")

    base = {
      "HOME"            => File.join(@project, ".home"),
      "XDG_CONFIG_HOME" => File.join(@project, ".home", ".config")
    }
    out, err, status = Open3.capture3(
      base, "bash", UPDATE_SH, "--runtime", sync_runtime_name,
      chdir: @project, stdin_data: ""
    )

    assert status.success?, "update.sh failed: #{err}"
    assert_includes out, "bin/sync-agent-config updated"
    assert_equal expected_sync_content, generated("bin/sync-agent-config")
  end

  def test_fails_on_project_without_bootstrap
    FileUtils.rm_rf(File.join(@project, "bin"))

    _out, err, status = run_update("--runtime", sync_runtime_name)
    refute status.success?, "a project without bin/sync-agent-config must fail"
    assert_includes err, "does not look bootstrapped"
  end

  def test_updated_script_actually_runs
    write_project(File.join("bin", "sync-agent-config"), "outdated\n")
    run_update("--runtime", sync_runtime_name)

    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    _out, err, status = run_sync
    assert status.success?, "updated script failed to run: #{err}"
    assert generated?(".cursor/rules/core.mdc")
  end
end
