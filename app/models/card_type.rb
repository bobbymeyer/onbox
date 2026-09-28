# Each card type is a small template that knows its own tool: the partial in
# app/views/cards/types/_<name>.html.erb renders the inline tool, and #deliver
# carries a reply or stamped message back to wherever the card came from.
# New sources are added by writing a new card type.
class CardType
  class Generic
    def name = "generic"
    def tool_label = "Note"
    def tool_placeholder = "Anything to record before this leaves the thread"
    def requires_text? = false

    # Nothing to send back; the text lives on in the handling log.
    def deliver(card, text) = nil
  end

  class Agent < Generic
    def name = "agent"
    def tool_label = "Instruction"
    def tool_placeholder = "Tell the agent what to do next"
    def requires_text? = true

    def deliver(card, text)
      AgentDispatchJob.perform_later(card, text) if text.present?
    end
  end

  REGISTRY = [ Agent.new, Generic.new ].index_by(&:name).freeze
  NAMES = REGISTRY.keys.freeze

  SOURCE_KIND_DEFAULTS = { "claude_code" => "agent" }.freeze

  def self.for(name)
    REGISTRY.fetch(name.to_s, REGISTRY["generic"])
  end

  def self.default_for(source_kind)
    SOURCE_KIND_DEFAULTS.fetch(source_kind.to_s, "generic")
  end
end
