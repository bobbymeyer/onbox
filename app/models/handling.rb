# The event log: every gesture Bobby makes on a card, and every change the
# secretary makes on its own judgment (verb "secretary"). The noticer reads
# the free-text replies; the secretary's accounting is built from the log.
class Handling < ApplicationRecord
  VERBS = %w[stamp reply top_of_stack later flip decompose release done secretary].freeze

  belongs_to :card
  belongs_to :stamp, optional: true

  validates :verb, inclusion: { in: VERBS }

  scope :replies, -> { where(verb: "reply") }
  scope :by_secretary, -> { where(verb: "secretary") }
end
