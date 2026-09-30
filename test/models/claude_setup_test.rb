require "test_helper"

class ClaudeSetupTest < ActiveSupport::TestCase
  setup do
    @home = Rails.root.join("tmp/home-#{SecureRandom.hex(3)}")
    FileUtils.mkdir_p(@home.join("Library/Application Support/Claude"))
    FileUtils.mkdir_p(@home.join(".claude"))
    File.write(@home.join(".claude/settings.json"), { "model" => "opus", "hooks" => { "Stop" => [ { "hooks" => [ { "type" => "command", "command" => "say done" } ] } ] } }.to_json)
    File.write(@home.join(".claude/CLAUDE.md"), "# Mine\n\nBe terse.\n")
  end

  teardown { FileUtils.rm_rf(@home) }

  test "connects Claude Code and the desktop app without losing what's there, and twice is the same as once" do
    log = Rails.root.join("tmp/fake_claude_setup_#{SecureRandom.hex(3)}.json").to_s
    lines = with_env("HOME" => @home.to_s, "STACK_CLAUDE_BIN" => FAKE_CLAUDE, "FAKE_CLAUDE_LOG" => log, "STACK_SELF_URL" => "http://127.0.0.1:3005") do
      ClaudeSetup.connect!
      ClaudeSetup.connect!
    end

    settings = JSON.parse(File.read(@home.join(".claude/settings.json")))
    assert_equal "opus", settings["model"]
    assert_equal [ "http://127.0.0.1:3005", "claude-code-test-token" ], settings["env"].values_at("STACK_URL", "STACK_TOKEN")
    assert_equal [ "say done", Rails.root.join("script/stack-hook").to_s ], settings["hooks"]["Stop"].flat_map { |e| e["hooks"].map { |h| h["command"] } }
    assert_equal 1, settings["hooks"]["Notification"].size
    assert File.exist?(@home.join(".claude/settings.json.onbox-backup"))

    memory = File.read(@home.join(".claude/CLAUDE.md"))
    assert memory.start_with?("# Mine")
    assert_equal 1, memory.scan(ClaudeSetup::INSTRUCTION_MARK).size

    desktop = JSON.parse(File.read(@home.join("Library/Application Support/Claude/claude_desktop_config.json")))
    assert_equal [ RbConfig.ruby, [ StackMcp::SCRIPT.to_s ] ], desktop.dig("mcpServers", "stack").values_at("command", "args")

    added = JSON.parse(File.read(log))["args"]
    assert_equal %w[mcp add-json stack], added.first(3)
    assert lines.none? { |line| line.include?("claude-code-test-token") }, "never prints the token"
  ensure
    FileUtils.rm_f(log) if log
  end
end
