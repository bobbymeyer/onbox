class Secretary
  # Proposes how to break one card into single-action cards. Bobby edits the
  # proposal before anything is created.
  module Decomposition
    SYSTEM = <<~PROMPT.freeze
      You break one index card from Bobby's stack into smaller cards, each a
      single action he can take from its front alone, in the order they must
      happen. If the card is poorly defined, the first step is the clarifying
      question he needs answered (ask "decision"). Two to six steps; fewer is
      better. For agent cards, proposed_action is the instruction to send the
      agent for that step; for others it is the drafted response, or "" when
      the step is just to note something.
    PROMPT

    SCHEMA = {
      type: "object",
      properties: {
        steps: {
          type: "array",
          items: {
            type: "object",
            properties: {
              summary: { type: "string" },
              ask: { type: "string", enum: Card::ASKS },
              proposed_action: { type: "string" }
            },
            required: %w[summary ask proposed_action],
            additionalProperties: false
          }
        }
      },
      required: %w[steps],
      additionalProperties: false
    }.freeze

    module_function

    # Returns [{ "summary", "ask", "proposed_action" }] or [] when unavailable.
    def propose(card)
      return [] unless Secretary.enabled?(:deep)

      answer = Secretary.new.structured(system: SYSTEM, user: <<~CARD, schema: SCHEMA, effort: :medium, tier: :deep)
        Card type: #{card.card_type}
        Project: #{card.project}
        Summary: #{card.summary}
        Ask: #{card.ask}
        Proposed action: #{card.proposed_action}

        Payload:
        #{JSON.pretty_generate(card.payload.except("likely_stamps"))}
      CARD
      Array(answer&.dig("steps"))
    end
  end
end
