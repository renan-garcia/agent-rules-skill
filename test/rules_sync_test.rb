# frozen_string_literal: true

require_relative "test_helper"

class RulesSyncTest < SyncTestCase
  def test_global_rule_maps_to_cursor_and_claude
    write_rule("core", frontmatter: { "description" => "Core conventions", "alwaysApply" => true })

    _out, err, status = run_sync
    assert status.success?, "sync failed: #{err}"

    cursor = generated(".cursor/rules/core.mdc")
    assert_includes cursor, "description: Core conventions"
    assert_includes cursor, "alwaysApply: true"
    refute_includes cursor, "globs:", "a global rule must not have globs"

    claude = generated(".claude/rules/core.md")
    assert_includes claude, "description: Core conventions"
    refute_includes claude, "paths:", "an alwaysApply rule must not generate paths in Claude"
  end

  def test_scoped_rule_converts_globs_to_paths
    write_rule(
      "services",
      frontmatter: {
        "description" => "Service layer",
        "alwaysApply" => false,
        "globs" => "app/services/**/*.rb,src/services/**/*.ts"
      }
    )

    _out, _err, status = run_sync
    assert status.success?

    cursor = generated(".cursor/rules/services.mdc")
    assert_includes cursor, "globs: app/services/**/*.rb,src/services/**/*.ts"
    assert_includes cursor, "alwaysApply: false"

    claude = generated(".claude/rules/services.md")
    assert_includes claude, "paths:"
    assert_includes claude, "app/services/**/*.rb"
    assert_includes claude, "src/services/**/*.ts"
  end

  def test_rule_body_is_preserved
    write_rule(
      "core",
      frontmatter: { "description" => "Core", "alwaysApply" => true },
      body: "# Title\n\nProject-specific rule.\n"
    )

    run_sync

    assert_includes generated(".cursor/rules/core.mdc"), "Project-specific rule."
    assert_includes generated(".claude/rules/core.md"), "Project-specific rule."
  end

  def test_cursor_only_overlay_is_appended_only_to_cursor
    write_rule("core", frontmatter: { "description" => "Core", "alwaysApply" => true })
    write_overlay("cursor", "rules", "core", "## Cursor only\n\nCursor only.\n")

    run_sync

    assert_includes generated(".cursor/rules/core.mdc"), "Cursor only."
    refute_includes generated(".claude/rules/core.md"), "Cursor only."
  end
end
