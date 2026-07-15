# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "socket"

# bin/sync-agent-update pulls the vendored executables from the skill
# repository (here exercised via --source pointing at a local checkout or a
# local HTTP server) behind a y/n confirmation. The suite runs it against
# every port via SYNC_RUNTIME.
class RemoteUpdateTest < SyncTestCase
  def setup
    super
    install_updater
  end

  def install_updater
    source = File.join(SKILL_ROOT, "templates", runtime[:update_template])
    target = File.join(@project, "bin", "sync-agent-update")
    FileUtils.cp(source, target)
    if runtime[:shebang]
      lines = File.readlines(target)
      lines[0] = "#{runtime[:shebang]}\n"
      File.write(target, lines.join)
    end
    FileUtils.chmod(0o755, target)
  end

  def run_update(*args, stdin: "")
    base = { "HOME" => File.join(@project, ".home") }
    Open3.capture3(base, runtime[:interpreter], "bin/sync-agent-update", *args, chdir: @project, stdin_data: stdin)
  end

  def expected_sync_content
    content = File.read(File.join(SKILL_ROOT, "templates", runtime[:template]))
    content = content.sub("env node", "env bun") if runtime[:shebang]
    content
  end

  # Appends a blank line: changes the bytes without breaking syntax in any
  # port (the outdated self-updater still has to run).
  def outdate(relative_path)
    file = File.join(@project, relative_path)
    File.write(file, File.read(file) + "\n")
  end

  # ── Local directory source ───────────────────────────────────────────────

  def test_everything_up_to_date_on_fresh_copy
    out, _err, status = run_update("--source", SKILL_ROOT)
    assert status.success?, "expected success: #{out}"
    assert_includes out, "Everything is up to date."
  end

  def test_outdated_files_are_updated_after_yes
    outdate("bin/sync-agent-config")

    out, _err, status = run_update("--source", SKILL_ROOT, stdin: "y\n")
    assert status.success?

    assert_includes out, "bin/sync-agent-config — update available"
    assert_includes out, "✅ Updated bin/sync-agent-config"
    assert_includes out, "Update complete."
    assert_equal expected_sync_content, generated("bin/sync-agent-config")
    assert File.executable?(File.join(@project, "bin", "sync-agent-config"))
  end

  def test_no_answers_keeps_files
    outdate("bin/sync-agent-config")
    original = generated("bin/sync-agent-config")

    out, _err, status = run_update("--source", SKILL_ROOT, stdin: "n\n")
    assert status.success?
    assert_includes out, "No changes applied."
    assert_equal original, generated("bin/sync-agent-config")
  end

  def test_eof_is_a_safe_no
    outdate("bin/sync-agent-config")
    original = generated("bin/sync-agent-config")

    out, _err, status = run_update("--source", SKILL_ROOT, stdin: "")
    assert status.success?
    assert_includes out, "No changes applied."
    assert_equal original, generated("bin/sync-agent-config")
  end

  def test_yes_flag_applies_without_prompting
    outdate("bin/sync-agent-config")

    out, _err, status = run_update("--source", SKILL_ROOT, "--yes")
    assert status.success?
    refute_includes out, "Apply", "--yes must not prompt"
    assert_equal expected_sync_content, generated("bin/sync-agent-config")
  end

  def test_check_reports_updates_without_writing
    outdate("bin/sync-agent-config")
    original = generated("bin/sync-agent-config")

    out, _err, status = run_update("--source", SKILL_ROOT, "--check")
    refute status.success?, "--check must exit 1 when updates exist"
    assert_includes out, "update(s) available"
    assert_equal original, generated("bin/sync-agent-config")
  end

  def test_check_passes_when_current
    _out, _err, status = run_update("--source", SKILL_ROOT, "--check")
    assert status.success?
  end

  def test_updater_updates_itself
    outdate("bin/sync-agent-update")

    out, _err, status = run_update("--source", SKILL_ROOT, stdin: "y\n")
    assert status.success?
    assert_includes out, "✅ Updated bin/sync-agent-update"

    expected = File.read(File.join(SKILL_ROOT, "templates", runtime[:update_template]))
    expected = expected.sub("env node", "env bun") if runtime[:shebang]
    assert_equal expected, generated("bin/sync-agent-update")
  end

  def test_hook_is_updated_only_when_present
    add_sync_hook
    outdate(".agents/hooks/sync-on-edit.sh")

    out, _err, status = run_update("--source", SKILL_ROOT, stdin: "y\n")
    assert status.success?
    assert_includes out, "✅ Updated .agents/hooks/sync-on-edit.sh"
    assert_equal File.read(SYNC_ON_EDIT), generated(".agents/hooks/sync-on-edit.sh")
  end

  def test_state_is_recorded_and_other_namespaces_preserved
    prune = { "prune" => { "ignored" => [".cursor/rules/old.mdc"] } }
    write_project(File.join("bin", "sync-agent-config-options.json"), JSON.pretty_generate(prune) + "\n")
    outdate("bin/sync-agent-config")

    _out, _err, status = run_update("--source", SKILL_ROOT, "--yes")
    assert status.success?

    options = generated_json("bin/sync-agent-config-options.json")
    assert options.dig("update", "updated_at"), "update state must be recorded"
    assert_equal [".cursor/rules/old.mdc"], options.dig("prune", "ignored"), "prune namespace must be preserved"
  end

  def test_missing_bootstrap_fails
    FileUtils.rm(File.join(@project, "bin", "sync-agent-config"))

    _out, err, status = run_update("--source", SKILL_ROOT)
    refute status.success?
    assert_includes err, "does not look bootstrapped"
  end

  # ── Checksums ────────────────────────────────────────────────────────────

  def build_source(corrupt: false)
    src = File.join(@project, ".source")
    FileUtils.mkdir_p(File.join(src, "templates"))
    FileUtils.cp_r(Dir[File.join(SKILL_ROOT, "templates", "*")], File.join(src, "templates"))
    lines = Dir[File.join(src, "templates", "*")].sort.select { |f| File.file?(f) }.map do |f|
      digest = Digest::SHA256.hexdigest(File.read(f))
      digest = "0" * 64 if corrupt
      "#{digest}  templates/#{File.basename(f)}"
    end
    File.write(File.join(src, "SHA256SUMS"), lines.join("\n") + "\n")
    src
  end

  def test_valid_checksums_pass_silently
    outdate("bin/sync-agent-config")

    _out, err, status = run_update("--source", build_source, "--yes")
    assert status.success?, "valid checksums must pass: #{err}"
    refute_includes err, "SHA256SUMS not found"
  end

  def test_checksum_mismatch_aborts_before_writing
    outdate("bin/sync-agent-config")
    original = generated("bin/sync-agent-config")

    _out, err, status = run_update("--source", build_source(corrupt: true), "--yes")
    refute status.success?, "corrupted checksums must abort"
    assert_includes err, "Checksum mismatch"
    assert_equal original, generated("bin/sync-agent-config")
  end

  def test_missing_checksum_file_warns_but_continues
    outdate("bin/sync-agent-config")

    _out, err, status = run_update("--source", SKILL_ROOT, "--yes")
    assert status.success?
    assert_includes err, "SHA256SUMS not found"
  end

  # ── HTTP source ──────────────────────────────────────────────────────────

  def test_http_source_end_to_end
    src = build_source
    port = free_port
    server = spawn("python3", "-m", "http.server", port.to_s, "--bind", "127.0.0.1",
                   "--directory", src, out: File::NULL, err: File::NULL)
    wait_for_port(port)

    outdate("bin/sync-agent-config")
    out, err, status = run_update("--source", "http://127.0.0.1:#{port}", "--yes")

    assert status.success?, "http update failed: #{err}"
    assert_includes out, "✅ Updated bin/sync-agent-config"
    assert_equal expected_sync_content, generated("bin/sync-agent-config")
  ensure
    if server
      Process.kill("TERM", server) rescue nil
      Process.wait(server) rescue nil
    end
  end

  private

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_for_port(port)
    50.times do
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue Errno::ECONNREFUSED
      sleep 0.1
    end
    flunk "local http server did not start"
  end
end
