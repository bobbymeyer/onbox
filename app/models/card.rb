# An index card in the stack. Position is height in the stack: new cards land
# on top (highest position) and fall; the lowest live, unblocked card is the
# one in front of Bobby.
class Card < ApplicationRecord
  ASKS = %w[decision reply review acknowledge].freeze

  belongs_to :source, optional: true
  belongs_to :parent_card, class_name: "Card", optional: true
  belongs_to :blocked_by, class_name: "Card", optional: true
  has_many :children, class_name: "Card", foreign_key: :parent_card_id, dependent: :nullify, inverse_of: :parent_card
  has_many :blocking, class_name: "Card", foreign_key: :blocked_by_id, dependent: :nullify, inverse_of: :blocked_by
  has_many :triggers, dependent: :destroy
  has_many :handlings, dependent: :destroy

  enum :state, { live: "live", held: "held", handled: "handled" }, validate: true

  validates :card_type, inclusion: { in: CardType::NAMES }
  validates :ask, inclusion: { in: ASKS }

  before_validation :land_on_top, on: :create

  scope :open, -> { where.not(state: :handled) }
  scope :unblocked, -> { where(blocked_by_id: nil).or(where(blocked_by_id: Card.handled.select(:id))) }
  scope :in_stack_order, -> { order(:position, :id) }

  broadcasts_refreshes_to ->(_card) { "stack" }

  def self.current
    live.unblocked.in_stack_order.first
  end

  def self.top_position
    (maximum(:position) || 0) + 1
  end

  def self.bottom_position
    (open.minimum(:position) || 1) - 1
  end

  def type
    CardType.for(card_type)
  end

  def age
    created_at
  end

  def blocked?
    blocked_by.present? && !blocked_by.handled?
  end

  def pending_trigger
    triggers.pending.order(:fires_at).first
  end

  # Maintenance: shift one place toward the front (:forward) or back (:back)
  # among the live cards, renumbering them to keep positions distinct.
  def move!(direction)
    order = Card.live.in_stack_order.to_a
    index = order.index(self) or return
    other = direction.to_s == "forward" ? index - 1 : index + 1
    return if other.negative? || other >= order.size

    order[index], order[other] = order[other], order[index]
    base = order.map(&:position).min
    transaction { order.each_with_index { |card, i| card.update_column(:position, base + i) } }
    Card.broadcast_stack_refresh
  end

  def self.broadcast_stack_refresh
    Turbo::StreamsChannel.broadcast_refresh_to("stack")
  end

  # "Not this one": back onto the top, to fall again behind everything below it.
  def to_top_of_stack!
    update!(position: Card.top_position)
  end

  # "Not now": out of the stack until a trigger fires.
  def hold!(until_time: nil, event_key: nil)
    transaction do
      triggers.pending.update_all(fired_at: Time.current)
      triggers.create!(kind: :time, fires_at: until_time) if until_time
      triggers.create!(kind: :event, event_key: event_key) if event_key
      update!(state: :held, hold_until: until_time, hold_event: event_key)
    end
  end

  def release!
    transaction do
      triggers.pending.update_all(fired_at: Time.current)
      update!(state: :live, hold_until: nil, hold_event: nil, position: Card.top_position)
    end
  end

  def handle!(with:)
    transaction do
      triggers.pending.update_all(fired_at: Time.current)
      update!(state: :handled, handled_at: Time.current, handled_with: with)
    end
  end

  # Something went wrong carrying out Bobby's decision; it comes back as a card
  # rather than dropping silently.
  def report_failure!(summary, output, **payload)
    Card.create!(
      source: source,
      parent_card: self,
      card_type: "generic",
      project: project,
      summary: summary.truncate(200),
      ask: "review",
      payload: self.payload.slice("session_id", "cwd", "thread_id").merge(payload.stringify_keys).merge("body" => output.to_s.last(4000))
    )
  end

  # Template interpolation for stamps and successors: {{project}}, {{summary}}, ...
  def interpolate(text)
    text.to_s.gsub(/\{\{\s*(\w+)\s*\}\}/) do
      case $1
      when "project" then project.to_s
      when "summary" then summary.to_s
      when "ask" then ask.to_s
      when "proposed_action" then proposed_action.to_s
      else ""
      end
    end
  end

  private
    def land_on_top
      self.position = Card.top_position if position.nil?
    end
end
