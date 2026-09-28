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

    card.type.deliver(card, message) if %w[instruct reply].include?(stamp.action_kind)
    card
  end

  # The fallback when no stamp fits. Repeated replies are what the noticer
  # will turn into stamps.
  def reply(card, text)
    Card.transaction do
      card.handlings.create!(verb: "reply", text: text)
      card.handle!(with: "reply")
    end
    card.type.deliver(card, text)
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
        card_type: CardType::NAMES.include?(spec["card_type"]) ? spec["card_type"] : "generic",
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
