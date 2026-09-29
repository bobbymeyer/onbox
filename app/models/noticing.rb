# One phrase the noticer caught Bobby typing repeatedly, and what became of
# the offer: pending while its card is open, accepted once a stamp exists,
# declined otherwise. A phrase is only ever offered once.
class Noticing < ApplicationRecord
  belongs_to :card, optional: true
  belongs_to :stamp, optional: true

  validates :card_type, :phrase, :example, presence: true

  def status
    if stamp_id then "accepted"
    elsif card && !card.handled? then "pending"
    else "declined"
    end
  end
end
