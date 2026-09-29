require "test_helper"

class MaintenanceControllerTest < ActionDispatch::IntegrationTest
  test "bulk later holds every selected card" do
    a, b = Card.create!(summary: "a"), Card.create!(summary: "b")
    post bulk_cards_url, params: { card_ids: [ a.id, b.id ], bulk_op: "later", value: "tomorrow" }
    assert_redirected_to maintenance_url
    assert [ a, b ].all? { |c| c.reload.held? }
  end

  test "bulk to front keeps the selection's order" do
    a, b, c = %w[a b c].map { |s| Card.create!(summary: s) }
    post bulk_cards_url, params: { card_ids: [ b.id, c.id ], bulk_op: "front" }
    assert_equal [ b, c, a ], Card.live.in_stack_order.to_a
  end

  test "bulk re-tag, done and delete" do
    a, b, c = %w[a b c].map { |s| Card.create!(summary: s) }
    post bulk_cards_url, params: { card_ids: [ a.id ], bulk_op: "project", value: "house" }
    assert_equal "house", a.reload.project
    post bulk_cards_url, params: { card_ids: [ b.id ], bulk_op: "done" }
    assert b.reload.handled?
    post bulk_cards_url, params: { card_ids: [ c.id ], bulk_op: "delete" }
    assert_not Card.exists?(c.id)
  end

  test "bulk later with unreadable text changes nothing" do
    a = Card.create!(summary: "a")
    post bulk_cards_url, params: { card_ids: [ a.id ], bulk_op: "later", value: "whenever-ish" }
    follow_redirect!
    assert_select ".flash-alert"
    assert a.reload.live?
  end

  test "talking to the secretary and standing instructions" do
    post secretary_conversation_url, params: { text: "why is this so high?" }
    assert_redirected_to maintenance_url(anchor: "secretary")

    post directives_url, params: { directive: { text: "Hold receipts until evening" } }
    get maintenance_url
    assert_select ".message-bobby", /why is this so high/
    assert_select ".directive", /Hold receipts/

    delete directive_url(Directive.sole)
    assert_empty Directive.all
  end

  test "move and decompose from maintenance" do
    a, b = Card.create!(summary: "a"), Card.create!(summary: "b")
    post move_card_url(b, direction: "forward")
    assert_equal b, Card.current

    get breakdown_card_url(a)
    assert_response :success
    assert_select "input[name='steps[0][summary]']"

    post decompose_card_url(a), params: { steps: { "0" => { summary: "First", ask: "decision" }, "1" => { summary: "" } } }
    assert a.reload.handled?
    assert_equal "First", a.children.sole.summary

    post decompose_card_url(b), params: { steps: { "0" => { summary: "" } } }
    assert_redirected_to breakdown_card_url(b)
  end
end

class NoticerFlowTest < ActionDispatch::IntegrationTest
  test "the offer card casts a stamp from the dispenser" do
    3.times { |i| Gestures.reply(agent_card(session_id: "s#{i}"), "Ship it to staging") }
    Noticer.call("agent")

    get root_url
    assert_select ".tool-stamp-offer input[name=label][value=?]", "Ship it to staging"
    assert_select "a.stamp-link", false, "offers can't be decomposed"
    assert_select "button.stamp", false, "offers take no stamps"

    post cast_card_url(Card.current), params: { label: "Staging", template: "Ship it to staging" }
    assert_redirected_to root_url
    assert Stamp.exists?(label: "Staging", card_type: "agent")
  end
end

class DigestsControllerTest < ActionDispatch::IntegrationTest
  test "lists digests and catches up" do
    Gestures.stamp(Card.create!(summary: "Waiting"), stamps(:done))
    travel_to(1.day.from_now) do
      post catch_up_digests_url
      follow_redirect!
      assert_select ".flash-notice", /Wrote/
      assert_select ".digest-daily .maint-summary", /Daily digest/

      get digests_url(period: "hourly")
      assert_select ".digest-daily", false
    end
  end

  test "a digest card shows its body on the front" do
    card = Card.create!(card_type: "digest", summary: "Held 2 receipts", payload: { "title" => "Daily digest · Mon 28 Sep", "body" => "Held two receipts until evening." })
    get root_url
    assert_select ".digest-body", /Held two receipts/
    assert_select "input[type=submit][value='Got it']"
    assert_equal card, Card.current
  end
end
