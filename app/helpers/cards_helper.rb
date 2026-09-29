module CardsHelper
  ASK_LABELS = { "decision" => "Decide", "reply" => "Reply", "review" => "Review", "acknowledge" => "Note" }.freeze

  def ask_label(card)
    ASK_LABELS.fetch(card.ask, card.ask.humanize)
  end

  def card_age(card)
    "#{time_ago_in_words(card.created_at)} ago"
  end

  def stale?(card)
    card.created_at < 1.day.ago
  end

  def hold_description(card)
    parts = []
    parts << card.hold_until.to_fs(:short) if card.hold_until
    parts << card.hold_event if card.hold_event
    parts.to_sentence(two_words_connector: " or ", last_word_connector: ", or ").presence || "released"
  end

  def card_body(card)
    card.payload["body"].presence || card.payload["last_assistant_message"].presence
  end

  RSVP_ORDER = %w[accept tentative decline].freeze

  # The Accept / Maybe / Decline stamps, in that order.
  def calendar_stamps
    Stamp.where(card_type: "calendar").select { |s| RSVP_ORDER.include?(s.action_kind) }
      .sort_by { |s| RSVP_ORDER.index(s.action_kind) }
  end

  LATER_CHOICES = [ "1 hour", "this afternoon", "tonight", "tomorrow", "next week" ].freeze
end
