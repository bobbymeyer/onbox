require "test_helper"

class AgentDispatchTest < ActiveSupport::TestCase
  test "placeholders are substituted per argument, never through a shell" do
    argv = AgentDispatch.argv(session_id: "abc", instruction: "it's done; rm -rf /")
    assert_equal [ "claude", "--resume", "abc", "-p", "it's done; rm -rf /" ], argv
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

  private
    def with_env(vars)
      old = vars.keys.to_h { |k| [ k, ENV[k] ] }
      vars.each { |k, v| ENV[k] = v }
      yield
    ensure
      old.each { |k, v| ENV[k] = v }
    end
end
