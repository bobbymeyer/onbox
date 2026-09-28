require "test_helper"

class DispenserControllerTest < ActionDispatch::IntegrationTest
  test "empty stack" do
    get root_url
    assert_response :success
    assert_select ".empty-line", "Nothing in front of you."
  end

  test "shows only the current card, with no count" do
    Card.create!(summary: "first")
    Card.create!(summary: "second")
    get root_url
    assert_select ".card", 1
    assert_select ".card-summary", "first"
    assert_no_match "second", response.body
  end

  test "stamping advances to the next card" do
    card = Card.create!(summary: "first")
    Card.create!(summary: "second")
    post stamp_card_url(card, stamp_id: stamps(:done).id)
    assert_redirected_to root_url
    follow_redirect!
    assert_select ".card-summary", "second"
  end

  test "flip-first stamps are disabled on the front" do
    agent_card
    get root_url
    assert_select "button.stamp[disabled]", "Force push"
  end

  test "later with unreadable text keeps the card and says so" do
    card = Card.create!(summary: "first")
    post later_card_url(card), params: { when: "whenever-ish" }
    follow_redirect!
    assert_select ".flash-alert"
    assert card.reload.live?
  end

  test "maintenance shows the whole stack" do
    Card.create!(summary: "first")
    Card.create!(summary: "second").hold!(until_time: 1.day.from_now)
    get maintenance_url
    assert_response :success
    assert_match "first", response.body
    assert_match "second", response.body
  end

  test "stamp form rejects bad JSON" do
    post stamps_url, params: { stamp: { label: "Bad", card_type: "any", action_json: "{nope", successors_json: "[]" } }
    assert_response :unprocessable_entity
  end
end

class SourcesControllerTest < ActionDispatch::IntegrationTest
  test "saves an email source's search" do
    source = connect(sources(:gmail))
    patch source_url(source), params: { source: { email_query: "in:inbox is:important" } }
    assert_redirected_to sources_url
    assert_equal "in:inbox is:important", source.reload.email_query
  end

  test "shows connection state" do
    get sources_url
    assert_match "gmail:connect[gmail]", response.body
  end

  test "email cards render a reply box addressed to the sender" do
    email_card
    get root_url
    assert_select ".tool-email label", "Reply to Ada Lovelace <ada@example.com>"
    assert_select "button.stamp", "Archive"
  end
end
