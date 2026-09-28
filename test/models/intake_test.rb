require "test_helper"

class IntakeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "a Stop hook becomes an agent card keyed by session" do
    card = agent_card(last_assistant_message: "Refactored intake.\nTests pass.")

    assert_equal "claude_code:sess-1", card.key
    assert_equal "agent", card.card_type
    assert_equal "onbox", card.project
    assert_equal "Refactored intake.", card.summary
    assert_equal "review", card.ask
    assert card.live?
    assert_enqueued_with job: DigestCardJob
  end

  test "a Notification asks for a decision" do
    card = agent_card(hook: "Notification", message: "Claude needs your permission to use Bash")
    assert_equal "decision", card.ask
    assert_equal "Claude needs your permission to use Bash", card.summary
  end

  test "reads the last assistant message from the transcript when the hook omits it" do
    Tempfile.create([ "transcript", ".jsonl" ]) do |f|
      f.puts({ type: "assistant", message: { content: [ { type: "text", text: "First" } ] } }.to_json)
      f.puts({ type: "user", message: { content: "ok" } }.to_json)
      f.puts({ type: "assistant", message: { content: [ { type: "tool_use" }, { type: "text", text: "Shipped the fix." } ] } }.to_json)
      f.flush
      card = agent_card(transcript_path: f.path)
      assert_equal "Shipped the fix.", card.summary
    end
  end

  test "one session holds one open card, refreshed and landed on top" do
    first = agent_card(last_assistant_message: "one")
    other = agent_card(session_id: "sess-2", last_assistant_message: "other")
    again = agent_card(last_assistant_message: "two")

    assert_equal first.id, again.id
    assert_equal "two", again.summary
    assert_operator again.position, :>, other.position
    assert_equal other, Card.current
  end

  test "a handled session card is not reopened; a new one is made" do
    first = agent_card
    first.handle!(with: "reply")
    assert_not_equal first.id, agent_card.id
  end

  test "an incoming event wakes cards held on its key" do
    held = Card.create!(summary: "Check the print", card_type: "generic")
    held.hold!(event_key: "printer:print.done")

    Intake.receive(sources(:printer), { "summary" => "Print finished", "event" => "print.done" })
    assert held.reload.live?
  end

  test "generic sources state their own front" do
    card = Intake.receive(sources(:printer), { "summary" => "Filament low", "ask" => "decision", "project" => "shop", "key" => "spool-1" })
    assert_equal [ "generic", "shop", "Filament low", "decision", "printer:spool-1" ],
                 [ card.card_type, card.project, card.summary, card.ask, card.key ]
  end
end
