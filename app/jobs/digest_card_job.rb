class DigestCardJob < ApplicationJob
  queue_as :default

  def perform(card)
    Secretary.digest(card) unless card.handled?
  end
end
