# A saved action applied in one motion. It bundles a message (template), an
# action, and the cards it seeds afterwards (successors).
#
# action:     { "kind" => "instruct" | "reply" | "handle", "repeat" => "1 week" }
# successors: [{ "summary" => "Deploy {{project}}", "ask" => "acknowledge",
#                "card_type" => "generic", "later" => "tomorrow morning",
#                "parallel" => false }]
class Stamp < ApplicationRecord
  ACTION_KINDS = %w[instruct reply handle].freeze

  has_many :handlings, dependent: :nullify

  validates :label, presence: true
  validates :card_type, inclusion: { in: [ "any", *CardType::NAMES ] }
  validate :action_kind_known
  validate :json_fields_parse

  # action and successors are edited as JSON text in maintenance mode.
  def action_json = @action_json || JSON.pretty_generate(action || {})
  def successors_json = @successors_json || JSON.pretty_generate(successors || [])

  def action_json=(text)
    @action_json = text
    self.action = parse_json(text, :action_json) || {}
  end

  def successors_json=(text)
    @successors_json = text
    self.successors = parse_json(text, :successors_json) || []
  end

  scope :for_card, ->(card) { where(card_type: [ "any", card.card_type ]) }
  scope :by_use, -> { order(use_count: :desc, label: :asc) }

  def action_kind
    action.fetch("kind", "handle")
  end

  # A sending stamp with no template needs a drafted proposed action to send.
  def applicable_to?(card)
    action_kind == "handle" || template.present? || card.proposed_action.present?
  end

  def repeat_every
    action["repeat"].presence
  end

  def successor_specs
    Array(successors).select { |s| s.is_a?(Hash) && s["summary"].present? }
  end

  private
    def parse_json(text, field)
      text.blank? ? nil : JSON.parse(text)
    rescue JSON::ParserError
      (@json_errors ||= []) << field
      nil
    end

    def json_fields_parse
      Array(@json_errors).each { |field| errors.add(field, "is not valid JSON") }
      errors.add(:successors_json, "must be a JSON array") unless successors.is_a?(Array)
      errors.add(:action_json, "must be a JSON object") unless action.is_a?(Hash)
    end

    def action_kind_known
      errors.add(:action, "kind must be one of #{ACTION_KINDS.join(", ")}") unless ACTION_KINDS.include?(action_kind)
    end
end
