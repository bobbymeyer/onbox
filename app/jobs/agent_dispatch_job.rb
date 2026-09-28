# Handling an agent card sends the instruction back to the session. The agent's
# next Stop hook brings the result back as a fresh card. A failed send comes
# back as a card too, so nothing drops silently.
class AgentDispatchJob < ApplicationJob
  queue_as :default

  def perform(card, instruction)
    session_id = card.payload["session_id"]
    if session_id.blank?
      return report_failure(card, instruction, "Card has no session_id to send to.")
    end

    output, ok = AgentDispatch.call(session_id: session_id, instruction: instruction, cwd: card.payload["cwd"])
    report_failure(card, instruction, output) unless ok
  end

  private
    def report_failure(card, instruction, output)
      Card.create!(
        source: card.source,
        parent_card: card,
        card_type: "generic",
        project: card.project,
        summary: "Couldn't send instruction to #{card.project.presence || "agent"}",
        ask: "review",
        proposed_action: nil,
        payload: card.payload.slice("session_id", "cwd").merge("instruction" => instruction, "body" => output.to_s.last(4000))
      )
    end
end
