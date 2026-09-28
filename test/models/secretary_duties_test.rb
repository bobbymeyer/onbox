require "test_helper"

class SecretaryDutiesTest < ActiveSupport::TestCase
  test "conversation operations make reversible changes only" do
    a = Card.create!(summary: "a")
    b = Card.create!(summary: "b")
    apply = ->(op, id = nil, value = nil) { Secretary::Conversation.apply("op" => op, "target_id" => id, "value" => value) }

    assert_match "front", apply.("to_front", b.id)
    assert_equal b, Card.current

    assert_match "Held", apply.("hold", b.id, 2.hours.from_now.iso8601)
    assert b.reload.held?
    assert_match "Released", apply.("release", b.id)
    assert b.reload.live?

    apply.("set_project", a.id, "house")
    apply.("set_ask", a.id, "decision")
    assert_equal [ "house", "decision" ], a.reload.values_at(:project, :ask)
    assert_nil apply.("set_ask", a.id, "nonsense")

    assert_match "Remembered", apply.("remember", nil, "Hold receipts until evening")
    directive = Directive.sole
    assert_match "Forgot", apply.("forget", directive.id)
    assert_empty Directive.all

    assert_nil apply.("delete", a.id)
    assert_nil apply.("to_front", 999_999)
    assert Card.exists?(a.id)
  end

  test "conversation without API access says so and keeps the log" do
    reply = Secretary::Conversation.say("why is this so high?")
    assert_equal %w[bobby secretary], SecretaryMessage.order(:id).pluck(:role)
    assert_match "not available", reply.body
  end

  test "the conversation context lists the stack and standing instructions" do
    Card.create!(summary: "Pay invoice", project: "house")
    Directive.create!(text: "Hold receipts until evening")
    context = Secretary::Conversation.context(SecretaryMessage.recent)
    assert_match "1. [#", context
    assert_match "Pay invoice", context
    assert_match "Hold receipts until evening", context
  end

  test "digest placement: front, or held per a standing instruction" do
    old = Card.create!(summary: "old")
    urgent = Card.create!(summary: "urgent")
    Secretary.new.place(urgent, "placement" => "front", "hold_until" => "")
    assert_equal urgent, Card.current

    receipt = Card.create!(summary: "receipt")
    Secretary.new.place(receipt, "placement" => "hold", "hold_until" => 3.hours.from_now.iso8601)
    assert receipt.reload.held?

    Secretary.new.place(old, "placement" => "hold", "hold_until" => "not a time")
    assert old.reload.live?
  end
end
