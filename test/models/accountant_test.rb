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

  def work_a_card(at, summary: "Print finished")
    travel_to(at) do
      card = Card.create!(summary: summary, source: sources(:printer))
      Gestures.stamp(card, stamps(:done))
      card
    end
  end

  test "an hour Bobby worked gets a digest; an hour he didn't gets none" do
    work_a_card(NOW.change(hour: 9, min: 30))

    travel_to(NOW) do
      hourly = Accountant.account("hourly", NOW)
      assert_equal 1, hourly.stats["handled_count"]
      assert_equal({ "printer" => 1 }, hourly.stats["arrived"])
      assert_match "Handled 1 (1 Done)", hourly.body
      assert_nil hourly.card, "hourly digests stay off the stack"
      assert_nil Accountant.account("hourly", NOW), "written once"
    end
  end

  test "arrivals and the secretary's own moves alone don't make a report" do
    travel_to(NOW.change(hour: 9, min: 10)) do
      card = Card.create!(summary: "Receipt from Stripe", source: sources(:printer))
      Secretary.new.place(card, "placement" => "hold", "hold_until" => NOW.change(hour: 18).iso8601)
    end
    travel_to(NOW) { assert_nil Accountant.account("hourly", NOW) }
  end

  test "an inactive day gets no report, even with cards waiting" do
    travel_to(NOW - 3.days) { Card.create!(summary: "Old thing") }
    travel_to(NOW) { assert_empty Accountant.run(NOW) }
  end

  test "the secretary's own actions are accounted for" do
    travel_to(NOW.change(hour: 9, min: 10)) do
      card = Card.create!(summary: "Receipt from Stripe")
      Secretary.new.place(card, "placement" => "hold", "hold_until" => NOW.change(hour: 18).iso8601)
    end
    work_a_card(NOW.change(hour: 9, min: 20))
    hourly = travel_to(NOW) { Accountant.account("hourly", NOW) }
    assert_match(/Held on arrival until .*: Receipt from Stripe/, hourly.stats["secretary"].sole)
    assert_match "Receipt from Stripe", hourly.stats["held_now"].sole
  end

  test "daily digests roll up the hours" do
    day = Time.zone.local(2026, 9, 28)
    work_a_card(day + 9.hours + 30.minutes)
    Accounting.create!(period: "hourly", starts_at: day + 9.hours, ends_at: day + 10.hours, body: "Quiet morning.")
    Accounting.create!(period: "hourly", starts_at: day - 1.hour, ends_at: day, body: "Yesterday, not today.")

    daily = travel_to(NOW) { Accountant.account("daily", NOW) }
    assert_equal [ "Quiet morning." ], Accounting.within("daily", daily.starts_at, daily.ends_at).map(&:body)
    assert_equal [ "digest", "acknowledge" ], daily.card.values_at(:card_type, :ask)
  end

  test "done for the night: the digest waits for Bobby's next gesture" do
    work_a_card(Time.zone.local(2026, 9, 28, 21, 0))
    midnight = Time.zone.local(2026, 9, 29, 0, 2)
    card = travel_to(midnight) { Accountant.account("daily", midnight) }.card
    assert card.held?
    assert_nil Card.current

    travel_to(Time.zone.local(2026, 9, 29, 7, 45)) do
      morning = Card.create!(summary: "First email")
      assert_equal morning, Card.current
      Gestures.flip(morning)
      assert card.reload.live?, "his first gesture brings it in"
    end
  end

  test "still clocking cards: the digest lands now, however late" do
    work_a_card(Time.zone.local(2026, 9, 28, 23, 50))
    after_midnight = Time.zone.local(2026, 9, 29, 0, 2)
    card = travel_to(after_midnight) { Accountant.account("daily", after_midnight) }.card
    assert card.live?
  end

  test "run catches up each period's latest window, shortest first, once" do
    work_a_card(Time.zone.local(2026, 9, 25, 15)) # in the week of 21 Sep
    work_a_card(Time.zone.local(2026, 9, 30, 15)) # the last day of the month
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
    work_a_card(NOW - 3.hours)
    card = travel_to(NOW) { Accountant.account("daily", NOW + 1.day) }.card
    assert_empty StampTray.for(card).shown
    Gestures.reply(card, "")
    assert card.reload.handled?
  end
end
