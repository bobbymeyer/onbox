module Intake
  # One email, already flattened (see Gmail::Message). The thread is the card's
  # key, so a thread holds one open card and a new message refreshes it.
  module Email
    def self.call(source, payload)
      sender = Mail::Address.new(payload["from"].to_s) rescue nil
      address = sender&.address&.downcase

      Event.new(
        key: payload["thread_id"].present? ? "#{source.name}:thread:#{payload["thread_id"]}" : nil,
        project: sender&.display_name.presence || address,
        summary: payload["subject"].presence || payload["snippet"].to_s.truncate(90).presence || "(no subject)",
        ask: "reply",
        body: payload["body"].presence || payload["snippet"],
        payload: payload,
        event_keys: [ source.name, address && "#{source.name}:from:#{address}" ].compact
      )
    end
  end
end
