# frozen_string_literal: true

require_relative "test_helper"

class HooksAndCliTest < SyncTestCase
  def test_sync_hook_is_registered_on_all_platforms_without_linter
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    add_sync_hook

    _out, err, status = run_sync
    assert status.success?, "sync failed: #{err}"

    cursor = generated_json(".cursor/hooks.json")
    commands = cursor.dig("hooks", "afterFileEdit").map { |h| h["command"] }
    assert_includes commands, ".agents/hooks/sync-on-edit.sh"

    claude = generated_json(".claude/settings.json")
    claude_cmds = claude.dig("hooks", "PostToolUse").flat_map { |m| m["hooks"].map { |h| h["command"] } }
    assert(claude_cmds.any? { |c| c.include?("sync-on-edit.sh") }, "sync-on-edit missing from Claude")

    codex = generated_json(".codex/hooks.json")
    codex_cmds = codex.dig("hooks", "PostToolUse").flat_map { |m| m["hooks"].map { |h| h["command"] } }
    assert(codex_cmds.any? { |c| c.include?("sync-on-edit.sh") }, "sync-on-edit missing from Codex")
  end

  def test_linter_hook_is_registered_alongside_sync_hook
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    add_sync_hook
    add_linter_hook

    run_sync

    cursor = generated_json(".cursor/hooks.json")
    commands = cursor.dig("hooks", "afterFileEdit").map { |h| h["command"] }
    assert_includes commands, ".agents/hooks/sync-on-edit.sh"
    assert_includes commands, ".agents/hooks/linter-autocorrect.sh"
  end

  def test_check_reports_in_sync_after_generation
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    run_sync

    out, _err, status = run_sync("--check")
    assert status.success?, "expected exit 0 when in sync"
    assert_includes out, "in sync"
  end

  def test_check_detects_drift
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    run_sync

    File.write(File.join(@project, ".cursor", "rules", "core.mdc"), "tampered\n")

    _out, _err, status = run_sync("--check")
    refute status.success?, "expected non-zero exit when there is drift"
  end

  def test_platforms_flag_limits_generation
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })

    run_sync("--platforms", "cursor")

    assert generated?(".cursor/rules/core.mdc")
    refute generated?(".claude/rules/core.md"), "Claude should not be generated"
    refute generated?(".codex/agents"), "Codex should not be generated"
  end

  def test_platforms_env_var_is_respected
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })

    run_sync(env: { "AGENT_PLATFORMS" => "claude" })

    assert generated?(".claude/rules/core.md")
    refute generated?(".cursor/rules/core.mdc")
  end

  def test_invalid_platform_exits_with_error
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })

    _out, _err, status = run_sync("--platforms", "doesnotexist")
    refute status.success?, "an invalid platform should fail"
  end

  def test_agents_md_is_created_when_missing
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    refute generated?("AGENTS.md")

    _out, err, status = run_sync
    assert status.success?, "sync failed: #{err}"

    assert generated?("AGENTS.md"), "AGENTS.md should have been created"
    assert_includes generated("AGENTS.md"), "# AGENTS.md"
    assert_includes generated("AGENTS.md"), "Source Of Truth"
  end

  def test_existing_agents_md_is_never_overwritten
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    write_project("AGENTS.md", "# My custom AGENTS.md\n")

    run_sync

    assert_equal "# My custom AGENTS.md\n", generated("AGENTS.md")
  end

  def test_check_does_not_flag_missing_agents_md_as_drift
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    run_sync
    File.delete(File.join(@project, "AGENTS.md"))

    _out, _err, status = run_sync("--check")
    assert status.success?, "--check must not fail for a missing AGENTS.md (it is source, not an adapter)"
    refute generated?("AGENTS.md"), "--check must not create files"
  end

  def test_config_json_selects_platforms
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    write_project(".agents/config.json", JSON.pretty_generate("platforms" => ["codex"]))

    write_agent("rev", frontmatter: { "name" => "rev", "description" => "r" })
    run_sync

    assert generated?(".codex/agents/rev.toml")
    refute generated?(".cursor/agents/rev.md")
  end
end
