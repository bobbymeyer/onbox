# One row per webhook origin. The token authenticates the intake POST;
# kind picks the normalizer, card_type picks the card template.
class Source < ApplicationRecord
  KINDS = %w[claude_code email calendar reminders generic].freeze
  MAC_KINDS = %w[email calendar reminders].freeze
  # What each Mac source needs macOS to allow.
  MAC_ACCESS = { "email" => "mail", "calendar" => "calendar", "reminders" => "reminders" }.freeze
  MAC_APPS = { "email" => "Mail", "calendar" => "Calendar", "reminders" => "Reminders" }.freeze

  has_secure_token :token
  has_many :cards, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :card_type, inclusion: { in: CardType::SOURCE_NAMES }

  before_validation { self.card_type = CardType.default_for(kind) if card_type.blank? }

  scope :email, -> { where(kind: "email") }
  scope :calendar, -> { where(kind: "calendar") }
  scope :reminders, -> { where(kind: "reminders") }
  scope :mac, -> { where(kind: MAC_KINDS) }

  def email? = kind == "email"
  def calendar? = kind == "calendar"
  def mac? = MAC_KINDS.include?(kind)
  def mac_access = MAC_ACCESS[kind]
  def mac_app = MAC_APPS[kind]

  # Mail, Calendar and Reminders: macOS allowed onbox to use the app.
  def connected?
    mac? && MacEventKit.granted?(mac_access)
  end

  # Checks Mail, Calendar or Reminders now; returns the new cards.
  def poll!
    case kind
    when "email" then MacMail::Sync.call(self)
    when "calendar" then MacCalendar::Sync.call(self)
    when "reminders" then MacReminders::Sync.call(self)
    else raise ArgumentError, "#{name} isn't polled"
    end
  end

  def last_polled_at
    settings["last_polled_at"].presence && Time.zone.parse(settings["last_polled_at"])
  end

  def last_error
    settings["last_error"].presence
  end
end
