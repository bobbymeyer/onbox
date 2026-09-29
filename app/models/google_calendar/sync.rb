module GoogleCalendar
  # Polls one calendar and pushes what needs Bobby through the intake:
  #   invitation - he hasn't answered (one card per series);
  #   moved      - a meeting he's going to changed time;
  #   cancelled  - a meeting he's going to was called off.
  # Everything else (his own edits, answered invites, the past) stays out.
  # It remembers the upcoming meetings he's going to, so it can tell what moved.
  module Sync
    OVERLAP = 5.minutes
    FIRST_LOOKBACK = 1.day
    HORIZON = 60.days

    module_function

    def call(source, calendar: Calendar.new(source), now: Time.current)
      raise ArgumentError, "#{source.name} is not connected to Google Calendar" unless source.connected?

      since = (source.last_polled_at || now - FIRST_LOOKBACK) - OVERLAP
      known = source.settings.fetch("known_events", {})
      agenda = calendar.agenda(from: now, to: now + HORIZON)

      changes = calendar.changed(since: since).filter_map { |event| classify(event, known, now) }
      cards = changes.sort_by { |event| event["start"].to_s }.uniq { |event| [ event["change"], event["change"] == "invitation" ? event["series_id"] : event["event_id"] ] }
        .reject { |event| seen?(event) }
        .map { |event| Intake.receive(source, event.merge("conflicts" => conflicts(event, agenda))) }

      source.update!(settings: source.settings.merge(
        "last_polled_at" => now.iso8601, "last_error" => nil,
        "known_events" => agenda.select { |e| going?(e) }.to_h { |e| [ e["event_id"], e.slice("summary", "start") ] }
      ))
      cards
    rescue Google::Apis::Error, Signet::AuthorizationError => e
      source.update!(settings: source.settings.merge("last_error" => "#{e.class}: #{e.message}".truncate(500)))
      raise
    end

    def classify(event, known, now)
      before = known[event["event_id"]]
      if event["status"] == "cancelled"
        return unless before && Time.zone.parse(before["start"].to_s)&.future?
        return event.merge("change" => "cancelled", "summary" => before["summary"], "start" => before["start"], "was" => before["start"])
      end
      return if event["end"] && Time.zone.parse(event["end"]) < now

      if event["self_response"] == "needsAction" && !event["organizer_self"]
        event.merge("change" => "invitation")
      elsif before && before["start"] != event["start"] && going?(event) && !event["organizer_self"]
        event.merge("change" => "moved", "was" => before["start"])
      end
    end

    # Accepted or maybe, or his own meeting with no guest list.
    def going?(event)
      %w[accepted tentative].include?(event["self_response"]) || (event["self_response"].nil? && event["organizer_self"])
    end

    # Timed meetings he's going to that overlap this one.
    def conflicts(event, agenda)
      return [] if event["all_day"] || event["change"] == "cancelled"
      starts, ends = Time.zone.parse(event["start"].to_s), Time.zone.parse(event["end"].to_s)
      return [] unless starts && ends

      agenda.select do |other|
        next false if other["all_day"] || other["series_id"] == event["series_id"] || !going?(other)
        Time.zone.parse(other["start"]) < ends && Time.zone.parse(other["end"]) > starts
      end.map { |other| "#{other["summary"]} (#{Time.zone.parse(other["start"]).strftime("%H:%M")}–#{Time.zone.parse(other["end"]).strftime("%H:%M")})" }
    end

    def seen?(event)
      Card.where("json_extract(payload, '$.event_id') = ? AND json_extract(payload, '$.updated') = ? AND json_extract(payload, '$.change') = ?",
                 event["event_id"], event["updated"], event["change"]).exists?
    end
  end
end
