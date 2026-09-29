# The event log: every gesture Bobby makes on a card, and every change the
# secretary makes on its own judgment (verb "secretary"). The noticer reads
# the free-text replies; the secretary's accounting is built from the log.
class Handling < ApplicationRecord
  VERBS = %w[stamp reply top_of_stack later flip decompose release done secretary].freeze

  # Fired by Bobby's first gesture after a quiet spell; digests wait on it.
  ACTIVE_EVENT = "stack:active".freeze

  belongs_to :card
  belongs_to :stamp, optional: true

  validates :verb, inclusion: { in: VERBS }

  scope :replies, -> { where(verb: "reply") }
  scope :by_secretary, -> { where(verb: "secretary") }
  scope :by_bobby, -> { where.not(verb: "secretary") }

  after_create_commit -> { Trigger.fire_matching!(ACTIVE_EVENT) }, unless: -> { verb == "secretary" }

  # Bobby is working cards right now.
  def self.bobby_active?(within: ENV.fetch("STACK_ACTIVE_MINUTES", 30).to_i.minutes)
    by_bobby.where(created_at: within.ago..).exists?
  end
end
