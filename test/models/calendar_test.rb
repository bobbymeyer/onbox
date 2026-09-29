require "test_helper"

class CalendarTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  NOW = Time.zone.local(2026, 9, 29, 10)
  G = Google::Apis::CalendarV3

  def sync(changed: [], agenda: [], now: NOW)
    source = connect(sources(:calendar))
    travel_to(now) { GoogleCalendar::Sync.call(source, calendar: FakeCalendar.new(changed: changed, agenda: agenda), now: now) }
  end

  test "normalizes timed, all-day and recurring events, and finds Bobby on the guest list" do
    me = G::EventAttendee.new(email: "bobby@x.com", self: true, response_status: "needsAction")
    timed = G::Event.new(id: "ev1_20261001", recurring_event_id: "ev1", summary: "Standup", status: "confirmed",
                         start: G::EventDateTime.new(date_time: DateTime.new(2026, 10, 1, 9)),
                         end: G::EventDateTime.new(date_time: DateTime.new(2026, 10, 1, 9, 15)),
                         organizer: G::Event::Organizer.new(display_name: "Ada"), attendees: [ me ],
                         description: "<b>Agenda</b> inside")
    n = GoogleCalendar::Event.normalize(timed)
    assert_equal [ "ev1", true, "needsAction", "Ada", false, "Agenda inside" ],
                 n.values_at("series_id", "recurring", "self_response", "organizer", "all_day", "description")

    all_day = G::Event.new(id: "hol", start: G::EventDateTime.new(date: "2026-10-02"), end: G::EventDateTime.new(date: "2026-10-03"))
    assert GoogleCalendar::Event.normalize(all_day)["all_day"]
  end

  test "an invitation becomes a decision card with its clashes" do
    clash = calendar_event(event_id: "other", series_id: "other", summary: "1:1 with Grace", self_response: "accepted",
                           start: Time.zone.local(2026, 10, 1, 15, 30).iso8601, end: Time.zone.local(2026, 10, 1, 16, 30).iso8601)
    card = sync(changed: [ calendar_event ], agenda: [ clash ]).sole

    assert_equal [ "calendar", "decision", "Design review", "Ada Lovelace", "calendar:series:ev1" ],
                 card.values_at(:card_type, :ask, :summary, :project, :key)
    assert_equal [ "1:1 with Grace (15:30–16:30)" ], card.payload["conflicts"]
    assert_match "Thu 1 Oct, 15:00–16:00", card.payload["body"]
  end

  test "a recurring invitation is one card for the series; answered, own and past events stay out" do
    instances = (0..3).map { |i| calendar_event(event_id: "wk_#{i}", series_id: "wk", recurring: true, start: (NOW + (i + 1).weeks).iso8601, end: (NOW + (i + 1).weeks + 1.hour).iso8601) }
    others = [
      calendar_event(event_id: "yes", series_id: "yes", self_response: "accepted"),
      calendar_event(event_id: "mine", series_id: "mine", organizer_self: true),
      calendar_event(event_id: "old", series_id: "old", start: (NOW - 2.hours).iso8601, end: (NOW - 1.hour).iso8601)
    ]
    cards = sync(changed: instances.reverse + others)
    assert_equal [ "calendar:series:wk" ], cards.map(&:key)
    assert_equal "wk_0", cards.sole.payload["event_id"], "the next occurrence represents the series"
  end

  test "the same change isn't carded twice" do
    sync(changed: [ calendar_event ])
    Card.last.handle!(with: "done")
    assert_empty sync(changed: [ calendar_event ], now: NOW + 5.minutes)
  end

  test "meetings Bobby is going to that move or get cancelled become heads-ups" do
    going = [ calendar_event(self_response: "accepted"), calendar_event(event_id: "ev2", series_id: "ev2", summary: "Lunch", self_response: "accepted") ]
    sync(agenda: going) # learns what he's going to
    assert_equal %w[ev1 ev2], sources(:calendar).reload.settings["known_events"].keys

    moved = calendar_event(self_response: "accepted", updated: "2026-09-29T11:00:00Z",
                           start: Time.zone.local(2026, 10, 2, 11).iso8601, end: Time.zone.local(2026, 10, 2, 12).iso8601)
    cancelled = { "event_id" => "ev2", "series_id" => "ev2", "status" => "cancelled", "updated" => "2026-09-29T11:00:00Z" }
    cards = sync(changed: [ moved, cancelled ], now: NOW + 1.hour)

    assert_equal [ "Cancelled: Lunch", "Moved: Design review" ].sort, cards.map(&:summary).sort
    cards = cards.sort_by(&:summary).reverse
    assert cards.all? { |c| c.ask == "acknowledge" }
    assert_match "Fri 2 Oct, 11:00–12:00 (was Thu 1 Oct, 15:00)", cards.first.payload["body"]
  end

  test "RSVP stamps answer with Bobby's note, never the secretary's advice" do
    card = sync(changed: [ calendar_event ]).sole
    card.update!(proposed_action: "Accept: no clashes.")

    assert_enqueued_with job: CalendarActionJob, args: [ card, "accept", nil ] do
      Gestures.stamp(card, stamps(:accept))
    end

    other = sync(changed: [ calendar_event(event_id: "ev9", series_id: "ev9") ]).sole
    assert_enqueued_with job: CalendarActionJob, args: [ other, "decline", "Traveling that week" ] do
      Gestures.stamp(other, stamps(:decline), text: "Traveling that week")
    end
  end

  test "RSVP stamps live in the card's tool, not the tray; heads-ups can't be answered" do
    card = sync(changed: [ calendar_event ]).sole
    assert_empty StampTray.for(card).shown, "Accept/Maybe/Decline are in the tool; Done is \"Handled without answering\""

    heads_up = Card.create!(card_type: "calendar", summary: "Cancelled: Lunch", payload: { "change" => "cancelled" })
    assert_no_enqueued_jobs(only: CalendarActionJob) { Gestures.stamp(heads_up, stamps(:accept)) }
  end

  test "the action job answers in Google Calendar, or reports why it couldn't" do
    card = sync(changed: [ calendar_event ]).sole
    calendar = FakeCalendar.new
    with_stub(GoogleCalendar::Calendar, :new, calendar) { CalendarActionJob.perform_now(card, "tentative", "Might be late") }
    assert_equal [ [ "ev1", "tentative", "Might be late" ] ], calendar.responses

    sources(:calendar).update!(secret: nil)
    CalendarActionJob.perform_now(card.reload, "accept")
    assert_match "no connected calendar", card.children.sole.summary
  end

  test "respond patches Bobby's own RSVP on the whole series and notifies everyone" do
    me = G::EventAttendee.new(email: "bobby@x.com", self: true, response_status: "needsAction")
    ada = G::EventAttendee.new(email: "ada@x.com", response_status: "accepted")
    patched = []
    service = Object.new
    service.define_singleton_method(:get_event) { |_cal, _id| G::Event.new(summary: "Standup", attendees: [ me, ada ]) }
    service.define_singleton_method(:patch_event) { |cal, id, event, send_updates:| patched << [ cal, id, event, send_updates ] }

    calendar = GoogleCalendar::Calendar.new(sources(:calendar))
    calendar.instance_variable_set(:@service, service)
    calendar.respond({ "event_id" => "wk_0", "series_id" => "wk" }, "decline", "Out that week")

    cal, id, event, send_updates = patched.sole
    assert_equal [ "primary", "wk", "all" ], [ cal, id, send_updates ]
    assert_equal [ [ "declined", "Out that week" ], [ "accepted", nil ] ], event.attendees.map { |a| [ a.response_status, a.comment ] }
  end

  test "Google sign-in reads the pasted address and checks it belongs to this sign-in" do
    GoogleOauth.configure!("client-id.apps.googleusercontent.com", "shh")
    assert_equal "client-id.apps.googleusercontent.com", GoogleOauth.client_id
    assert_match "scope=https://www.googleapis.com/auth/calendar.events", CGI.unescape(GoogleOauth.url("calendar", state: "abc"))
    assert_not_includes Credential.connection.select_values("SELECT secret FROM credentials").join, "shh"

    assert_raises(ArgumentError, match: /different sign-in/) { GoogleOauth.exchange("calendar", "http://localhost:8765/?state=zzz&code=1", state: "abc") }
    assert_raises(ArgumentError, match: /no code/) { GoogleOauth.exchange("calendar", "http://localhost:8765/?state=abc", state: "abc") }
  end
end
