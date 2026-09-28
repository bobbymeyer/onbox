# One authenticated endpoint; everything enters here. The normalizer turns the
# payload into an Intake::Event, the event becomes (or refreshes) a card, and
# the secretary digests it in the background.
module Intake
  def self.receive(source, payload)
    event = Normalizer.for(source).call(source, payload)

    card = Card.transaction do
      card = (event.key && Card.open.find_by(key: event.key)) || Card.new(key: event.key)
      card.assign_attributes(
        source: source,
        card_type: source.card_type,
        project: event.project,
        summary: event.summary || "#{source.name}: new event",
        ask: event.ask,
        proposed_action: event.proposed_action,
        payload: event.payload.merge("body" => event.body),
        digested_at: nil
      )
      # Fresh news on an open card lands it on top again, to fall like a new one.
      card.position = Card.top_position if card.persisted? && card.live?
      card.save!
      card
    end

    Trigger.fire_matching!(event.event_keys)
    DigestCardJob.perform_later(card)
    card
  end
end
