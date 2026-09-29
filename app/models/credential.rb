# A secret onbox holds on Bobby's behalf, encrypted at rest.
class Credential < ApplicationRecord
  CLAUDE_TOKEN = "claude_code_oauth_token".freeze

  encrypts :secret

  validates :name, presence: true, uniqueness: true
  validates :secret, presence: true

  def self.claude_token
    find_by(name: CLAUDE_TOKEN)
  end

  def self.store_claude_token!(token)
    record = find_or_initialize_by(name: CLAUDE_TOKEN)
    record.update!(secret: token)
    record
  end

  # setup-token tokens last a year.
  def expires_at
    created_at + 1.year
  end
end
