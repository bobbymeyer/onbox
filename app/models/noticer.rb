# Watches what Bobby types repeatedly and offers to cast it into a stamp. The
# offer is a card, so the decision still reaches him; only the re-typing goes
# away once he accepts.
module Noticer
  THRESHOLD = ENV.fetch("STACK_NOTICER_THRESHOLD", 3).to_i
  WINDOW = 60.days
  MAX_LENGTH = 280

  module_function

  # "PR & merge." and "pr and merge" are the same phrase.
  def normalize(text)
    text.to_s.downcase.gsub("&", " and ").gsub(/[^\p{Alnum}\s]/, " ").squish
  end

  # Offers a stamp for every phrase on this card type that crossed the
  # threshold and isn't already a stamp or an earlier offer. Returns the new
  # offer cards.
  def call(card_type)
    texts = Handling.replies.joins(:card)
      .where(cards: { card_type: card_type }, created_at: WINDOW.ago..)
      .order(:created_at).pluck(:text)
      .select { |text| text.present? && text.length <= MAX_LENGTH }

    texts.group_by { |text| normalize(text) }.filter_map do |phrase, uses|
      next if phrase.empty? || uses.size < THRESHOLD || known?(card_type, phrase)
      offer(card_type, phrase, uses.last, uses.size)
    end
  end

  def known?(card_type, phrase)
    Noticing.exists?(card_type: card_type, phrase: phrase) ||
      Stamp.where(card_type: [ "any", card_type ]).any? { |s| [ s.label, s.template ].any? { |t| matches?(t, phrase) } }
  end

  # A stamp's {{placeholders}} match whatever they were filled with.
  def matches?(template, phrase)
    return false if template.blank?
    parts = template.split(/\{\{\s*\w+\s*\}\}/, -1).map { |part| Regexp.escape(normalize(part)) }
    phrase.match?(/\A#{parts.join(".+?")}\z/)
  end

  def offer(card_type, phrase, example, count)
    Card.transaction do
      card = Card.create!(
        card_type: "stamp_offer",
        project: "#{card_type} cards",
        summary: "You've typed \"#{example.truncate(60)}\" #{count} times. Make it a stamp?",
        ask: "decision",
        proposed_action: example,
        payload: { "noticed" => { "card_type" => card_type, "phrase" => phrase, "count" => count }, "body" => example },
        digested_at: Time.current
      )
      Noticing.create!(card_type: card_type, phrase: phrase, example: example, count: count, card: card)
      card
    end
  end

  # Bobby accepted: the stamp does what his reply did, for the same card type.
  def cast!(card, label:, template:)
    noticing = Noticing.find_by!(card: card)
    kind = CardType.for(noticing.card_type).primary_action

    Card.transaction do
      stamp = Stamp.create!(label: label.to_s.strip.presence || noticing.example.truncate(40),
                            card_type: noticing.card_type,
                            template: template.to_s.strip.presence || noticing.example,
                            action: { "kind" => kind })
      noticing.update!(stamp: stamp)
      card.handlings.create!(verb: "stamp", text: "Cast stamp: #{stamp.label}")
      card.handle!(with: "cast stamp")
      stamp
    end
  end
end
