# frozen_string_literal: true

require_relative "test_helper"

# Stale adapter pruning: adapters whose canonical source was removed are
# offered for deletion behind a per-file y/n/a/q prompt. Default platforms
# generate one rule into .cursor/rules, .claude/rules and .opencode/rules, so a
# deleted rule source leaves exactly three stale files (in that prompt order).
class PruneSyncTest < SyncTestCase
  def setup
    super
    write_rule("keep", frontmatter: { "description" => "Kept rule", "alwaysApply" => true })
    write_rule("old",  frontmatter: { "description" => "Old rule", "alwaysApply" => true })
    _out, err, status = run_sync
    assert status.success?, "initial sync failed: #{err}"
    FileUtils.rm(File.join(@project, ".agents", "rules", "old.md"))
  end

  def test_yes_removes_only_the_confirmed_file
    out, err, status = run_sync(stdin: "y\nn\nn\n")
    assert status.success?, "sync failed: #{err}"

    assert_includes out, "Remove stale .cursor/rules/old.mdc? [y/n/a/i/q]"
    assert_includes out, "Removed 1 stale adapter file(s)."
    refute generated?(".cursor/rules/old.mdc")
    assert generated?(".claude/rules/old.md")
    assert generated?(".opencode/rules/old.md")
  end

  def test_answers_are_case_insensitive
    _out, _err, status = run_sync(stdin: "Y\nQ\n")
    assert status.success?

    refute generated?(".cursor/rules/old.mdc")
    assert generated?(".claude/rules/old.md")
  end

  def test_all_removes_every_remaining_stale_file
    out, _err, status = run_sync(stdin: "a\n")
    assert status.success?

    assert_includes out, "Removed 3 stale adapter file(s)."
    refute generated?(".cursor/rules/old.mdc")
    refute generated?(".claude/rules/old.md")
    refute generated?(".opencode/rules/old.md")
    assert generated?(".cursor/rules/keep.mdc"), "kept rule must not be pruned"
  end

  def test_quit_keeps_every_remaining_stale_file
    out, _err, status = run_sync(stdin: "y\nq\n")
    assert status.success?

    assert_includes out, "Removed 1 stale adapter file(s)."
    refute generated?(".cursor/rules/old.mdc")
    assert generated?(".claude/rules/old.md")
    assert generated?(".opencode/rules/old.md")
  end

  def test_invalid_answer_reprompts
    out, _err, status = run_sync(stdin: "x\ny\nq\n")
    assert status.success?

    assert_equal 2, out.scan("Remove stale .cursor/rules/old.mdc?").length
    refute generated?(".cursor/rules/old.mdc")
  end

  def test_eof_keeps_files_so_hooks_never_delete_silently
    _out, _err, status = run_sync(stdin: "")
    assert status.success?

    assert generated?(".cursor/rules/old.mdc")
    assert generated?(".claude/rules/old.md")
    assert generated?(".opencode/rules/old.md")
  end

  def test_check_reports_stale_files_as_drift
    out, _err, status = run_sync("--check", stdin: "")
    refute status.success?, "--check must fail while stale files exist"

    assert_includes out, ".cursor/rules/old.mdc (stale — no canonical source)"
    assert generated?(".cursor/rules/old.mdc"), "--check must not delete files"
  end

  def test_empty_managed_dir_is_removed_after_pruning
    FileUtils.rm(File.join(@project, ".agents", "rules", "keep.md"))
    _out, _err, status = run_sync(stdin: "a\n")
    assert status.success?

    refute generated?(".cursor/rules"), "emptied managed dir must be removed"
  end

  def test_ignore_persists_the_file_and_skips_future_prompts
    out, _err, status = run_sync(stdin: "i\nq\n")
    assert status.success?

    assert_includes out, "Ignored .cursor/rules/old.mdc — saved to bin/sync-agent-config-options.json."
    assert generated?(".cursor/rules/old.mdc"), "ignored file must be kept"
    assert_equal(
      [".cursor/rules/old.mdc"],
      generated_json("bin/sync-agent-config-options.json").dig("prune", "ignored")
    )

    out, _err, status = run_sync(stdin: "q\n")
    assert status.success?
    refute_includes out, "Remove stale .cursor/rules/old.mdc?", "ignored file must not be prompted again"
    assert_includes out, "Remove stale .claude/rules/old.md?"
  end

  def test_ignored_files_are_not_reported_as_drift_by_check
    _out, _err, status = run_sync(stdin: "i\ni\ni\n")
    assert status.success?

    out, _err, status = run_sync("--check", stdin: "")
    assert status.success?, "--check must pass once every stale file is ignored: #{out}"
  end

  def test_options_file_keeps_unknown_keys_for_future_options
    write_project(
      File.join("bin", "sync-agent-config-options.json"),
      JSON.pretty_generate("future" => { "enabled" => true }) + "\n"
    )

    _out, _err, status = run_sync(stdin: "i\nq\n")
    assert status.success?

    options = generated_json("bin/sync-agent-config-options.json")
    assert_equal({ "enabled" => true }, options["future"], "unknown option namespaces must be preserved")
    assert_equal [".cursor/rules/old.mdc"], options.dig("prune", "ignored")
  end
end
