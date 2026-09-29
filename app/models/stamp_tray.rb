# The stamps shown on a card: the secretary's two or three likeliest for this
# card, then the most used. The rest stay one tap away.
class StampTray
  SHOWN = 4

  attr_reader :shown, :more

  def self.for(card)
    new(card)
  end

  def initialize(card)
    stamps = Stamp.for_card(card).by_use.select { |stamp| stamp.applicable_to?(card) && card.type.tool_actions.exclude?(stamp.action_kind) }
    likely = Array(card.payload["likely_stamps"]).filter_map { |label| stamps.find { |s| s.label == label } }.first(3)
    ordered = (likely + stamps).uniq
    @shown = ordered.first(SHOWN)
    @more = ordered.drop(SHOWN)
  end
end
