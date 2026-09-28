# One turn of the maintenance-mode conversation with the secretary.
class SecretaryMessage < ApplicationRecord
  ROLES = %w[bobby secretary].freeze

  validates :role, inclusion: { in: ROLES }
  validates :body, presence: true

  scope :recent, ->(n = 10) { order(id: :desc).limit(n).reverse }
end
