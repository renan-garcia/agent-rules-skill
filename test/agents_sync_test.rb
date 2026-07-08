# frozen_string_literal: true

require_relative "test_helper"

class AgentsSyncTest < SyncTestCase
  def test_readonly_agent_generates_restricted_adapters
    write_agent(
      "code-reviewer",
      frontmatter: {
        "name" => "code-reviewer",
        "description" => "Read-only reviewer",
        "model" => "claude-sonnet-4-5",
        "readonly" => true
      }
    )

    _out, err, status = run_sync
    assert status.success?, "sync failed: #{err}"

    cursor = generated(".cursor/agents/code-reviewer.md")
    assert_includes cursor, "name: code-reviewer"
    assert_includes cursor, "readonly: true"

    claude = generated(".claude/agents/code-reviewer.md")
    assert_includes claude, "model: sonnet"
    assert_includes claude, "tools: Read, Grep, Glob, Bash"
    assert_includes claude, "disallowedTools: Write, Edit, MultiEdit"

    codex = generated(".codex/agents/code-reviewer.toml")
    assert_includes codex, 'name = "code-reviewer"'
    assert_includes codex, 'sandbox_mode = "read-only"'
    assert_includes codex, 'model_reasoning_effort = "high"'
    assert_includes codex, "developer_instructions = '''"
  end

  def test_writable_agent_has_no_readonly_restrictions
    write_agent(
      "test-runner",
      frontmatter: {
        "name" => "test-runner",
        "description" => "Runs and fixes tests",
        "model" => "composer-2.5-fast"
      }
    )

    run_sync

    claude = generated(".claude/agents/test-runner.md")
    assert_includes claude, "model: inherit"
    refute_includes claude, "disallowedTools"

    codex = generated(".codex/agents/test-runner.toml")
    refute_includes codex, "sandbox_mode"
    assert_includes codex, 'model_reasoning_effort = "medium"'
  end

  def test_codex_overlay_is_appended_to_developer_instructions
    write_agent(
      "test-runner",
      frontmatter: { "name" => "test-runner", "description" => "Runs tests" }
    )
    write_overlay("codex", "agents", "test-runner", "## Codex Runtime\n\nUse asdf exec.\n")

    run_sync

    codex = generated(".codex/agents/test-runner.toml")
    assert_includes codex, "Use asdf exec."
    refute_includes generated(".cursor/agents/test-runner.md"), "Use asdf exec."
  end
end
