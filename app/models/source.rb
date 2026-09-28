# One row per webhook origin. The token authenticates the intake POST;
# kind picks the normalizer, card_type picks the card template.
class Source < ApplicationRecord
  KINDS = %w[claude_code generic].freeze

  has_secure_token :token
  has_many :cards, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :card_type, inclusion: { in: CardType::NAMES }

  before_validation { self.card_type = CardType.default_for(kind) if card_type.blank? }
end
