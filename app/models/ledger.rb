# The hard numbers behind a digest, read straight from the cards and the
# handling log for one window.
module Ledger
  OWN_TYPES = %w[digest stamp_offer].freeze

  module_function

  def for(window)
    arrived = Card.where(created_at: window).where.not(card_type: OWN_TYPES).left_joins(:source)
    handled = Card.where(handled_at: window).where.not(card_type: OWN_TYPES)
    handlings = Handling.where(created_at: window)
    live = Card.live.where.not(card_type: OWN_TYPES)
    oldest = live.order(:created_at).first

    {
      "gestures" => handlings.by_bobby.count,
      "arrived" => arrived.group("COALESCE(sources.name, 'stack')").count,
      "handled_count" => handled.count,
      "handled" => handled.group(:handled_with).order(Arel.sql("COUNT(*) DESC")).limit(6).count,
      "secretary" => handlings.by_secretary.includes(:card).order(:created_at).limit(20).map { |h| "#{h.text}: #{h.card.summary}" },
      "deferred" => handlings.where(verb: %w[later top_of_stack]).includes(:card).group_by(&:card).select { |_, hs| hs.size > 1 }.map { |c, hs| "#{c.summary} (#{hs.size}x)" },
      "flips" => handlings.where(verb: "flip").count,
      "decomposed" => handlings.where(verb: "decompose").count,
      "stamps_offered" => Noticing.where(created_at: window).count,
      "held_now" => Card.held.where.not(card_type: OWN_TYPES).order(:hold_until).limit(20).map { |c| "#{c.summary} (until #{[ c.hold_until&.to_fs(:short), c.hold_event ].compact.join(" or ")})" },
      "live_now" => live.count,
      "stale_now" => live.where(created_at: ...1.day.ago).count,
      "oldest" => oldest && "#{oldest.summary} (#{ActionController::Base.helpers.time_ago_in_words(oldest.created_at)})"
    }
  end

  # Bobby worked cards in the window. No activity, no report.
  def active?(stats)
    stats["gestures"].positive?
  end
end
