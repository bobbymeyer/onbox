module Intake
  # Anything else: a cron, a print server, a failed build. The source states
  # what it knows; missing fields are left for the secretary.
  #
  #   { "summary": "Print finished", "project": "shop", "ask": "acknowledge",
  #     "body": "...", "key": "printer:job-42", "event": "print.done" }
  module Generic
    def self.call(source, payload)
      Event.new(
        key: payload["key"].presence && "#{source.name}:#{payload["key"]}",
        project: payload["project"],
        summary: (payload["summary"] || payload["title"]).to_s.truncate(200).presence,
        ask: Card::ASKS.include?(payload["ask"]) ? payload["ask"] : "acknowledge",
        proposed_action: payload["proposed_action"],
        body: payload["body"] || payload["message"],
        payload: payload,
        event_keys: [ "#{source.name}", payload["event"].presence && "#{source.name}:#{payload["event"]}" ].compact
      )
    end
  end
end
