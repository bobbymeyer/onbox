require "test_helper"

class DecomposeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def steps(*summaries)
    summaries.map { |s| { "summary" => s, "ask" => "review", "proposed_action" => "Do: #{s}" } }
  end

  test "sub-cards chain by dependency: first at the front, the rest land on top" do
    behind = Card.create!(summary: "already waiting")
    card = agent_card
    Gestures.top_of_stack(behind) # so the agent card is at the front

    first, second, third = Gestures.decompose(card, steps("Which DB?", "Write migration", "Backfill"))

    assert card.reload.handled?
    assert_equal "decompose", card.handled_with
    assert_equal first, Card.current
    assert_nil first.blocked_by
    assert_equal first, second.blocked_by
    assert_equal second, third.blocked_by
    assert_operator second.position, :>, behind.position, "later steps fall like new cards"

    Gestures.stamp(first, stamps(:done))
    assert_equal behind, Card.current, "the next step waits its turn behind older cards"
  end

  test "sub-cards keep the original's type and context" do
    card = agent_card
    sub = Gestures.decompose(card, steps("Write migration")).sole
    assert_equal [ "agent", "onbox", "sess-1", card.id ],
                 [ sub.card_type, sub.project, sub.payload["session_id"], sub.parent_card_id ]

    assert_enqueued_with job: AgentDispatchJob, args: [ sub, "Do: Write migration" ] do
      Gestures.stamp(sub, stamps(:approve))
    end
  end

  test "blank steps are skipped; no steps leaves the card alone" do
    card = Card.create!(summary: "big")
    assert_equal [], Gestures.decompose(card, [ { "summary" => " " } ])
    assert card.reload.live?
  end

  test "a card placed at position zero keeps it" do
    card = Card.create!(summary: "x", position: 0)
    assert_equal 0, card.position
  end

  test "move shifts a card among live cards" do
    a, b, c = %w[a b c].map { |s| Card.create!(summary: s) }
    c.move!(:forward)
    assert_equal [ a, c, b ], Card.live.in_stack_order.to_a
    a.move!(:forward)
    assert_equal [ a, c, b ], Card.live.in_stack_order.to_a
    a.move!(:back)
    assert_equal [ c, a, b ], Card.live.in_stack_order.to_a
  end
end
