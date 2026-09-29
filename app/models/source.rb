# One row per webhook origin. The token authenticates the intake POST;
# kind picks the normalizer, card_type picks the card template.
class Source < ApplicationRecord
  KINDS = %w[claude_code email generic].freeze
  DEFAULT_EMAIL_QUERY = "in:inbox category:primary".freeze

  has_secure_token :token
  has_many :cards, dependent: :nullify

  # For email sources, the Gmail refresh token.
  encrypts :secret

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :card_type, inclusion: { in: CardType::SOURCE_NAMES }

  before_validation { self.card_type = CardType.default_for(kind) if card_type.blank? }

  scope :email, -> { where(kind: "email") }

  def email? = kind == "email"

  def connected?
    email? && secret.present?
  end

  def email_query
    settings["query"].presence || DEFAULT_EMAIL_QUERY
  end

  def last_polled_at
    settings["last_polled_at"].presence && Time.zone.parse(settings["last_polled_at"])
  end

  def last_error
    settings["last_error"].presence
  end
end
