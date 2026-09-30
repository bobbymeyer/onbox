# Secrets onbox holds (the Claude Code token) are encrypted at rest. Keys come
# from credentials when set there, otherwise they are derived from
# secret_key_base so a fresh install needs no extra setup.
Rails.application.config.after_initialize do
  encryption = Rails.application.credentials.active_record_encryption || {}
  derive = ->(purpose) { Rails.application.key_generator.generate_key("stack/active_record_encryption/#{purpose}", 32).unpack1("H*") }

  ActiveRecord::Encryption.configure(
    primary_key: encryption[:primary_key] || derive.("primary"),
    deterministic_key: encryption[:deterministic_key] || derive.("deterministic"),
    key_derivation_salt: encryption[:key_derivation_salt] || derive.("salt")
  )
end
