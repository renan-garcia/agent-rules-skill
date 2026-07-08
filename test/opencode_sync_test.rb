# frozen_string_literal: true

require_relative "test_helper"

class OpencodeSyncTest < SyncTestCase
  def test_rules_are_generated_as_plain_instruction_files
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true }, body: "# Core\n\nglobal rule\n")

    _out, err, status = run_sync("--platforms", "opencode")
    assert status.success?, "sync failed: #{err}"

    rule = generated(".opencode/rules/core.md")
    assert_includes rule, "global rule"
    refute_includes rule, "alwaysApply", "opencode rule must not carry frontmatter"
  end

  def test_opencode_json_points_instructions_at_generated_rules
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })

    run_sync("--platforms", "opencode")

    config = generated_json("opencode.json")
    assert_equal "https://opencode.ai/config.json", config["$schema"]
    assert_includes config["instructions"], ".opencode/rules/*.md"
  end

  def test_opencode_json_merge_preserves_user_config
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    write_project("opencode.json", JSON.pretty_generate("model" => "anthropic/claude", "plugin" => ["foo"]))

    run_sync("--platforms", "opencode")

    config = generated_json("opencode.json")
    assert_equal "anthropic/claude", config["model"]
    assert_equal ["foo"], config["plugin"]
    assert_includes config["instructions"], ".opencode/rules/*.md"
  end

  def test_opencode_json_is_idempotent
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    run_sync("--platforms", "opencode")
    first = generated("opencode.json")

    run_sync("--platforms", "opencode")
    assert_equal first, generated("opencode.json"), "re-running must not duplicate the instructions entry"
  end

  def test_readonly_agent_restricts_tools
    write_agent(
      "reviewer",
      frontmatter: { "name" => "reviewer", "description" => "read-only", "model" => "claude-sonnet-4-5", "readonly" => true }
    )

    run_sync("--platforms", "opencode")

    agent = generated(".opencode/agents/reviewer.md")
    assert_includes agent, "mode: subagent"
    assert_includes agent, "model: claude-sonnet-4-5"
    assert_includes agent, "write: false"
    assert_includes agent, "edit: false"
  end

  def test_writable_agent_has_no_tool_restrictions
    write_agent("runner", frontmatter: { "name" => "runner", "description" => "writes" })

    run_sync("--platforms", "opencode")

    agent = generated(".opencode/agents/runner.md")
    assert_includes agent, "mode: subagent"
    refute_includes agent, "write: false"
  end

  def test_opencode_overlay_is_appended_only_to_opencode
    write_agent("runner", frontmatter: { "name" => "runner", "description" => "writes" })
    write_overlay("opencode", "agents", "runner", "## opencode note\n\nUse bun.\n")

    run_sync("--platforms", "opencode")

    assert_includes generated(".opencode/agents/runner.md"), "Use bun."
  end

  def test_opencode_is_included_in_default_platforms
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })

    run_sync

    assert generated?(".opencode/rules/core.md"), "opencode should be part of the default platform set"
  end
end
