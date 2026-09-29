require "google/apis/calendar_v3"

module GoogleCalendar
  # The only code that talks to Google Calendar. Everything else sees hashes.
  class Calendar
    RESPONSES = { "accept" => "accepted", "tentative" => "tentative", "decline" => "declined" }.freeze

    def initialize(source)
      @source = source
    end

    # Events on the primary calendar changed since the given time, including
    # cancellations, from yesterday on. Recurring events come as instances.
    def changed(since:)
      items(updated_min: since.iso8601, show_deleted: true, single_events: true,
            time_min: 1.day.ago.iso8601, max_results: 250)
    end

    # What Bobby is expected at in a window: not cancelled, not declined.
    def agenda(from:, to:)
      items(time_min: from.iso8601, time_max: to.iso8601, single_events: true, order_by: "startTime", max_results: 250)
        .reject { |e| e["status"] == "cancelled" || e["self_response"] == "declined" }
    end

    # RSVP for the event (the whole series, for a recurring one), with an
    # optional note to the organizer. Everyone is notified.
    def respond(payload, kind, note = nil)
      id = payload["series_id"].presence || payload["event_id"]
      event = service.get_event("primary", id)
      me = Array(event.attendees).find(&:self) or raise ArgumentError, "you aren't on the guest list of \"#{event.summary}\""
      me.response_status = RESPONSES.fetch(kind)
      me.comment = note if note.present?
      service.patch_event("primary", id, Google::Apis::CalendarV3::Event.new(attendees: event.attendees), send_updates: "all")
    end

    private
      def items(**query)
        Array(service.list_events("primary", **query).items).map { |e| Event.normalize(e) }
      end

      def service
        @service ||= Google::Apis::CalendarV3::CalendarService.new.tap do |s|
          s.authorization = GoogleOauth.credentials("calendar", @source.secret)
        end
      end
  end
end
