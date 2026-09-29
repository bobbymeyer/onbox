require "test_helper"

class AccountantTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  # Tuesday 29 Sep 2026, a little after 10:00.
  NOW = Time.zone.local(2026, 9, 29, 10, 2)

  test "windows are the last completed calendar periods" do
    assert_equal [ NOW.change(hour: 9), NOW.change(hour: 10, min: 0) ], Accounting.window("hourly", NOW)
    assert_equal [ Time.zone.local(2026, 9, 28), Time.zone.local(2026, 9, 29) ], Accounting.window("daily", NOW)
    assert_equal [ Time.zone.local(2026, 9, 21), Time.zone.local(2026, 9, 28) ], Accounting.window("weekly", NOW)
    assert_equal [ Time.zone.local(2026, 8, 1), Time.zone.local(2026, 9, 1) ], Accounting.window("monthly", NOW)
  end

  test "an hour with activity gets a digest from the log; a quiet one is skipped" do
    travel_to(NOW.change(hour: 9, min: 30)) do
      card = Card.create!(summary: "Print finished", source: sources(:printer))
      Gestures.flip(card)
      Gestures.stamp(card, stamps(:done))
    end

    travel_to(NOW) do
      hourly = Accountant.account("hourly", NOW)
      assert_equal 1, hourly.stats["handled_count"]
      assert_equal({ "printer" => 1 }, hourly.stats["arrived"])
      assert_match "Handled 1 (1 Done)", hourly.body
      assert_nil hourly.card, "hourly digests stay off the stack"

      assert_nil Accountant.account("hourly", NOW), "written once"
      assert_nil Accountant.account("hourly", NOW + 1.hour), "quiet hour skipped"
    end
  end

  test "the secretary's own actions are accounted for" do
    travel_to(NOW.change(hour: 9, min: 10)) do
      card = Card.create!(summary: "Receipt from Stripe")
      Secretary.new.place(card, "placement" => "hold", "hold_until" => NOW.change(hour: 18).iso8601)
    end
    hourly = travel_to(NOW) { Accountant.account("hourly", NOW) }
    assert_match(/Held on arrival until .*: Receipt from Stripe/, hourly.stats["secretary"].sole)
    assert_match "Receipt from Stripe", hourly.stats["held_now"].sole
  end

  test "daily digests roll up the hours and become a card held until morning" do
    day = Time.zone.local(2026, 9, 28)
    Accounting.create!(period: "hourly", starts_at: day + 9.hours, ends_at: day + 10.hours, body: "Quiet morning.")
    Accounting.create!(period: "hourly", starts_at: day - 1.hour, ends_at: day, body: "Yesterday, not today.")

    just_after_midnight = Time.zone.local(2026, 9, 29, 0, 2)
    daily = travel_to(just_after_midnight) { Accountant.account("daily", just_after_midnight) }

    assert_equal [ "Quiet morning." ], Accounting.within("daily", daily.starts_at, daily.ends_at).map(&:body)
    card = daily.card
    assert_equal [ "digest", "acknowledge" ], [ card.card_type, card.ask ]
    assert card.held?
    assert_equal Time.zone.local(2026, 9, 29, 8), card.hold_until
  end

  test "longer periods report while cards wait, even with nothing new" do
    travel_to(NOW - 3.days) { Card.create!(summary: "Old thing") }
    daily = travel_to(NOW) { Accountant.account("daily", NOW) }
    assert_equal 1, daily.stats["stale_now"]
    assert_match "oldest: Old thing", daily.body
    assert daily.card.live?, "delivered by day, not held"
  end

  test "run catches up each period's latest window, shortest first, once" do
    travel_to(NOW - 3.days) { Card.create!(summary: "Old thing") }
    month_start = Time.zone.local(2026, 10, 1, 0, 2)
    written = travel_to(month_start) { Accountant.run(month_start) }
    assert_equal %w[daily weekly monthly], written.map(&:period)
    assert_equal [ Time.zone.local(2026, 9, 21), Time.zone.local(2026, 9, 1) ], written.drop(1).map(&:starts_at)

    assert_empty travel_to(month_start + 1.hour) { Accountant.run(month_start + 1.hour) }
  end

  test "repeated deferrals of the same card show up as drift" do
    travel_to(NOW.change(hour: 9, min: 5)) do
      card = Card.create!(summary: "Call the accountant")
      2.times { Gestures.top_of_stack(card) }
    end
    hourly = travel_to(NOW) { Accountant.account("hourly", NOW) }
    assert_equal [ "Call the accountant (2x)" ], hourly.stats["deferred"]
  end

  test "digest cards take no stamps and are read, then acknowledged" do
    travel_to(NOW - 3.days) { Card.create!(summary: "Old thing") }
    card = travel_to(NOW) { Accountant.account("daily", NOW) }.card
    assert_empty StampTray.for(card).shown
    Gestures.reply(card, "")
    assert card.reload.handled?
  end
end
