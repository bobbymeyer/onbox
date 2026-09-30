require "test_helper"

class CalendarTest < ActiveSupport::TestCase
  NOW = Time.zone.local(2026, 9, 29, 10)

  def sync(events, now: NOW)
    travel_to(now) { MacCalendar::Sync.call(sources(:calendar), kit: FakeKit.new(events: events), now: now) }
  end

  def going(**overrides) = calendar_event(self_response: "accepted", **overrides)

  test "an unanswered invitation becomes a decision card with its clashes" do
    clash = going(event_id: "other", series_id: "other", summary: "1:1 with Grace",
                  start: Time.zone.local(2026, 10, 1, 15, 30).iso8601, end: Time.zone.local(2026, 10, 1, 16, 30).iso8601)
    card = sync([ calendar_event, clash ]).sole

    assert_equal [ "calendar", "decision", "Design review", "Ada Lovelace", "calendar:series:ev1" ],
                 card.values_at(:card_type, :ask, :summary, :project, :key)
    assert_equal [ "1:1 with Grace (15:30–16:30)" ], card.payload["conflicts"]
  end

  test "a recurring invitation is one card; answered, own and past events stay out" do
    instances = (0..3).map { |i| calendar_event(event_id: "wk_#{i}", series_id: "wk", recurring: true, start: (NOW + (i + 1).weeks).iso8601, end: (NOW + (i + 1).weeks + 1.hour).iso8601) }
    others = [
      going(event_id: "yes", series_id: "yes"),
      calendar_event(event_id: "mine", series_id: "mine", organizer_self: true),
      calendar_event(event_id: "old", series_id: "old", start: (NOW - 2.hours).iso8601, end: (NOW - 1.hour).iso8601)
    ]
    cards = sync(instances.reverse + others)
    assert_equal [ "calendar:series:wk" ], cards.map(&:key)
    assert_equal "wk_0", cards.sole.payload["event_id"]
  end

  test "polling again doesn't re-card or re-top an invitation" do
    card = sync([ calendar_event ]).sole
    later = Card.create!(summary: "newer")
    assert_empty sync([ calendar_event ], now: NOW + 2.minutes)
    assert_operator card.reload.position, :<, later.position
  end

  test "the card clears itself once Bobby answers in Calendar" do
    card = sync([ calendar_event ]).sole
    sync([ going ], now: NOW + 2.minutes)
    assert card.reload.handled?
    assert_equal "answered in Calendar", card.handled_with
  end

  test "meetings Bobby is going to that move, get cancelled or disappear become heads-ups" do
    lunch = going(event_id: "ev2", series_id: "ev2", summary: "Lunch")
    gym = going(event_id: "ev3", series_id: "ev3", summary: "Gym")
    sync([ going, lunch, gym ])

    moved = going(start: Time.zone.local(2026, 10, 2, 11).iso8601, end: Time.zone.local(2026, 10, 2, 12).iso8601)
    cards = sync([ moved, lunch.merge("status" => "cancelled") ], now: NOW + 1.hour)

    assert_equal [ "Cancelled: Gym", "Cancelled: Lunch", "Moved: Design review" ], cards.map(&:summary).sort
    assert cards.all? { |c| c.ask == "acknowledge" }
    assert_match "Fri 2 Oct, 11:00–12:00 (was Thu 1 Oct, 15:00)", cards.find { |c| c.summary.start_with?("Moved") }.payload["body"]
  end

  test "Later reads the calendar so the secretary can resolve 'after my 3pm'" do
    with_stub(MacEventKit, :available?, true) do
      with_stub(MacEventKit, :events, [ going(summary: "Design review") ]) do
        assert_equal "- Thu 1 Oct, 15:00–16:00: Design review", Secretary.new.send(:agenda_text, NOW)
      end
    end
  end

  test "a calendar card points to Calendar for the answer" do
    card = sync([ calendar_event ]).sole
    assert_empty StampTray.for(card).shown.map(&:label) & %w[Accept Decline]
    assert_not card.type.decomposable?
  end
end

class RemindersTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  NOW = CalendarTest::NOW

  def sync(reminders, now: NOW)
    travel_to(now) { MacReminders::Sync.call(sources(:reminders), kit: FakeKit.new(reminders: reminders), now: now) }
  end

  test "due reminders from any list, and everything in the Stack list, become cards" do
    cards = sync([
      reminder(reminder_id: "due", title: "Pay rent", due: (NOW - 1.hour).iso8601),
      reminder(reminder_id: "later", title: "Call mom", due: (NOW + 1.day).iso8601),
      reminder(reminder_id: "someday", title: "Learn piano"),
      reminder(reminder_id: "stack", title: "Order filament", list: "Stack")
    ])
    assert_equal [ "Pay rent", "Order filament" ], cards.map(&:summary)
    assert_equal [ "reminder", "Personal", "review" ], cards.first.values_at(:card_type, :project, :ask)
  end

  test "the Stack list name is configurable" do
    sources(:reminders).update!(settings: { "list" => "Inbox" })
    assert_equal [ "Sort mail" ], sync([ reminder(title: "Sort mail", list: "Inbox") ]).map(&:summary)
  end

  test "polling again doesn't duplicate a reminder already in the stack" do
    due = reminder(due: (NOW - 1.hour).iso8601)
    sync([ due ])
    assert_empty sync([ due ], now: NOW + 2.minutes)
  end

  test "Done completes the reminder; Later moves its due time" do
    card = sync([ reminder(list: "Stack") ]).sole
    assert_enqueued_with(job: ReminderActionJob, args: [ card, "complete" ]) { Gestures.reply(card, "") }

    other = sync([ reminder(reminder_id: "r2", list: "Stack") ]).sole
    travel_to(NOW) do
      assert_enqueued_with(job: ReminderActionJob, args: [ other, "reschedule", (NOW + 2.hours).iso8601 ]) { Gestures.later(other, "2h") }
    end
  end

  test "the action job talks to Reminders, or reports why it couldn't" do
    card = sync([ reminder(list: "Stack") ]).sole
    completed = []
    original = MacEventKit.method(:complete)
    MacEventKit.define_singleton_method(:complete) { |id| completed << id }
    ReminderActionJob.perform_now(card, "complete")
    assert_equal [ "r1" ], completed

    MacEventKit.define_singleton_method(:complete) { |_id| raise MacEventKit::Error, "no reminder r1" }
    ReminderActionJob.perform_now(card, "complete")
    assert_match "Couldn't complete", card.children.sole.summary
  ensure
    MacEventKit.define_singleton_method(:complete, original)
  end

  test "a reminder completed elsewhere clears its card" do
    card = sync([ reminder(list: "Stack") ]).sole
    sync([], now: NOW + 2.minutes)
    assert_equal "completed in Reminders", card.reload.handled_with
  end

  test "decomposing a reminder makes plain cards, so a step doesn't complete it" do
    card = sync([ reminder(list: "Stack", title: "Plan trip") ]).sole
    step = Gestures.decompose(card, [ { "summary" => "Book flights" } ]).sole
    assert_equal "generic", step.card_type
    assert_nil step.payload["reminder_id"]
    assert_no_enqueued_jobs(only: ReminderActionJob) { Gestures.reply(step, "") }
  end
end

class MacEventKitTest < ActiveSupport::TestCase
  test "talks JSON to the helper and reports its errors" do
    helper = Rails.root.join("tmp/fake_eventkit_#{SecureRandom.hex(3)}").to_s
    File.write(helper, <<~SH)
      #!/bin/sh
      case "$1" in
        access) echo '{"calendar":"granted","reminders":"denied"}' ;;
        mail-access) echo '{"mail":"granted"}' ;;
        mail-unread) sleep 5 ;;
        events) echo "[{\\"event_id\\":\\"e1\\",\\"from\\":\\"$2\\"}]" ;;
        *) echo "no reminder $2" >&2; exit 1 ;;
      esac
    SH
    File.chmod(0o755, helper)

    with_env("STACK_EVENTKIT_BIN" => helper) do
      assert MacEventKit.granted?("calendar")
      assert_not MacEventKit.granted?("reminders")
      assert_equal "2026-09-29T10:00:00Z", MacEventKit.events(from: Time.utc(2026, 9, 29, 10), to: Time.utc(2026, 9, 30)).sole["from"]
      assert_raises(MacEventKit::Error, match: /no reminder x/) { MacEventKit.complete("x") }
      assert MacEventKit.granted?("mail")
      assert_raises(MacEventKit::Error, match: /didn't answer mail-unread within 1s/) { MacEventKit.run("mail-unread", timeout: 1) }
    end
  ensure
    FileUtils.rm_f(helper)
  end

  test "off the Mac, it says so" do
    skip "running on a Mac" if RUBY_PLATFORM.include?("darwin")
    with_env("STACK_EVENTKIT_BIN" => nil) do
      assert_not MacEventKit.available?
      assert_raises(MacEventKit::Error, match: /on the Mac/) { MacEventKit.access }
    end
  end
end

class MacPollJobTest < ActiveSupport::TestCase
  test "says which sources it skipped because macOS hasn't allowed them" do
    log = StringIO.new
    original, Rails.logger = Rails.logger, ActiveSupport::Logger.new(log)
    with_stub(MacEventKit, :available?, true) do
      with_stub(MacEventKit, :granted?, false) { MacPollJob.perform_now }
    end
    assert_match "[mac] skipped calendar, mail, reminders: not allowed in macOS", log.string
  ensure
    Rails.logger = original
  end
end
