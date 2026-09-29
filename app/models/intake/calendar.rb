module Intake
  # One calendar change from the Mac's Calendar (see MacCalendar::Sync).
  module Calendar
    LABELS = { "moved" => "Moved", "cancelled" => "Cancelled" }.freeze

    def self.call(source, payload)
      change = payload["change"].to_s
      invitation = change == "invitation"
      key = invitation ? "series:#{payload["series_id"]}" : "#{change}:#{payload["event_id"]}"

      Event.new(
        key: "#{source.name}:#{key}",
        project: payload["organizer"],
        summary: [ LABELS[change], payload["summary"] ].compact.join(": "),
        ask: invitation ? "decision" : "acknowledge",
        body: [ When.describe(payload), payload["location"], payload["description"] ].compact_blank.join("\n\n"),
        payload: payload,
        event_keys: [ source.name, "#{source.name}:#{change}" ]
      )
    end
  end
end
