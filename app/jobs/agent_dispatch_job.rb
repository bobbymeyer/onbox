# Handling an agent card sends the instruction back to the session. The agent's
# next Stop hook brings the result back as a fresh card. A failed send comes
# back as a card too, so nothing drops silently.
class AgentDispatchJob < ApplicationJob
  queue_as :default

  def perform(card, instruction)
    session_id = card.payload["session_id"]
    return report(card, instruction, "Card has no session_id to send to.") if session_id.blank?

    output, ok = AgentDispatch.call(session_id: session_id, instruction: instruction, cwd: card.payload["cwd"])
    report(card, instruction, output) unless ok
  end

  private
    def report(card, instruction, output)
      card.report_failure!("Couldn't send instruction to #{card.project.presence || "agent"}", output, instruction: instruction)
    end
end
