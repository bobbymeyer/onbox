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
    def decomposable? = true

    # What a stamp cast from Bobby's replies on this type does.
    def primary_action = "handle"

    # Actions the type's own tool offers, so the stamp tray leaves them out.
    def tool_actions = []

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
    def primary_action = "instruct"

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
    def primary_action = "reply"

    # "instruct" on an email means send the drafted reply, so "Approve" works here too.
    def perform(kind, card, text)
      case kind
      when "reply", "instruct" then EmailActionJob.perform_later(card, "reply", text) if text.present?
      when "archive" then EmailActionJob.perform_later(card, "archive", nil)
      end
    end
  end

  # An invitation to answer, or a heads-up that a meeting moved or was
  # cancelled. The tool's Accept / Maybe / Decline buttons are stamps (with an
  # optional note to the organizer); the tray leaves them to the tool.
  class Calendar < Generic
    def name = "calendar"
    def send_label = "Got it"
    def actions = %w[accept tentative decline]
    def tool_actions = [ *actions, "handle" ] # "Handled without answering" covers Done
    def primary_action = "accept"
    def decomposable? = false

    # A stamp with no typed note falls back to the card's proposed action,
    # which here is the secretary's advice to Bobby, not a note for the
    # organizer; only a note he wrote is sent.
    def perform(kind, card, text)
      return unless actions.include?(kind) && card.payload["change"] == "invitation"
      note = text unless text.blank? || text == card.proposed_action.to_s
      CalendarActionJob.perform_later(card, kind, note)
    end
  end

  # The noticer's offer to turn a repeated reply into a stamp. Its tool casts
  # the stamp (CardsController#cast); replying with nothing declines.
  class StampOffer < Generic
    def name = "stamp_offer"
    def send_label = "Not a stamp"
    def decomposable? = false
    def supports?(_kind) = false
  end

  # The secretary's periodic accounting, delivered as a card to read.
  class Digest < Generic
    def name = "digest"
    def send_label = "Got it"
    def decomposable? = false
    def supports?(_kind) = false
  end

  REGISTRY = [ Agent.new, Email.new, Calendar.new, Generic.new, StampOffer.new, Digest.new ].index_by(&:name).freeze
  NAMES = REGISTRY.keys.freeze
  # Types a source or stamp can be for; offers and digests are the stack's own.
  SOURCE_NAMES = (NAMES - %w[stamp_offer digest]).freeze

  SOURCE_KIND_DEFAULTS = { "claude_code" => "agent", "email" => "email", "calendar" => "calendar" }.freeze

  def self.for(name)
    REGISTRY.fetch(name.to_s, REGISTRY["generic"])
  end

  def self.default_for(source_kind)
    SOURCE_KIND_DEFAULTS.fetch(source_kind.to_s, "generic")
  end
end
