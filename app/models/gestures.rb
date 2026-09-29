# What Bobby can do to the card in front of him. One verb for leaving the
# thread: handled. The specific action (stamp label, "reply") is metadata.
module Gestures
  module_function

  # Apply a saved action in one motion: send its message, handle the card,
  # seed its successors, re-seed it if it repeats.
  def stamp(card, stamp, text: nil)
    message = text.presence || card.interpolate(stamp.template.presence || card.proposed_action)

    Card.transaction do
      card.handlings.create!(verb: "stamp", stamp: stamp, text: message)
      stamp.increment!(:use_count)
      card.handle!(with: stamp.label)
      seed_successors(card, stamp.successor_specs)
      reseed(card, stamp.repeat_every) if stamp.repeat_every
    end

    card.type.perform(stamp.action_kind, card, message)
    card
  end

  # The fallback when no stamp fits. Repeated replies are what the noticer
  # will turn into stamps.
  def reply(card, text)
    Card.transaction do
      card.handlings.create!(verb: "reply", text: text)
      card.handle!(with: "reply")
    end
    card.type.perform("reply", card, text)
    NoticerJob.perform_later(card.card_type) if text.present?
    card
  end

  # "Not this one."
  def top_of_stack(card)
    card.handlings.create!(verb: "top_of_stack")
    card.to_top_of_stack!
  end

  # "Not now." Returns false when the deferral cannot be resolved.
  def later(card, text)
    resolved = Secretary.resolve_later(text, card: card)
    return false unless resolved

    Card.transaction do
      card.handlings.create!(verb: "later", text: text)
      card.hold!(**resolved)
    end
    true
  end

  # Break one overcomposed or poorly defined card into single-action cards.
  # Each step waits on the one before it. The first goes to the front, since
  # Bobby was on this card; the rest land on top and fall like new cards, so
  # the steps scatter through the stack by dependency rather than as a block.
  # Steps keep the original's type and context, so an agent step can still be
  # sent to its session.
  #
  # steps: [{ "summary" =>, "ask" =>, "proposed_action" => }]
  def decompose(card, steps)
    steps = steps.map(&:to_h).select { |step| step["summary"].present? }
    return [] if steps.empty?

    Card.transaction do
      front = Card.bottom_position
      previous = nil
      subs = steps.each_with_index.map do |step, i|
        previous = Card.create!(
          source: card.source,
          parent_card: card,
          blocked_by: previous,
          position: i.zero? ? front : nil,
          card_type: card.type.decomposed_type,
          project: card.project,
          summary: step["summary"].to_s.strip.truncate(200),
          ask: Card::ASKS.include?(step["ask"]) ? step["ask"] : "acknowledge",
          proposed_action: step["proposed_action"].to_s.strip.presence,
          payload: card.payload.except("likely_stamps", "reminder_id").merge("decomposed_from" => card.id),
          digested_at: Time.current
        )
      end
      card.handlings.create!(verb: "decompose", text: subs.map(&:summary).join("\n"))
      card.handle!(with: "decompose")
      subs
    end
  end

  # Flip rate is a health metric for the intake side.
  def flip(card)
    card.handlings.create!(verb: "flip")
    card.increment!(:flip_count)
  end

  # Successors run in sequence by default: each is blocked by the one before it,
  # so "notify" cannot fall before "deploy" is handled. "parallel": true opts out.
  def seed_successors(card, specs)
    previous = nil
    specs.each do |spec|
      successor = Card.create!(
        source: card.source,
        parent_card: card,
        blocked_by: spec["parallel"] ? nil : previous,
        card_type: CardType::SOURCE_NAMES.include?(spec["card_type"]) ? spec["card_type"] : "generic",
        project: card.interpolate(spec["project"].presence || "{{project}}"),
        summary: card.interpolate(spec["summary"]).truncate(200),
        ask: Card::ASKS.include?(spec["ask"]) ? spec["ask"] : "acknowledge",
        proposed_action: card.interpolate(spec["proposed_action"]).presence,
        payload: card.payload.slice("session_id", "cwd").merge("seeded_by" => card.id)
      )
      if spec["later"].present? && (time = DeferralParser.parse(spec["later"]))
        successor.hold!(until_time: time)
      end
      previous = successor
    end
  end

  # A repeating task re-seeds itself, deferred to its next interval.
  def reseed(card, every)
    time = DeferralParser.parse(every) or return
    copy = Card.create!(
      card.attributes.slice("source_id", "card_type", "project", "summary", "ask", "proposed_action", "payload")
        .merge("parent_card_id" => card.id)
    )
    copy.hold!(until_time: time)
  end
end
