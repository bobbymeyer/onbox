# Each card type is a small template that knows its own tool: the partial in
# app/views/cards/types/_<name>.html.erb renders the inline tool, and #perform
# carries out a stamp's or reply's action against wherever the card came from.
# New sources are added by writing a new card type.
class CardType
  class Generic
    def name = "generic"
    def tool_label = "Note"
    def tool_placeholder = "Anything to record before this leaves the thread"
    def send_label = "Handled"
    def requires_text? = false

    # Action kinds this type can carry out besides "handle".
    def actions = []

    def supports?(kind)
      kind == "handle" || actions.include?(kind)
    end

    # Nothing to send back by default; the text lives on in the handling log.
    def perform(kind, card, text) = nil
  end

  class Agent < Generic
    def name = "agent"
    def tool_label = "Instruction"
    def tool_placeholder = "Tell the agent what to do next"
    def send_label = "Send to agent"
    def requires_text? = true
    def actions = %w[instruct reply]

    def perform(kind, card, text)
      AgentDispatchJob.perform_later(card, text) if text.present? && actions.include?(kind)
    end
  end

  class Email < Generic
    def name = "email"
    def tool_label = "Reply"
    def tool_placeholder = "Your reply"
    def send_label = "Send reply"
    def requires_text? = true
    def actions = %w[reply instruct archive]

    # "instruct" on an email means send the drafted reply, so "Approve" works here too.
    def perform(kind, card, text)
      case kind
      when "reply", "instruct" then EmailActionJob.perform_later(card, "reply", text) if text.present?
      when "archive" then EmailActionJob.perform_later(card, "archive", nil)
      end
    end
  end

  REGISTRY = [ Agent.new, Email.new, Generic.new ].index_by(&:name).freeze
  NAMES = REGISTRY.keys.freeze

  SOURCE_KIND_DEFAULTS = { "claude_code" => "agent", "email" => "email" }.freeze

  def self.for(name)
    REGISTRY.fetch(name.to_s, REGISTRY["generic"])
  end

  def self.default_for(source_kind)
    SOURCE_KIND_DEFAULTS.fetch(source_kind.to_s, "generic")
  end
end
