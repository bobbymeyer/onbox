# How often a card's front was not enough. A rising rate means whoever is
# pushing cards is not making them actionable.
module FlipRate
  module_function

  def recent(since: 7.days.ago)
    handled = Card.handled.where(handled_at: since..).count
    return if handled.zero?
    flipped = Card.handled.where(handled_at: since..).where("flip_count > 0").count
    (flipped * 100.0 / handled).round
  end
end
