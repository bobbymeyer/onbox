# Wakes a held card, either at a time or when an incoming event carries a
# matching event key.
class Trigger < ApplicationRecord
  belongs_to :card

  enum :kind, { time: "time", event: "event" }, validate: true

  validates :fires_at, presence: true, if: :time?
  validates :event_key, presence: true, if: :event?

  scope :pending, -> { where(fired_at: nil) }
  scope :due, ->(now = Time.current) { pending.time.where(fires_at: ..now) }
  scope :matching, ->(keys) { pending.event.where(event_key: Array(keys)) }

  def self.fire_due!(now = Time.current)
    due(now).includes(:card).find_each(&:fire!)
  end

  def self.fire_matching!(keys)
    matching(keys).includes(:card).find_each(&:fire!)
  end

  def fire!
    return if fired_at
    update!(fired_at: Time.current)
    card.release! if card.held?
  end
end
