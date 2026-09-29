module MacCalendar
  # Reads the Mac's Calendar (Google and any other accounts it syncs) and
  # pushes what needs Bobby through the intake:
  #   invitation - he hasn't answered (one card per series). onbox can't
  #                answer invitations (Apple offers no way to), so he answers
  #                in Calendar and the card clears itself once that syncs;
  #   moved      - a meeting he's going to changed time;
  #   cancelled  - a meeting he's going to was called off or removed.
  # It remembers his upcoming meetings between polls to tell what changed.
  module Sync
    LOOKBACK = 1.day
    HORIZON = 60.days
    ANSWERED = "answered in Calendar".freeze

    module_function

    def call(source, kit: MacEventKit, now: Time.current)
      events = kit.events(from: now - LOOKBACK, to: now + HORIZON)
      current = events.index_by { |e| e["event_id"] }
      known = source.settings.fetch("known_events", {})

      changes = events.filter_map { |event| classify(event, known, now) } + removed(known, current, now)
      cards = changes.sort_by { |e| e["start"].to_s }
        .uniq { |e| e["change"] == "invitation" ? [ "invitation", e["series_id"] ] : [ e["change"], e["event_id"] ] }
        .reject { |e| seen?(e) }
        .map { |e| Intake.receive(source, e.merge("conflicts" => conflicts(e, events))) }

      clear_answered(source, events)
      source.update!(settings: source.settings.merge(
        "last_polled_at" => now.iso8601, "last_error" => nil,
        "known_events" => events.select { |e| going?(e) && future?(e["start"], now) }.to_h { |e| [ e["event_id"], e.slice("summary", "start", "series_id") ] }
      ))
      cards
    rescue MacEventKit::Error => e
      source.update!(settings: source.settings.merge("last_error" => e.message))
      raise
    end

    def classify(event, known, now)
      before = known[event["event_id"]]
      return unless future?(event["end"], now)

      if event["status"] == "cancelled"
        event.merge("change" => "cancelled", "was" => before["start"]) if before
      elsif pending?(event)
        event.merge("change" => "invitation")
      elsif before && before["start"] != event["start"] && going?(event) && !event["organizer_self"]
        event.merge("change" => "moved", "was" => before["start"])
      end
    end

    # Meetings he was going to that are no longer on the calendar at all.
    def removed(known, current, now)
      known.filter_map do |id, before|
        next if current.key?(id) || !future?(before["start"], now)
        { "event_id" => id, "series_id" => before["series_id"], "summary" => before["summary"],
          "start" => before["start"], "was" => before["start"], "status" => "cancelled", "change" => "cancelled" }
      end
    end

    def pending?(event)
      event["self_response"] == "pending" && !event["organizer_self"] && event["status"] != "cancelled"
    end

    # Accepted or maybe, or on his calendar with no guest list.
    def going?(event)
      event["status"] != "cancelled" &&
        (%w[accepted tentative].include?(event["self_response"]) || (event["self_response"].nil? && Array(event["attendees"]).empty?))
    end

    def future?(time, now)
      (t = Time.zone.parse(time.to_s)) && t > now
    end

    # Timed meetings he's going to that overlap this one.
    def conflicts(event, events)
      return [] if event["all_day"] || event["change"] == "cancelled"
      starts, ends = Time.zone.parse(event["start"].to_s), Time.zone.parse(event["end"].to_s)
      return [] unless starts && ends

      events.select do |other|
        next false if other["all_day"] || other["series_id"] == event["series_id"] || !going?(other)
        Time.zone.parse(other["start"]) < ends && Time.zone.parse(other["end"]) > starts
      end.map { |o| "#{o["summary"]} (#{Time.zone.parse(o["start"]).strftime("%H:%M")}–#{Time.zone.parse(o["end"]).strftime("%H:%M")})" }
    end

    # An invitation card clears itself once no occurrence is still unanswered.
    def clear_answered(source, events)
      waiting = events.select { |e| pending?(e) }.map { |e| e["series_id"] }.to_set
      source.cards.open.where(card_type: "calendar").find_each do |card|
        next unless card.payload["change"] == "invitation" && waiting.exclude?(card.payload["series_id"])
        card.handle!(with: ANSWERED)
      end
    end

    def seen?(event)
      field = event["change"] == "invitation" ? "series_id" : "event_id"
      Card.where("json_extract(payload, '$.#{field}') = ? AND json_extract(payload, '$.change') = ? AND json_extract(payload, '$.start') = ?",
                 event[field], event["change"], event["start"]).exists?
    end
  end
end
