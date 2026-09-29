module Intake
  # One reminder from the Mac's Reminders (see MacReminders::Sync).
  module Reminder
    def self.key(source, payload) = "#{source.name}:reminder:#{payload["reminder_id"]}"

    def self.call(source, payload)
      due = Time.zone.parse(payload["due"].to_s)
      Event.new(
        key: key(source, payload),
        project: payload["list"],
        summary: payload["title"].to_s.truncate(200),
        ask: "review",
        body: [ due && "Due #{due.strftime(payload["all_day_due"] ? "%a %-d %b" : "%a %-d %b, %H:%M")}", payload["notes"], payload["url"] ].compact_blank.join("\n\n"),
        payload: payload,
        event_keys: [ source.name ]
      )
    end
  end
end
