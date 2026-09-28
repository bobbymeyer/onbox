require "test_helper"

class DeferralParserTest < ActiveSupport::TestCase
  NOW = Time.zone.local(2026, 9, 28, 11, 30) # a Monday morning

  def parse(text, now: NOW) = DeferralParser.parse(text, now: now)

  test "durations" do
    assert_equal NOW + 2.hours, parse("2h")
    assert_equal NOW + 30.minutes, parse("in 30 minutes")
    assert_equal NOW + 1.hour, parse("an hour")
    assert_equal NOW + 1.week, parse("1 week")
  end

  test "times of day" do
    assert_equal NOW.change(hour: 14), parse("this afternoon")
    assert_equal NOW.change(hour: 18), parse("tonight")
    assert_equal (NOW + 1.day).change(hour: 9), parse("tomorrow")
  end

  test "tonight when it is already evening stays tonight" do
    late = NOW.change(hour: 20)
    assert_equal late + 2.hours, parse("tonight", now: late)
  end

  test "weekdays land on the next one, never today" do
    assert_equal Time.zone.local(2026, 10, 2, 9), parse("friday")
    assert_equal Time.zone.local(2026, 10, 5, 9), parse("monday")
    assert_equal Time.zone.local(2026, 10, 5, 9), parse("next week")
  end

  test "unreadable text is left for the secretary" do
    assert_nil parse("after my 3pm")
    assert_nil parse("")
  end
end
