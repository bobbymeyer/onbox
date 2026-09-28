# The common event every webhook payload is normalized into. The intake writes
# a card's front from it; the secretary then rewrites the front with judgment.
module Intake
  Event = Data.define(:key, :project, :summary, :ask, :proposed_action, :body, :payload, :event_keys) do
    def initialize(key: nil, project: nil, summary: nil, ask: "acknowledge", proposed_action: nil, body: nil, payload: {}, event_keys: [])
      super
    end
  end
end
