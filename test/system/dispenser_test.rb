require "application_system_test_case"

class DispenserTest < ApplicationSystemTestCase
  test "working the stack on the phone: stamp, flip to unlock, later" do
    Card.create!(summary: "Print finished", source: sources(:printer))
    agent_card(last_assistant_message: "Refactored intake. Ready to force push?")

    visit root_url
    assert_text "Print finished"
    assert_no_text "Refactored intake" # one card at a time
    click_on "Done"

    assert_text "Refactored intake."
    assert_button "Force push", disabled: true
    find("summary", text: "Flip").click
    assert_text "Ready to force push?"
    assert_button "Force push", disabled: false
    assert_equal 1, Card.find_by(key: "claude_code:sess-1").reload.flip_count

    fill_in "when", with: "2h"
    click_on "Later"
    assert_text "Held until"
    assert_text "Nothing in front of you."
  end

  test "maintenance: select cards and act on them in bulk" do
    a, b = Card.create!(summary: "Renew domain"), Card.create!(summary: "Order filament")
    visit maintenance_url
    find("input.select-card[value='#{b.id}']").check
    find("select[name=bulk_op]").select("To front")
    click_on "Apply"
    assert_text "Moved 1 card to the front"
    assert_equal [ b, a ], Card.live.in_stack_order.to_a
  end
end
