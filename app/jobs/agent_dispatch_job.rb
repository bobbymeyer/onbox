# Handling an agent card sends the instruction back to the session. onbox
# resumes the session itself (ClaudeRun) and brings the reply back as a fresh
# card. With STACK_AGENT_COMMAND set, the command is run instead and the
# agent's Stop hook brings the result back. A failed send comes back as a
# card too, so nothing drops silently.
class AgentDispatchJob < ApplicationJob
  queue_as :default

  def perform(card, instruction)
    session_id = card.payload["session_id"]
    return report(card, instruction, "Card has no session_id to send to.") if session_id.blank?

    if ENV["STACK_AGENT_COMMAND"].present?
      output, ok = AgentDispatch.call(session_id: session_id, instruction: instruction, cwd: card.payload["cwd"])
      report(card, instruction, output) unless ok
    else
      cwd = card.payload["cwd"].presence
      cwd = Dir.home unless cwd && File.directory?(cwd)
      ClaudeRun.start!(prompt: instruction, cwd: cwd, session_id: session_id, card: card)
    end
  end

  private
    def report(card, instruction, output)
      card.report_failure!("Couldn't send instruction to #{card.project.presence || "agent"}", output, instruction: instruction)
    end
end
