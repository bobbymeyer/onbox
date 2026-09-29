# One row per webhook origin. The token authenticates the intake POST;
# kind picks the normalizer, card_type picks the card template.
class Source < ApplicationRecord
  KINDS = %w[claude_code email calendar reminders generic].freeze
  GOOGLE_KINDS = %w[email].freeze
  MAC_KINDS = %w[calendar reminders].freeze
  DEFAULT_EMAIL_QUERY = "in:inbox category:primary".freeze

  has_secure_token :token
  has_many :cards, dependent: :nullify

  # For the email source, the Gmail refresh token.
  encrypts :secret

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :card_type, inclusion: { in: CardType::SOURCE_NAMES }

  before_validation { self.card_type = CardType.default_for(kind) if card_type.blank? }

  scope :email, -> { where(kind: "email") }
  scope :calendar, -> { where(kind: "calendar") }
  scope :reminders, -> { where(kind: "reminders") }
  scope :google, -> { where(kind: GOOGLE_KINDS) }
  scope :mac, -> { where(kind: MAC_KINDS) }

  def email? = kind == "email"
  def calendar? = kind == "calendar"
  def google? = GOOGLE_KINDS.include?(kind)
  def mac? = MAC_KINDS.include?(kind)

  # Email: signed in to Gmail. Calendar and Reminders: macOS allowed access.
  def connected?
    if google? then secret.present?
    elsif mac? then MacEventKit.granted?(calendar? ? "calendar" : "reminders")
    else false
    end
  end

  # Checks Gmail, Calendar or Reminders now; returns the new cards.
  def poll!
    case kind
    when "email" then Gmail::Sync.call(self)
    when "calendar" then MacCalendar::Sync.call(self)
    when "reminders" then MacReminders::Sync.call(self)
    else raise ArgumentError, "#{name} isn't polled"
    end
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
