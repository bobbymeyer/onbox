require "test_helper"

class AgentDispatchTest < ActiveSupport::TestCase
  test "placeholders are substituted per argument, never through a shell" do
    argv = AgentDispatch.argv(session_id: "abc", instruction: "it's done; rm -rf /")
    assert_equal [ "claude", "--resume", "abc", "-p", "it's done; rm -rf /" ], argv
  end

  test "replies run on the Claude login: API keys are removed, hooks still fire" do
    log = Rails.root.join("tmp/fake_claude_#{SecureRandom.hex(4)}.json").to_s
    with_env("STACK_CLAUDE_BIN" => FAKE_CLAUDE, "ANTHROPIC_API_KEY" => "sk-should-not-leak", "FAKE_CLAUDE_LOG" => log) do
      _, ok = AgentDispatch.call(session_id: "abc", instruction: "go", cwd: Dir.pwd)
      assert ok
    end
    seen = JSON.parse(File.read(log))
    assert_equal [ "--resume", "abc", "-p", "go" ], seen["args"]
    assert_nil seen["api_key"]
    assert_nil seen["internal"], "a real agent turn, so its Stop hook reports back"
  ensure
    FileUtils.rm_f(log)
  end

  test "a failed send comes back as a card" do
    card = agent_card
    with_env("STACK_AGENT_COMMAND" => "false {session_id}") do
      AgentDispatchJob.perform_now(card, "go")
    end
    failure = card.children.sole
    assert_equal "review", failure.ask
    assert_match "Couldn't send instruction", failure.summary
  end
end
