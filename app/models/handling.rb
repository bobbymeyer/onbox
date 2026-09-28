# The event log: every gesture Bobby makes on a card. The noticer reads the
# free-text rows; the secretary's accounting is built from the whole log.
class Handling < ApplicationRecord
  VERBS = %w[stamp reply top_of_stack later flip decompose release delete].freeze

  belongs_to :card
  belongs_to :stamp, optional: true

  validates :verb, inclusion: { in: VERBS }

  scope :replies, -> { where(verb: "reply") }
end
