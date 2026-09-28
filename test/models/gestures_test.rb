require "test_helper"

class GesturesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "the bottom unblocked live card is the current one" do
    a = Card.create!(summary: "a")
    b = Card.create!(summary: "b")
    assert_equal a, Card.current
    Gestures.top_of_stack(a)
    assert_equal b, Card.current
  end

  test "a stamp sends its message, handles the card, and seeds successors in sequence" do
    card = agent_card

    assert_enqueued_with job: AgentDispatchJob, args: [ card, "Open a PR for onbox and merge it once CI is green." ] do
      Gestures.stamp(card, stamps(:pr_and_merge))
    end

    assert card.handled?
    assert_equal "PR and merge", card.handled_with
    assert_equal 1, stamps(:pr_and_merge).reload.use_count

    deploy, announce = card.children.order(:id)
    assert_equal "Deploy onbox", deploy.summary
    assert_equal deploy, announce.blocked_by
    assert_equal deploy, Card.current

    Gestures.stamp(deploy, stamps(:done))
    assert_equal announce, Card.current
  end

  test "a stamp with no template sends the drafted proposed action" do
    card = agent_card
    card.update!(proposed_action: "Run the migration too.")
    assert_enqueued_with job: AgentDispatchJob, args: [ card, "Run the migration too." ] do
      Gestures.stamp(card, stamps(:approve))
    end
  end

  test "a handle stamp sends nothing" do
    card = agent_card
    assert_no_enqueued_jobs only: AgentDispatchJob do
      Gestures.stamp(card, stamps(:done))
    end
  end

  test "a repeating stamp re-seeds the card for its next interval" do
    card = Card.create!(summary: "Review the week")
    Gestures.stamp(card, stamps(:weekly_review))

    copy = card.children.sole
    assert copy.held?
    assert_in_delta 1.week.from_now, copy.hold_until, 5.seconds
  end

  test "reply delivers to the agent and logs the text for the noticer" do
    card = agent_card
    assert_enqueued_with job: AgentDispatchJob, args: [ card, "PR and merge" ] do
      Gestures.reply(card, "PR and merge")
    end
    assert card.handled?
    assert_equal [ "PR and merge" ], Handling.replies.pluck(:text)
  end

  test "later holds the card until its trigger fires" do
    card = Card.create!(summary: "later")
    assert Gestures.later(card, "2h")
    assert card.reload.held?
    assert_nil Card.current

    travel 3.hours do
      Trigger.fire_due!
      assert card.reload.live?
      assert_equal card, Card.current
    end
  end

  test "later refuses what it cannot read" do
    card = Card.create!(summary: "later")
    assert_not Gestures.later(card, "after my 3pm")
    assert card.reload.live?
  end

  test "flip counts toward the flip rate" do
    card = Card.create!(summary: "flip me")
    Gestures.flip(card)
    Gestures.stamp(card, stamps(:done))
    assert_equal 100, FlipRate.recent
  end

  test "the tray leaves off sending stamps with nothing to send" do
    card = agent_card
    labels = StampTray.for(card).shown.map(&:label)
    assert_not_includes labels, "Approve"
    assert_includes labels, "PR and merge"

    card.update!(proposed_action: "Go.")
    assert_includes StampTray.for(card).shown.map(&:label), "Approve"
  end

  test "the secretary's likely stamps lead the tray" do
    card = agent_card
    card.update!(payload: card.payload.merge("likely_stamps" => [ "Done" ]))
    assert_equal "Done", StampTray.for(card).shown.first.label
  end
end
